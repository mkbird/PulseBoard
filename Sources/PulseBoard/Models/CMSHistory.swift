import Foundation

struct CMSHistoryCursor: Sendable {
    let sessionID: String
    let sequence: Int64
}

/// One observed CMS frame. Only processes present in the raw observation are
/// stored; confirmed absences are represented by complete frames, including
/// empty ones. Session + sequence preserves order when the wall clock changes.
struct CMSHistoryFrame: Sendable {
    let sessionID: String
    let sessionStartedAt: Date
    let sequence: Int64
    /// Changes whenever sampling is explicitly suspended. CPU baselines must
    /// not cross segments, even if the monotonic clock excludes time asleep.
    let segment: Int64
    let maximumGap: TimeInterval
    let raw: CMSRawSnapshot
    let totalCPUPercent: Double?
    let totalMemoryBytes: Double?
    let processCPUPercent: [CMSProcessID: Double]

    static func capture(
        sessionID: String, sequence: Int64, segment: Int64,
        maximumGap: TimeInterval, raw: CMSRawSnapshot, statistics: CMSSessionSnapshot
    ) -> CMSHistoryFrame {
        let observedIDs = Set(raw.processes.map(\.id))
        let cpu = statistics.processes.reduce(into: [CMSProcessID: Double]()) { values, row in
            if observedIDs.contains(row.id), let value = row.cpu.current {
                values[row.id] = value
            }
        }
        return CMSHistoryFrame(
            sessionID: sessionID, sessionStartedAt: statistics.startedAt,
            sequence: sequence, segment: segment, maximumGap: maximumGap,
            raw: raw, totalCPUPercent: statistics.cpu.current,
            totalMemoryBytes: statistics.memory.current, processCPUPercent: cpu
        )
    }
}
