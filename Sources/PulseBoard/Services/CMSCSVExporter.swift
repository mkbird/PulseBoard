import Foundation
import CliptoPulseCore
#if canImport(AppKit)
import AppKit
#endif

enum CMSCSVExporter {
#if canImport(AppKit)
    @MainActor
    static func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let fileDate = DateFormatter()
        fileDate.locale = Locale(identifier: "en_US_POSIX")
        fileDate.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "PulseBoard-CMS-\(fileDate.string(from: Date())).csv"
        panel.title = L10n.text("cms.export_panel_title")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
#endif

    static func csv(frames: [CMSHistoryFrame], includeHeader: Bool = true) -> String {
        var rows = includeHeader ? [
            "row_type,session_id,session_started_at,session_started_unix_seconds,sequence,segment,timestamp,timestamp_unix_seconds,monotonic_seconds,maximum_gap_seconds,pid,process_start_time_us,process_name,cpu_percent,memory_bytes,cpu_seconds,enumeration_valid,unreadable_count,statistics_version"
        ] : []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for frame in frames {
            let context = [
                frame.sessionID,
                formatter.string(from: frame.sessionStartedAt),
                number(frame.sessionStartedAt.timeIntervalSince1970),
                String(frame.sequence), String(frame.segment),
                formatter.string(from: frame.raw.timestamp),
                number(frame.raw.timestamp.timeIntervalSince1970),
                number(frame.raw.monotonicSeconds), number(frame.maximumGap)
            ]
            let completeness = [
                frame.raw.enumerationValid ? "true" : "false",
                String(frame.raw.unreadableCount), String(frame.statisticsVersion)
            ]
            rows.append(row(
                ["total"] + context + ["", "", "", number(frame.totalCPUPercent), number(frame.totalMemoryBytes), ""]
                    + completeness
            ))
            for process in frame.raw.processes {
                rows.append(row(
                    ["process"] + context + [
                        String(process.id.pid), String(process.id.startTime), process.name,
                        number(frame.processCPUPercent[process.id]), number(process.memoryBytes), number(process.cpuSeconds)
                    ] + completeness
                ))
            }
        }
        return rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n"
    }

    private static func row(_ fields: [String]) -> String {
        fields.map { field in
            guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
                return field
            }
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }.joined(separator: ",")
    }

    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        // Keep sufficient precision to reconstruct intervals and CPU deltas;
        // String(Double) uses a locale-independent decimal representation.
        return String(value)
    }
}
