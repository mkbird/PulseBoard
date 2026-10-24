import Foundation

struct CMSProcessID: Hashable, Sendable {
    let pid: Int32
    /// BSD process start time, in microseconds since the Unix epoch.
    let startTime: UInt64
}

struct CMSProcessReading: Sendable {
    let id: CMSProcessID
    let name: String
    let cpuSeconds: Double?
    let memoryBytes: Double?
}

struct CMSRawSnapshot: Sendable {
    let timestamp: Date
    let monotonicSeconds: Double
    let processes: [CMSProcessReading]
    let enumerationValid: Bool
    let unreadableCount: Int

    var membershipComplete: Bool { enumerationValid && unreadableCount == 0 }
}

struct CMSMetricStatistics: Sendable {
    let current: Double?
    let average: Double?
    let peak: Double?
    let validDuration: TimeInterval
}

enum CMSProcessState: Sendable {
    case running, exited, unavailable
}

struct CMSProcessRow: Identifiable, Sendable {
    let id: CMSProcessID
    let name: String
    let state: CMSProcessState
    let cpu: CMSMetricStatistics
    let memory: CMSMetricStatistics
}

struct CMSSessionSnapshot: Sendable {
    let startedAt: Date
    let processes: [CMSProcessRow]
    let runningCount: Int
    let cpu: CMSMetricStatistics
    let memory: CMSMetricStatistics
    let isComplete: Bool
    let isSuspended: Bool
}

private struct CMSMetricAccumulator {
    var current: Double?
    var peak: Double?
    var integral: Double = 0
    var validDuration: TimeInterval = 0

    mutating func record(current: Double?, intervalValue: Double?, duration: TimeInterval) {
        self.current = valid(current)
        if let value = self.current { peak = max(peak ?? value, value) }
        if duration > 0, let value = valid(intervalValue) {
            integral += value * duration
            validDuration += duration
        }
    }

    var statistics: CMSMetricStatistics {
        CMSMetricStatistics(current: current, average: validDuration > 0 ? integral / validDuration : nil,
                            peak: peak, validDuration: validDuration)
    }
}

private func valid(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
}

/// Keeps only counters per process instance, never the full sequence of samples.
/// CPU represents the interval ending at the current sample; memory uses the
/// previous observed footprint over the interval (a sample-and-hold estimate).
struct CMSProcessSession {
    private struct Entry {
        let id: CMSProcessID
        var name: String
        var state: CMSProcessState = .running
        var cpu = CMSMetricAccumulator()
        var memory = CMSMetricAccumulator()

        var row: CMSProcessRow {
            CMSProcessRow(id: id, name: name, state: state, cpu: cpu.statistics, memory: memory.statistics)
        }
    }

    let startedAt: Date
    private var entries: [CMSProcessID: Entry] = [:]
    private var previous: CMSRawSnapshot?
    private var totalCPU = CMSMetricAccumulator()
    private var totalMemory = CMSMetricAccumulator()
    // New identities inherit only time in which successful enumerations proved
    // they were not in the matching process group. Unknown intervals stay out.
    private var confirmedAbsenceDuration: TimeInterval = 0
    private var runningCount = 0
    private var isComplete = false
    private var isSuspended = false

    init(startedAt: Date = Date()) { self.startedAt = startedAt }

    var snapshot: CMSSessionSnapshot {
        CMSSessionSnapshot(
            startedAt: startedAt,
            processes: entries.values.map(\.row).sorted {
                $0.id.pid == $1.id.pid ? $0.id.startTime < $1.id.startTime : $0.id.pid < $1.id.pid
            },
            runningCount: runningCount, cpu: totalCPU.statistics, memory: totalMemory.statistics,
            isComplete: isComplete, isSuspended: isSuspended
        )
    }

    mutating func suspend() {
        previous = nil
        isSuspended = true
        isComplete = false
        totalCPU.current = nil
        totalMemory.current = nil
        for id in Array(entries.keys) {
            entries[id]?.cpu.current = nil
            entries[id]?.memory.current = nil
        }
    }

    mutating func consume(_ sample: CMSRawSnapshot, maximumGap: TimeInterval = 30) {
        let old = previous
        let delta = old.map { sample.monotonicSeconds - $0.monotonicSeconds } ?? 0
        let duration = delta.isFinite && delta > 0 && delta <= maximumGap ? delta : 0
        let current = Dictionary(sample.processes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let prior = Dictionary((old?.processes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        isSuspended = false
        runningCount = current.count
        isComplete = sample.membershipComplete && current.values.allSatisfy {
            valid($0.cpuSeconds) != nil && valid($0.memoryBytes) != nil
        }

        for reading in current.values where entries[reading.id] == nil {
            var entry = Entry(id: reading.id, name: reading.name)
            entry.cpu.validDuration = confirmedAbsenceDuration
            entry.memory.validDuration = confirmedAbsenceDuration
            entries[reading.id] = entry
        }

        var groupCPU: Double? = sample.membershipComplete ? 0 : nil
        // An initial empty group is an observed zero; all other CPU rates need
        // two complete snapshots. An exit's last CPU delta is not observable.
        if !current.isEmpty || !(prior.isEmpty && (old?.membershipComplete ?? true)) {
            if duration == 0 || old?.membershipComplete != true { groupCPU = nil }
        }
        for id in Set(current.keys).union(prior.keys) {
            guard let reading = current[id], let before = prior[id], duration > 0,
                  let nowCPU = valid(reading.cpuSeconds), let beforeCPU = valid(before.cpuSeconds),
                  nowCPU >= beforeCPU else {
                groupCPU = nil
                continue
            }
            if let sum = groupCPU { groupCPU = sum + (nowCPU - beforeCPU) / duration * 100 }
        }

        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            let reading = current[id]
            let before = prior[id]
            let absentNow = reading == nil && sample.membershipComplete
            let absentBefore = before == nil && old?.membershipComplete == true
            let memoryNow = absentNow ? 0 : valid(reading?.memoryBytes)
            let memoryBefore = absentBefore ? 0 : valid(before?.memoryBytes)
            var cpuNow: Double? = absentNow ? 0 : nil
            var cpuInterval: Double?
            if absentNow && absentBefore {
                cpuInterval = 0
            } else if duration > 0, let nowCPU = valid(reading?.cpuSeconds),
                      let beforeCPU = valid(before?.cpuSeconds), nowCPU >= beforeCPU {
                cpuNow = (nowCPU - beforeCPU) / duration * 100
                cpuInterval = cpuNow
            }
            entry.state = absentNow ? .exited : (reading == nil || valid(reading?.cpuSeconds) == nil || memoryNow == nil ? .unavailable : .running)
            if let reading { entry.name = reading.name }
            entry.cpu.record(current: cpuNow, intervalValue: cpuInterval, duration: duration)
            entry.memory.record(current: memoryNow, intervalValue: memoryNow == nil ? nil : memoryBefore, duration: duration)
            entries[id] = entry
        }

        let memoryNow = Self.memoryTotal(sample)
        let memoryBefore = old.flatMap(Self.memoryTotal)
        totalCPU.record(current: groupCPU, intervalValue: groupCPU, duration: duration)
        totalMemory.record(current: memoryNow, intervalValue: memoryNow == nil ? nil : memoryBefore, duration: duration)
        if duration > 0, sample.membershipComplete, old?.membershipComplete == true {
            confirmedAbsenceDuration += duration
        }
        previous = sample
    }

    private static func memoryTotal(_ sample: CMSRawSnapshot) -> Double? {
        guard sample.membershipComplete else { return nil }
        var sum = 0.0
        for reading in sample.processes {
            guard let memory = valid(reading.memoryBytes) else { return nil }
            sum += memory
        }
        return sum
    }
}
