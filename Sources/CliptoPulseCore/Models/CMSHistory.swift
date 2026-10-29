import Foundation

package struct CMSHistoryCursor: Sendable {
    package let sessionID: String
    package let sequence: Int64

    package init(sessionID: String, sequence: Int64) {
        self.sessionID = sessionID
        self.sequence = sequence
    }
}

/// One observed CMS frame. Only processes present in the raw observation are
/// stored; confirmed absences are represented by complete frames, including
/// empty ones. Session + sequence preserves order when the wall clock changes.
package struct CMSHistoryFrame: Sendable {
    package let sessionID: String
    package let sessionStartedAt: Date
    package let sequence: Int64
    /// Changes whenever sampling is explicitly suspended. CPU baselines must
    /// not cross segments, even if the monotonic clock excludes time asleep.
    package let segment: Int64
    package let maximumGap: TimeInterval
    package let raw: CMSRawSnapshot
    package let totalCPUPercent: Double?
    package let totalMemoryBytes: Double?
    package let processCPUPercent: [CMSProcessID: Double]
    /// 1: complete-system gate; 2: sum the observed CMS rows independently.
    package var statisticsVersion: Int = 2

    package init(
        sessionID: String,
        sessionStartedAt: Date,
        sequence: Int64,
        segment: Int64,
        maximumGap: TimeInterval,
        raw: CMSRawSnapshot,
        totalCPUPercent: Double?,
        totalMemoryBytes: Double?,
        processCPUPercent: [CMSProcessID: Double],
        statisticsVersion: Int = 2
    ) {
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.sequence = sequence
        self.segment = segment
        self.maximumGap = maximumGap
        self.raw = raw
        self.totalCPUPercent = totalCPUPercent
        self.totalMemoryBytes = totalMemoryBytes
        self.processCPUPercent = processCPUPercent
        self.statisticsVersion = statisticsVersion
    }

    package static func capture(
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
            totalMemoryBytes: statistics.memory.current, processCPUPercent: cpu,
            statisticsVersion: statistics.statisticsVersion
        )
    }
}
