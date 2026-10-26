import Foundation

struct LiveSampleDTO: Codable, Sendable {
    let tsMs: Int64
    let cpuUsage: Double
    let gpuUsage: Double?
    let aneUsage: Double?
    let memoryUsage: Double
    let memoryUsedBytes: Double
    let memoryTotalBytes: Double
    let memoryPressure: Double
    let swapUsedBytes: Double
    let swapTotalBytes: Double
    let anePowerWatts: Double?
    let cpuPowerWatts: Double?
    let gpuPowerWatts: Double?
    let systemPowerWatts: Double?
    let memoryReadGBps: Double?
    let memoryWriteGBps: Double?
    let diskReadBps: Double
    let diskWriteBps: Double
    let diskFreeBytes: Double
    let diskTotalBytes: Double
    let netDownBps: Double
    let netUpBps: Double
    let thermalState: String
    let cliptoRunning: Bool
    let cliptoCPUPercent: Double?
    let cliptoMemoryBytes: Double?
    let cliptoDiskReadBps: Double?
    let cliptoDiskWriteBps: Double?
    let cliptoProcessCount: Int?
    let cliptoGPUPercent: Double?

    init(_ s: MetricSample) {
        tsMs = Int64((s.timestamp.timeIntervalSince1970 * 1_000.0).rounded())
        cpuUsage = s.cpuUsage
        gpuUsage = s.gpuUsage
        aneUsage = s.aneUsage
        memoryUsage = s.memoryUsage
        memoryUsedBytes = s.memoryUsedBytes
        memoryTotalBytes = s.memoryTotalBytes
        memoryPressure = s.memoryPressure
        swapUsedBytes = s.swapUsedBytes
        swapTotalBytes = s.swapTotalBytes
        anePowerWatts = s.anePowerWatts
        cpuPowerWatts = s.cpuPowerWatts
        gpuPowerWatts = s.gpuPowerWatts
        systemPowerWatts = s.systemPowerWatts
        memoryReadGBps = s.memoryReadGBps
        memoryWriteGBps = s.memoryWriteGBps
        diskReadBps = s.diskReadBytesPerSecond
        diskWriteBps = s.diskWriteBytesPerSecond
        diskFreeBytes = s.diskFreeBytes
        diskTotalBytes = s.diskTotalBytes
        netDownBps = s.networkDownBytesPerSecond
        netUpBps = s.networkUpBytesPerSecond
        thermalState = s.thermalState
        cliptoRunning = s.cliptoRunning
        cliptoCPUPercent = s.cliptoCPUPercent
        cliptoMemoryBytes = s.cliptoMemoryBytes
        cliptoDiskReadBps = s.cliptoDiskReadBytesPerSecond
        cliptoDiskWriteBps = s.cliptoDiskWriteBytesPerSecond
        cliptoProcessCount = s.cliptoProcessCount
        cliptoGPUPercent = s.cliptoGPUPercent
    }

    enum CodingKeys: String, CodingKey {
        case tsMs = "ts_ms"
        case cpuUsage = "cpu_usage"
        case gpuUsage = "gpu_usage"
        case aneUsage = "ane_usage"
        case memoryUsage = "memory_usage"
        case memoryUsedBytes = "memory_used_bytes"
        case memoryTotalBytes = "memory_total_bytes"
        case memoryPressure = "memory_pressure"
        case swapUsedBytes = "swap_used_bytes"
        case swapTotalBytes = "swap_total_bytes"
        case anePowerWatts = "ane_power_watts"
        case cpuPowerWatts = "cpu_power_watts"
        case gpuPowerWatts = "gpu_power_watts"
        case systemPowerWatts = "system_power_watts"
        case memoryReadGBps = "memory_read_gbps"
        case memoryWriteGBps = "memory_write_gbps"
        case diskReadBps = "disk_read_bps"
        case diskWriteBps = "disk_write_bps"
        case diskFreeBytes = "disk_free_bytes"
        case diskTotalBytes = "disk_total_bytes"
        case netDownBps = "net_down_bps"
        case netUpBps = "net_up_bps"
        case thermalState = "thermal_state"
        case cliptoRunning = "clipto_running"
        case cliptoCPUPercent = "clipto_cpu_percent"
        case cliptoMemoryBytes = "clipto_memory_bytes"
        case cliptoDiskReadBps = "clipto_disk_read_bps"
        case cliptoDiskWriteBps = "clipto_disk_write_bps"
        case cliptoProcessCount = "clipto_process_count"
        case cliptoGPUPercent = "clipto_gpu_percent"
    }
}

struct LiveCMSMetricDTO: Codable, Sendable {
    let current: Double?
    let average: Double?
    let peak: Double?
    let validDurationSec: Double

    init(_ m: CMSMetricStatistics) {
        current = m.current
        average = m.average
        peak = m.peak
        validDurationSec = m.validDuration
    }

    enum CodingKeys: String, CodingKey {
        case current, average, peak
        case validDurationSec = "valid_duration_sec"
    }
}

struct LiveCMSProcessDTO: Codable, Sendable {
    let pid: Int32
    let startTime: UInt64
    let name: String
    let state: String
    let cpu: LiveCMSMetricDTO
    let memory: LiveCMSMetricDTO

    init(_ row: CMSProcessRow) {
        pid = row.id.pid
        startTime = row.id.startTime
        name = row.name
        state = switch row.state {
        case .running: "running"
        case .exited: "exited"
        case .unavailable: "unavailable"
        }
        cpu = LiveCMSMetricDTO(row.cpu)
        memory = LiveCMSMetricDTO(row.memory)
    }

    enum CodingKeys: String, CodingKey {
        case pid
        case startTime = "start_time"
        case name, state, cpu, memory
    }
}

struct LiveCMSSessionDTO: Codable, Sendable {
    let startedAtMs: Int64
    let startedAtText: String
    let runningCount: Int
    let totalInstances: Int
    let isComplete: Bool
    let isSuspended: Bool
    let cpu: LiveCMSMetricDTO
    let memory: LiveCMSMetricDTO
    let processes: [LiveCMSProcessDTO]

    init(_ s: CMSSessionSnapshot) {
        let ms = Int64((s.startedAt.timeIntervalSince1970 * 1_000.0).rounded())
        startedAtMs = ms
        startedAtText = DAGSCAnalyzer.formatTimestampMs(ms)
        runningCount = s.runningCount
        totalInstances = s.processes.count
        isComplete = s.isComplete
        isSuspended = s.isSuspended
        cpu = LiveCMSMetricDTO(s.cpu)
        memory = LiveCMSMetricDTO(s.memory)
        processes = s.processes.map(LiveCMSProcessDTO.init)
    }

    enum CodingKeys: String, CodingKey {
        case startedAtMs = "started_at_ms"
        case startedAtText = "started_at_text"
        case runningCount = "running_count"
        case totalInstances = "total_instances"
        case isComplete = "is_complete"
        case isSuspended = "is_suspended"
        case cpu, memory, processes
    }
}

enum WebConsoleRouter {
    static func handle(
        request: HTTPRequest,
        monitor: MonitorStore,
        history: HistoryRepository
    ) async -> HTTPResponse {
        let path = request.path

        if path == "/" || path == "/index.html" || path == "/dagsc_analyzer.html" {
            if let htmlData = loadWebConsoleHTML() {
                return .html(200, htmlData)
            }
            return .jsonError(500, "找不到网页控制台资源文件 web_console.html")
        }

        if path == "/favicon.ico" {
            return HTTPResponse(statusCode: 204, contentType: "image/x-icon", extraHeaders: [], body: Data())
        }

        let dbURL = (try? await history.resolvedDatabaseURL()) ?? defaultHistoryDBURL()
        let port = await MainActor.run { monitor.webServerPort }
        let env = SystemEnvironmentService.current(webPort: port, historyDBURL: dbURL)

        if path == "/api/bootstrap" || path == "/api/default-info" {
            struct BootstrapPayload: Encodable {
                let ok = true
                let environment: SystemEnvironmentInfo
                let detected_username: String
                let default_dagsc_dir: String
            }
            return .json(200, BootstrapPayload(
                environment: env,
                detected_username: env.username,
                default_dagsc_dir: env.defaultDagscDir
            ))
        }

        if path == "/api/monitor/live" {
            let liveSnapshot = await MainActor.run { () -> (MetricSample?, CMSSessionSnapshot, Double, Int, Bool) in
                (
                    monitor.latest,
                    monitor.cmsSession,
                    monitor.samplingInterval,
                    monitor.retentionDays,
                    monitor.enhancedMetricsAvailable
                )
            }
            struct LivePayload: Encodable {
                let ok = true
                let sampling_interval_sec: Double
                let retention_days: Int
                let enhanced_available: Bool
                let latest: LiveSampleDTO?
                let cms: LiveCMSSessionDTO
                let environment: SystemEnvironmentInfo
            }
            return .json(200, LivePayload(
                sampling_interval_sec: liveSnapshot.2,
                retention_days: liveSnapshot.3,
                enhanced_available: liveSnapshot.4,
                latest: liveSnapshot.0.map(LiveSampleDTO.init),
                cms: LiveCMSSessionDTO(liveSnapshot.1),
                environment: env
            ))
        }

        if path == "/api/monitor/history" {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
            let toMs = request.query("to_ms").flatMap(Int64.init) ?? nowMs
            let fromMs = request.query("from_ms").flatMap(Int64.init) ?? (toMs - 15 * 60 * 1_000)
            let maxPts = request.query("max_points").flatMap(Int.init) ?? 600
            let fromDate = Date(timeIntervalSince1970: Double(fromMs) / 1_000.0)
            let toDate = Date(timeIntervalSince1970: Double(max(fromMs + 1_000, toMs)) / 1_000.0)

            do {
                let points = try await history.fetchWebHistory(from: fromDate, to: toDate, maxPoints: maxPts)
                struct HistoryPayload: Encodable {
                    let ok = true
                    let from_ms: Int64
                    let to_ms: Int64
                    let points: [AlignedTimeSeriesPoint]
                }
                return .json(200, HistoryPayload(from_ms: fromMs, to_ms: toMs, points: points))
            } catch {
                return .jsonError(500, error.localizedDescription)
            }
        }

        if path == "/api/monitor/aligned" {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
            let toMs = request.query("to_ms").flatMap(Int64.init) ?? nowMs
            let fromMs = request.query("from_ms").flatMap(Int64.init) ?? (toMs - 60 * 60 * 1_000)
            do {
                let aligned = try await history.fetchAlignedReport(
                    activeIntervalsMs: [[fromMs, toMs]],
                    fallbackStartMs: fromMs,
                    fallbackEndMs: toMs
                )
                struct AlignedOnlyPayload: Encodable {
                    let ok = true
                    let environment: SystemEnvironmentInfo
                    let aligned_hardware: AlignedHardwareReport
                }
                return .json(200, AlignedOnlyPayload(environment: env, aligned_hardware: aligned))
            } catch {
                return .jsonError(500, error.localizedDescription)
            }
        }

        if path == "/api/dagsc/analyze" || path == "/api/analyze" {
            let options = parseDAGSCQueryOptions(from: request)
            do {
                var result = try DAGSCAnalyzer.analyze(options: options, environment: env)
                let aligned = try? await history.fetchAlignedReport(
                    activeIntervalsMs: result.activeIntervalsMs,
                    fallbackStartMs: result.sliceStartMs,
                    fallbackEndMs: result.sliceEndMs
                )
                result.alignedHardware = aligned
                return .json(200, result)
            } catch {
                return .jsonError(400, error.localizedDescription)
            }
        }

        if path == "/api/report/markdown" {
            let options = parseDAGSCQueryOptions(from: request)
            let mdOptions = parseMarkdownOptions(from: request)
            do {
                var result = try DAGSCAnalyzer.analyze(options: options, environment: env)
                result.alignedHardware = try? await history.fetchAlignedReport(
                    activeIntervalsMs: result.activeIntervalsMs,
                    fallbackStartMs: result.sliceStartMs,
                    fallbackEndMs: result.sliceEndMs
                )
                let md = MarkdownReportGenerator.generate(analysis: result, options: mdOptions)
                let filename = "\(MarkdownReportGenerator.fileStem(result)).md"
                if request.query("download") == "1" {
                    return .download(
                        filename: filename,
                        contentType: "text/markdown; charset=utf-8",
                        data: Data(md.utf8)
                    )
                }
                struct MarkdownPayload: Encodable {
                    let ok = true
                    let filename: String
                    let markdown: String
                }
                return .json(200, MarkdownPayload(filename: filename, markdown: md))
            } catch {
                return .jsonError(400, error.localizedDescription)
            }
        }

        if path == "/api/report/profile" {
            // Manually entered 评测人 / 局域网 IP shared with the menu bar and CLI.
            if request.method == "POST",
               let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
                let reporter = obj["reporter"] as? String
                let lanHost = obj["lan_host"] as? String
                await MainActor.run {
                    if let reporter { monitor.reporterName = reporter }
                    if let lanHost { monitor.reportLANHost = lanHost }
                }
            }
            struct ProfilePayload: Encodable {
                let ok = true
                let reporter: String
                let lan_host: String
                let web_port: Int
                let detected_lan_ips: [String]
            }
            return .json(200, ProfilePayload(
                reporter: ReportProfile.reporter,
                lan_host: ReportProfile.lanHost,
                web_port: env.webPort,
                detected_lan_ips: env.lanIPs
            ))
        }

        if path == "/api/report/csv-labels" {
            // Row names of the single-column CSV, one per line (for setting up the tracking sheet once).
            let text = ReportCSVGenerator.rowLabels.joined(separator: "\n")
            return HTTPResponse(statusCode: 200, contentType: "text/plain; charset=utf-8", extraHeaders: [], body: Data(text.utf8))
        }

        if path == "/api/report/csv" {
            // Single-column CSV: row 1 = Clipto version, then one metric per row.
            // ?download=1 → attachment; ?format=column → newline-separated values for clipboard;
            // ?with_labels=1 → two columns (name,value) for checking.
            do {
                var result = try DAGSCAnalyzer.analyze(options: parseDAGSCQueryOptions(from: request), environment: env)
                result.alignedHardware = try? await history.fetchAlignedReport(
                    activeIntervalsMs: result.activeIntervalsMs,
                    fallbackStartMs: result.sliceStartMs,
                    fallbackEndMs: result.sliceEndMs
                )
                if request.query("format") == "column" {
                    let text = ReportCSVGenerator.columnText(analysis: result)
                    return HTTPResponse(statusCode: 200, contentType: "text/plain; charset=utf-8", extraHeaders: [], body: Data(text.utf8))
                }
                let csv = ReportCSVGenerator.generate(analysis: result, includeLabels: request.query("with_labels") == "1")
                if request.query("download") == "1" {
                    return .download(filename: ReportCSVGenerator.fileName(result), contentType: "text/csv; charset=utf-8", data: Data(csv.utf8))
                }
                return HTTPResponse(statusCode: 200, contentType: "text/csv; charset=utf-8", extraHeaders: [], body: Data(csv.utf8))
            } catch {
                return .jsonError(400, error.localizedDescription)
            }
        }

        if path == "/api/report/image" {
            // POST {"markdown": "...", "filename": "..."} renders exactly what the web console shows.
            // Without a markdown body the server generates the report itself from the slice params.
            var bodyJSON: [String: Any] = [:]
            if request.method == "POST", !request.body.isEmpty,
               let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
                bodyJSON = obj
            }
            do {
                let markdown: String
                var stem = "Clipto晨报"
                if let provided = bodyJSON["markdown"] as? String,
                   !provided.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    markdown = provided
                    if let fn = bodyJSON["filename"] as? String, !fn.isEmpty {
                        stem = (fn as NSString).deletingPathExtension
                    }
                } else {
                    var result = try DAGSCAnalyzer.analyze(options: parseDAGSCQueryOptions(from: request), environment: env)
                    result.alignedHardware = try? await history.fetchAlignedReport(
                        activeIntervalsMs: result.activeIntervalsMs,
                        fallbackStartMs: result.sliceStartMs,
                        fallbackEndMs: result.sliceEndMs
                    )
                    markdown = MarkdownReportGenerator.generate(analysis: result, options: parseMarkdownOptions(from: request))
                    stem = MarkdownReportGenerator.fileStem(result)
                }
                let png = try await MainActor.run { try ReportImageRenderer.renderPNG(markdown: markdown) }
                if request.query("download") == "1" {
                    return .download(filename: "\(stem).png", contentType: "image/png", data: png)
                }
                return HTTPResponse(statusCode: 200, contentType: "image/png", extraHeaders: [], body: png)
            } catch {
                return .jsonError(400, error.localizedDescription)
            }
        }

        if path == "/api/export/system-csv" {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
            let toMs = request.query("to_ms").flatMap(Int64.init) ?? nowMs
            let fromMs = request.query("from_ms").flatMap(Int64.init) ?? (toMs - 15 * 60 * 1_000)
            let fromDate = Date(timeIntervalSince1970: Double(fromMs) / 1_000.0)
            let toDate = Date(timeIntervalSince1970: Double(max(fromMs + 1_000, toMs)) / 1_000.0)
            do {
                let raw = try await history.fetchRaw(from: fromDate, to: toDate)
                let csv = CSVExporter.csv(samples: raw)
                let fn = "CliptoPulse-System-\(DAGSCAnalyzer.formatDayLocal(fromMs)).csv"
                return .download(filename: fn, contentType: "text/csv; charset=utf-8", data: Data(csv.utf8))
            } catch {
                return .jsonError(500, error.localizedDescription)
            }
        }

        if path == "/api/export/cms-csv" {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
            let toMs = request.query("to_ms").flatMap(Int64.init) ?? nowMs
            let fromMs = request.query("from_ms").flatMap(Int64.init) ?? (toMs - 15 * 60 * 1_000)
            let fromDate = Date(timeIntervalSince1970: Double(fromMs) / 1_000.0)
            let toDate = Date(timeIntervalSince1970: Double(max(fromMs + 1_000, toMs)) / 1_000.0)
            do {
                let csv = try await history.buildCMSCSVString(from: fromDate, to: toDate)
                let fn = "CliptoPulse-CMS-\(DAGSCAnalyzer.formatDayLocal(fromMs)).csv"
                return .download(filename: fn, contentType: "text/csv; charset=utf-8", data: Data(csv.utf8))
            } catch {
                return .jsonError(500, error.localizedDescription)
            }
        }

        return .jsonError(404, "未找到请求的接口或页面：\(path)")
    }

    // MARK: - Helpers

    private static func parseDAGSCQueryOptions(from request: HTTPRequest) -> DAGSCQueryOptions {
        var jsonBody: [String: Any] = [:]
        if request.method == "POST", !request.body.isEmpty,
           let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
            jsonBody = obj
        }

        func str(_ key: String) -> String? {
            if let q = request.query(key), !q.isEmpty { return q }
            if let v = jsonBody[key] as? String, !v.isEmpty { return v }
            return nil
        }

        func int64Val(_ key: String) -> Int64? {
            if let q = request.query(key), let v = Int64(q) { return v }
            if let n = jsonBody[key] as? NSNumber { return n.int64Value }
            if let s = jsonBody[key] as? String, let v = Int64(s) { return v }
            return nil
        }

        var opts = DAGSCQueryOptions()
        opts.inputPath = str("path") ?? ""
        opts.sliceMode = str("slice_mode") ?? "auto"
        opts.batchID = str("batch_id")
        opts.customFromMs = int64Val("from_ms")
        opts.customToMs = int64Val("to_ms")
        if let gapMin = int64Val("gap_min"), gapMin >= 1 {
            opts.batchGapMs = gapMin * 60 * 1_000
        }
        return opts
    }

    private static func parseMarkdownOptions(from request: HTTPRequest) -> MarkdownReportOptions {
        var jsonBody: [String: Any] = [:]
        if request.method == "POST", !request.body.isEmpty,
           let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
            jsonBody = obj
        }
        func str(_ key: String) -> String? {
            request.query(key) ?? (jsonBody[key] as? String)
        }
        var opts = MarkdownReportOptions() // reporter / lanHost default to the saved profile
        if let v = str("reporter") { opts.reporter = v }
        if let v = str("lan_host") { opts.lanHost = v }
        opts.changeSummary = str("change_summary") ?? ""
        opts.notes = str("notes") ?? ""
        return opts
    }

    private static func loadWebConsoleHTML() -> Data? {
        if let url = L10n.resourceURL(forResource: "web_console", withExtension: "html"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        // Fallback when running unbundled from package directory
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/web_console.html")
        return try? Data(contentsOf: fallback)
    }

    private static func defaultHistoryDBURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PulseBoard/history.sqlite")
    }
}
