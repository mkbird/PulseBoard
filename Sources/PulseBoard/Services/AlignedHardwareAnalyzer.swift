import Foundation
import SQLite3

private struct StatTracker {
    private(set) var values: [Double] = []
    private var sum: Double = 0
    private var minVal: Double = .infinity
    private var maxVal: Double = -.infinity

    mutating func add(_ value: Double?) {
        guard let value, value.isFinite else { return }
        values.append(value)
        sum += value
        if value < minVal { minVal = value }
        if value > maxVal { maxVal = value }
    }

    var metric: AlignedStatMetric {
        let cnt = values.count
        guard cnt > 0 else {
            return AlignedStatMetric(avg: nil, max: nil, min: nil, p95: nil, count: 0)
        }
        let sorted = values.sorted()
        let p95Idx = min(cnt - 1, max(0, Int(ceil(Double(cnt) * 0.95)) - 1))
        return AlignedStatMetric(
            avg: sum / Double(cnt),
            max: maxVal,
            min: minVal,
            p95: sorted[p95Idx],
            count: cnt
        )
    }
}

extension HistoryStore {
    func fetchWebHistory(from: Date, to: Date, maxPoints: Int = 600) throws -> [AlignedTimeSeriesPoint] {
        let clampedMax = max(30, min(maxPoints, 2_400))
        let samples = try fetch(from: from, to: to, maxPoints: clampedMax)
        guard !samples.isEmpty else { return [] }

        let span = max(1, to.timeIntervalSince(from))
        let bucket = max(1, Int(ceil(span / Double(clampedMax))))
        let cmsBuckets = try fetchCMSBuckets(from: from, to: to, bucketSeconds: bucket)

        return samples.map { s in
            let tsSec = s.timestamp.timeIntervalSince1970
            let key = Int64(floor(tsSec / Double(bucket)))
            let cms = cmsBuckets[key] ?? cmsBuckets[key - 1] ?? cmsBuckets[key + 1]
            return AlignedTimeSeriesPoint(
                tsMs: Int64((tsSec * 1_000.0).rounded()),
                sysCPU: s.cpuUsage,
                sysGPU: s.gpuUsage,
                aneUsage: s.aneUsage,
                sysMemBytes: s.memoryUsedBytes,
                sysMemPct: s.memoryUsage,
                swapUsedBytes: s.swapUsedBytes,
                cliptoCPU: s.cliptoCPUPercent,
                cliptoMemBytes: s.cliptoMemoryBytes,
                cliptoGPU: s.cliptoGPUPercent,
                cliptoDiskRead: s.cliptoDiskReadBytesPerSecond,
                cliptoDiskWrite: s.cliptoDiskWriteBytesPerSecond,
                cmsCPU: cms?.cpu,
                cmsMemBytes: cms?.mem,
                sysPower: s.systemPowerWatts,
                cpuPower: s.cpuPowerWatts,
                gpuPower: s.gpuPowerWatts,
                anePower: s.anePowerWatts,
                dramReadGBps: s.memoryReadGBps,
                dramWriteGBps: s.memoryWriteGBps,
                diskReadBps: s.diskReadBytesPerSecond,
                diskWriteBps: s.diskWriteBytesPerSecond,
                netDownBps: s.networkDownBytesPerSecond,
                netUpBps: s.networkUpBytesPerSecond,
                thermal: s.thermalState
            )
        }
    }

    func fetchAlignedReport(
        activeIntervalsMs: [[Int64]],
        fallbackStartMs: Int64,
        fallbackEndMs: Int64,
        maxSeriesPoints: Int = 480
    ) throws -> AlignedHardwareReport {
        var rawPairs: [(Int64, Int64)] = activeIntervalsMs.compactMap { pair in
            guard pair.count >= 2, pair[0] > 0, pair[1] >= pair[0] else { return nil }
            return (pair[0], pair[1])
        }
        if rawPairs.isEmpty, fallbackStartMs > 0, fallbackEndMs >= fallbackStartMs {
            rawPairs = [(fallbackStartMs, fallbackEndMs)]
        }

        guard !rawPairs.isEmpty else {
            return emptyAlignedReport(startMs: 0, endMs: 0)
        }

        let unpaddedMerged = DAGSCAnalyzer.mergeIntervalsWithGap(rawPairs, maxGapMs: 0)
        let targetActiveMs = unpaddedMerged.reduce(Int64(0)) { $0 + max(0, $1.1 - $1.0) }
        let targetActiveSeconds = max(1.0, Double(targetActiveMs) / 1_000.0)

        // Pad by ±2s to ensure 1Hz hardware samples cover tight task boundaries
        let paddedPairs = unpaddedMerged.map { (max(0, $0.0 - 2_000), $0.1 + 2_000) }
        let queryIntervals = DAGSCAnalyzer.mergeIntervalsWithGap(paddedPairs, maxGapMs: 1_000)

        let windowStartMs = unpaddedMerged.first?.0 ?? fallbackStartMs
        let windowEndMs = unpaddedMerged.last?.1 ?? fallbackEndMs

        // Fetch system + Clipto samples across active intervals
        var allSamples: [MetricSample] = []
        let useDownsample = targetActiveSeconds > 86_400 // > 24h active time
        for (sMs, eMs) in queryIntervals {
            let fromDate = Date(timeIntervalSince1970: Double(sMs) / 1_000.0)
            let toDate = Date(timeIntervalSince1970: Double(eMs) / 1_000.0)
            if useDownsample {
                let pts = try fetch(from: fromDate, to: toDate, maxPoints: 3_600)
                allSamples.append(contentsOf: pts)
            } else {
                let pts = try fetchRaw(from: fromDate, to: toDate)
                allSamples.append(contentsOf: pts)
            }
        }

        // Fetch CMS totals & per-process summaries across active intervals
        var cmsCPUTracker = StatTracker()
        var cmsMemTracker = StatTracker()
        var cmsFrameCount = 0
        for (sMs, eMs) in queryIntervals {
            let sSec = Double(sMs) / 1_000.0
            let eSec = Double(eMs) / 1_000.0
            try withStatement("""
            SELECT total_cpu_percent, total_memory_bytes
            FROM cms_frames
            WHERE timestamp BETWEEN ? AND ?
            ORDER BY timestamp;
            """) { stmt in
                try check(sqlite3_bind_double(stmt, 1, sSec))
                try check(sqlite3_bind_double(stmt, 2, eSec))
                while try nextRow(stmt) {
                    cmsFrameCount += 1
                    cmsCPUTracker.add(optionalDouble(stmt, 0))
                    cmsMemTracker.add(optionalDouble(stmt, 1))
                }
            }
        }

        let cmsProcesses = try fetchCMSProcessSummary(intervalsMs: queryIntervals)

        guard !allSamples.isEmpty || cmsFrameCount > 0 else {
            return emptyAlignedReport(
                startMs: windowStartMs,
                endMs: windowEndMs,
                targetActiveSeconds: targetActiveSeconds
            )
        }

        var sysCPU = StatTracker()
        var sysGPU = StatTracker()
        var aneUsage = StatTracker()
        var sysMemBytes = StatTracker()
        var sysMemPct = StatTracker()
        var swapUsed = StatTracker()
        var sysPower = StatTracker()
        var cpuPower = StatTracker()
        var gpuPower = StatTracker()
        var anePower = StatTracker()
        var dramRead = StatTracker()
        var dramWrite = StatTracker()
        var diskRead = StatTracker()
        var diskWrite = StatTracker()

        var cliptoActiveSamples = 0
        var cliptoMaxProcs = 0
        var cliptoCPU = StatTracker()
        var cliptoMem = StatTracker()
        var cliptoGPU = StatTracker()
        var cliptoDiskRead = StatTracker()
        var cliptoDiskWrite = StatTracker()
        var cmsGPU = StatTracker()

        var worstThermalRank = 0
        var worstThermal = "nominal"

        var coveredSeconds: Double = 0
        var energyJoules: Double = 0
        var energyValidSeconds: Double = 0

        let sortedSamples = allSamples.sorted { $0.timestamp < $1.timestamp }
        var prevSample: MetricSample?

        for s in sortedSamples {
            sysCPU.add(s.cpuUsage)
            sysGPU.add(s.gpuUsage)
            aneUsage.add(s.aneUsage)
            sysMemBytes.add(s.memoryUsedBytes)
            sysMemPct.add(s.memoryUsage)
            swapUsed.add(s.swapUsedBytes)
            sysPower.add(s.systemPowerWatts)
            cpuPower.add(s.cpuPowerWatts)
            gpuPower.add(s.gpuPowerWatts)
            anePower.add(s.anePowerWatts)
            dramRead.add(s.memoryReadGBps)
            dramWrite.add(s.memoryWriteGBps)
            diskRead.add(s.diskReadBytesPerSecond)
            diskWrite.add(s.diskWriteBytesPerSecond)

            cmsGPU.add(s.cmsGPUPercent)

            let rank = Self.thermalSeverity(s.thermalState)
            if rank > worstThermalRank {
                worstThermalRank = rank
                worstThermal = s.thermalState
            }

            if (s.cliptoProcessCount ?? 0) > 0 || s.cliptoMemoryBytes != nil || s.cliptoCPUPercent != nil {
                cliptoActiveSamples += 1
                cliptoMaxProcs = max(cliptoMaxProcs, s.cliptoProcessCount ?? 0)
                cliptoCPU.add(s.cliptoCPUPercent)
                cliptoMem.add(s.cliptoMemoryBytes)
                cliptoGPU.add(s.cliptoGPUPercent)
                cliptoDiskRead.add(s.cliptoDiskReadBytesPerSecond)
                cliptoDiskWrite.add(s.cliptoDiskWriteBytesPerSecond)
            }

            if let prev = prevSample {
                let dt = s.timestamp.timeIntervalSince(prev.timestamp)
                if dt > 0, dt <= 30 {
                    coveredSeconds += dt
                    if let p1 = prev.systemPowerWatts, let p2 = s.systemPowerWatts {
                        energyJoules += ((p1 + p2) * 0.5) * dt
                        energyValidSeconds += dt
                    }
                }
            } else {
                coveredSeconds += 1.0
            }
            prevSample = s
        }

        let estimatedWh: Double? = energyValidSeconds > 0 ? (energyJoules / 3_600.0) : nil
        let coveragePct = min(100.0, (coveredSeconds / targetActiveSeconds) * 100.0)

        let seriesFrom = Date(timeIntervalSince1970: Double(max(0, windowStartMs - 2_000)) / 1_000.0)
        let seriesTo = Date(timeIntervalSince1970: Double(windowEndMs + 2_000) / 1_000.0)
        let series = (try? fetchWebHistory(from: seriesFrom, to: seriesTo, maxPoints: maxSeriesPoints)) ?? []

        return AlignedHardwareReport(
            hasData: true,
            sampleCount: sortedSamples.count,
            cmsFrameCount: cmsFrameCount,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            windowStartText: DAGSCAnalyzer.formatTimestampMs(windowStartMs),
            windowEndText: DAGSCAnalyzer.formatTimestampMs(windowEndMs),
            targetActiveSeconds: (targetActiveSeconds * 100).rounded() / 100,
            coveredSeconds: (coveredSeconds * 100).rounded() / 100,
            coveragePercent: (coveragePct * 10).rounded() / 10,
            sysCPU: sysCPU.metric,
            sysGPU: sysGPU.metric,
            aneUsage: aneUsage.metric,
            sysMemBytes: sysMemBytes.metric,
            sysMemPct: sysMemPct.metric,
            swapUsedBytes: swapUsed.metric,
            sysPowerWatts: sysPower.metric,
            cpuPowerWatts: cpuPower.metric,
            gpuPowerWatts: gpuPower.metric,
            anePowerWatts: anePower.metric,
            estimatedEnergyWh: estimatedWh,
            dramReadGBps: dramRead.metric,
            dramWriteGBps: dramWrite.metric,
            diskReadBps: diskRead.metric,
            diskWriteBps: diskWrite.metric,
            worstThermalState: worstThermal,
            cliptoActiveSamples: cliptoActiveSamples,
            cliptoMaxProcesses: cliptoMaxProcs,
            cliptoCPUPercent: cliptoCPU.metric,
            cliptoMemoryBytes: cliptoMem.metric,
            cliptoGPUPercent: cliptoGPU.metric,
            cliptoDiskReadBps: cliptoDiskRead.metric,
            cliptoDiskWriteBps: cliptoDiskWrite.metric,
            cmsTotalCPUPercent: cmsCPUTracker.metric,
            cmsTotalGPUPercent: cmsGPU.metric,
            cmsTotalMemoryBytes: cmsMemTracker.metric,
            cmsProcesses: cmsProcesses,
            series: series
        )
    }

    // MARK: - Private Helpers

    private func fetchCMSBuckets(
        from: Date,
        to: Date,
        bucketSeconds: Int
    ) throws -> [Int64: (cpu: Double?, mem: Double?)] {
        let b = max(1, bucketSeconds)
        let sql: String
        if b == 1 {
            sql = """
            SELECT CAST(timestamp AS INTEGER), total_cpu_percent, total_memory_bytes
            FROM cms_frames
            WHERE timestamp BETWEEN ? AND ?
            ORDER BY timestamp;
            """
        } else {
            sql = """
            SELECT CAST(timestamp / \(b) AS INTEGER), AVG(total_cpu_percent), AVG(total_memory_bytes)
            FROM cms_frames
            WHERE timestamp BETWEEN ? AND ?
            GROUP BY CAST(timestamp / \(b) AS INTEGER)
            ORDER BY timestamp;
            """
        }
        return try withStatement(sql) { stmt in
            try check(sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970))
            try check(sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970))
            var dict: [Int64: (cpu: Double?, mem: Double?)] = [:]
            while try nextRow(stmt) {
                let key = sqlite3_column_int64(stmt, 0)
                dict[key] = (optionalDouble(stmt, 1), optionalDouble(stmt, 2))
            }
            return dict
        }
    }

    private func fetchCMSProcessSummary(intervalsMs: [(Int64, Int64)]) throws -> [AlignedCMSProcessItem] {
        struct ProcAcc {
            var identities: Set<String> = []
            var cpuSum: Double = 0
            var cpuCnt: Int = 0
            var cpuMax: Double?
            var memSum: Double = 0
            var memCnt: Int = 0
            var memMax: Double?
        }

        var byName: [String: ProcAcc] = [:]
        for (sMs, eMs) in intervalsMs {
            let sSec = Double(sMs) / 1_000.0
            let eSec = Double(eMs) / 1_000.0
            try withStatement("""
            SELECT p.name, p.session_id, p.pid, p.start_time, p.cpu_percent, p.memory_bytes
            FROM cms_frames f
            JOIN cms_process_samples p ON p.session_id = f.session_id AND p.sequence = f.sequence
            WHERE f.timestamp BETWEEN ? AND ?;
            """) { stmt in
                try check(sqlite3_bind_double(stmt, 1, sSec))
                try check(sqlite3_bind_double(stmt, 2, eSec))
                while try nextRow(stmt) {
                    guard let namePtr = sqlite3_column_text(stmt, 0),
                          let sessPtr = sqlite3_column_text(stmt, 1) else { continue }
                    let name = String(cString: namePtr)
                    let sess = String(cString: sessPtr)
                    let pid = sqlite3_column_int(stmt, 2)
                    let st = sqlite3_column_int64(stmt, 3)

                    var acc = byName[name] ?? ProcAcc()
                    acc.identities.insert("\(sess):\(pid):\(st)")
                    if let cpu = optionalDouble(stmt, 4), cpu.isFinite, cpu >= 0 {
                        acc.cpuSum += cpu
                        acc.cpuCnt += 1
                        acc.cpuMax = max(acc.cpuMax ?? cpu, cpu)
                    }
                    if let mem = optionalDouble(stmt, 5), mem.isFinite, mem >= 0 {
                        acc.memSum += mem
                        acc.memCnt += 1
                        acc.memMax = max(acc.memMax ?? mem, mem)
                    }
                    byName[name] = acc
                }
            }
        }

        return byName.map { name, acc in
            AlignedCMSProcessItem(
                name: name,
                instanceCount: acc.identities.count,
                avgCPUPercent: acc.cpuCnt > 0 ? acc.cpuSum / Double(acc.cpuCnt) : nil,
                maxCPUPercent: acc.cpuMax,
                avgMemoryBytes: acc.memCnt > 0 ? acc.memSum / Double(acc.memCnt) : nil,
                maxMemoryBytes: acc.memMax
            )
        }
        .sorted { ($0.maxMemoryBytes ?? 0) > ($1.maxMemoryBytes ?? 0) }
    }

    private func emptyAlignedReport(
        startMs: Int64,
        endMs: Int64,
        targetActiveSeconds: Double = 0
    ) -> AlignedHardwareReport {
        let empty = AlignedStatMetric(avg: nil, max: nil, min: nil, p95: nil, count: 0)
        return AlignedHardwareReport(
            hasData: false,
            sampleCount: 0,
            cmsFrameCount: 0,
            windowStartMs: startMs,
            windowEndMs: endMs,
            windowStartText: DAGSCAnalyzer.formatTimestampMs(startMs),
            windowEndText: DAGSCAnalyzer.formatTimestampMs(endMs),
            targetActiveSeconds: targetActiveSeconds,
            coveredSeconds: 0,
            coveragePercent: 0,
            sysCPU: empty, sysGPU: empty, aneUsage: empty,
            sysMemBytes: empty, sysMemPct: empty, swapUsedBytes: empty,
            sysPowerWatts: empty, cpuPowerWatts: empty, gpuPowerWatts: empty, anePowerWatts: empty,
            estimatedEnergyWh: nil,
            dramReadGBps: empty, dramWriteGBps: empty,
            diskReadBps: empty, diskWriteBps: empty,
            worstThermalState: "unknown",
            cliptoActiveSamples: 0, cliptoMaxProcesses: 0,
            cliptoCPUPercent: empty, cliptoMemoryBytes: empty, cliptoGPUPercent: empty,
            cliptoDiskReadBps: empty, cliptoDiskWriteBps: empty,
            cmsTotalCPUPercent: empty, cmsTotalGPUPercent: empty, cmsTotalMemoryBytes: empty,
            cmsProcesses: [], series: []
        )
    }

    private static func thermalSeverity(_ state: String) -> Int {
        switch state {
        case "nominal", "正常", "Normal": 1
        case "fair", "温热", "Warm": 2
        case "serious", "较高", "High": 3
        case "critical", "严重", "Critical": 4
        default: 0
        }
    }
}
