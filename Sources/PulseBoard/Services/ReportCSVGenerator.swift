import Foundation

/// Single-column CSV for pasting into the version-tracking spreadsheet: row 1 is the Clipto version,
/// every following row aligns 1-to-1 with the tracking sheet (no row names in default output).
enum ReportCSVGenerator {
    private struct Row {
        let label: String
        let value: String
    }

    /// Fixed order of the 20 DAGSC `node_type` services in `clipto_asset_analysis`.
    static let standardNodeTypes: [String] = [
        "clip",
        "asr",
        "vlm",
        "dynamic-cbs",
        "face",
        "speaker-detection",
        "transcode",
        "camera-tagging",
        "node-ingest",
        "ai-summarize",
        "embedding",
        "classification",
        "segmentation",
        "segment-image-embedding",
        "vlm-description-embedding",
        "mm_cls",
        "voice",
        "query-recommendation",
        "ner",
        "probe"
    ]

    /// Row names in output order (row 1 = version).
    static var rowLabels: [String] {
        rows(for: nil, remark: "").map(\.label)
    }

    /// Flattens `changeSummary` and `notes` into a single-line remark cell so row counts never shift.
    static func composeRemark(changeSummary: String = "", notes: String = "") -> String {
        func flatten(_ raw: String) -> String {
            raw.components(separatedBy: .newlines)
                .map { line -> String in
                    var s = line.trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("- ") { s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                    return s
                }
                .filter { !$0.isEmpty }
                .joined(separator: "；")
        }
        let parts = [flatten(changeSummary), flatten(notes)].filter { !$0.isEmpty }
        return parts.joined(separator: "｜")
    }

    /// One column, many rows (UTF-8 with BOM so Excel/Numbers detect Chinese correctly).
    static func generate(analysis: DAGSCAnalysisResponse, remark: String = "", includeLabels: Bool = false) -> String {
        let body = rows(for: analysis, remark: remark).map { row in
            includeLabels ? "\(escape(row.label)),\(escape(row.value))" : escape(row.value)
        }
        return "\u{FEFF}" + body.joined(separator: "\r\n") + "\r\n"
    }

    /// Just the values joined by newlines — pastes straight into one spreadsheet column.
    static func columnText(analysis: DAGSCAnalysisResponse, remark: String = "") -> String {
        rows(for: analysis, remark: remark).map(\.value).joined(separator: "\n")
    }

    private static func rows(for a: DAGSCAnalysisResponse?, remark: String) -> [Row] {
        let scope = a?.scopes.assetAnalysis
        let hw = a?.alignedHardware.flatMap { $0.hasData ? $0 : nil }
        let storage = a?.alignedHardware?.storage
        let gb = 1_024.0 * 1_024.0 * 1_024.0

        func num(_ v: Double?, _ digits: Int) -> String {
            guard let v, v.isFinite else { return "" }
            return String(format: "%.\(digits)f", v)
        }
        func bytesGB(_ v: Double?) -> String { num(v.map { $0 / gb }, 2) }
        func time(_ ms: Int64?) -> String {
            guard let ms, ms > 0 else { return "" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
        }

        let speedup = scope.flatMap { $0.wallSpeedup > 0 ? $0.wallSpeedup : nil }
        let speedupByNodeType: [String: Double] = Dictionary(
            (scope?.byNodeType ?? []).map { ($0.nodeType, $0.speedup) },
            uniquingKeysWith: { first, _ in first }
        )
        func nodeSpeedup(_ nodeType: String) -> String {
            guard let v = speedupByNodeType[nodeType], v > 0 else { return "" }
            return num(v, 2)
        }

        var result: [Row] = [
            Row(label: "Clipto Mac 版本号", value: a?.appVersion ?? ""),
            Row(label: "端到端分析速度", value: num(speedup, 2)),
            Row(label: "全 CMS 内存峰值", value: bytesGB(hw?.cmsTotalMemoryBytes.max)),
            Row(label: "全 CMS 内存平均", value: bytesGB(hw?.cmsTotalMemoryBytes.avg)),
            Row(label: "Clipto 进程组内存峰值", value: bytesGB(hw?.cliptoMemoryBytes.max)),
            Row(label: "Clipto 进程组gpu占用率p95", value: num(hw?.cliptoGPUPercent.p95, 1)),
            Row(label: "Clipto 进程组cpu占用率p95", value: num(hw?.cliptoCPUPercent.p95, 1)),
            Row(label: "Clipto 数据目录大小", value: bytesGB(storage?.endBytes)),
            Row(label: "Clipto 数据目录运行期间增长", value: bytesGB(storage.flatMap { s in s.startBytes.map { s.endBytes - $0 } }))
        ]

        for nt in standardNodeTypes {
            result.append(Row(label: "\(nt) 倍速比", value: nodeSpeedup(nt)))
        }

        result.append(contentsOf: [
            Row(label: "运行开始时间", value: time(a?.sliceStartMs)),
            Row(label: "运行结束时间", value: time(a?.sliceEndMs)),
            Row(label: "备注", value: a == nil ? "" : remark)
        ])

        return result
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "Clipto离线分析晨报_20261026-2015" stem shared with the .md/.png exports.
    static func fileName(_ a: DAGSCAnalysisResponse) -> String {
        "\(MarkdownReportGenerator.fileStem(a)).csv"
    }
}
