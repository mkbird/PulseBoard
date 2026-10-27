import Foundation

/// Single-column CSV for pasting into a version-tracking spreadsheet: row 1 is the Clipto version,
/// every following row is one metric. Values are plain numbers (units live in `rowLabels`), and
/// missing values are empty cells so spreadsheet charts/formulas keep working.
///
/// The row order is a contract with the user's tracking sheet — append new rows at the end only.
enum ReportCSVGenerator {
    private struct Row {
        let label: String
        let value: String
    }

    /// Row names in output order (row 1 = version). Shown in the web console so the sheet can be set up once.
    static var rowLabels: [String] {
        rows(for: nil).map(\.label)
    }

    /// One column, many rows (UTF-8 with BOM so Excel/Numbers detect Chinese correctly).
    static func generate(analysis: DAGSCAnalysisResponse, includeLabels: Bool = false) -> String {
        let body = rows(for: analysis).map { row in
            includeLabels ? "\(escape(row.label)),\(escape(row.value))" : escape(row.value)
        }
        return "\u{FEFF}" + body.joined(separator: "\r\n") + "\r\n"
    }

    /// Just the values joined by newlines — pastes straight into one spreadsheet column.
    static func columnText(analysis: DAGSCAnalysisResponse) -> String {
        rows(for: analysis).map(\.value).joined(separator: "\n")
    }

    private static func rows(for a: DAGSCAnalysisResponse?) -> [Row] {
        let scope = a?.scopes.assetAnalysis
        let hw = a?.alignedHardware.flatMap { $0.hasData ? $0 : nil }
        let storage = a?.alignedHardware?.storage
        let gb = 1_024.0 * 1_024.0 * 1_024.0

        func num(_ v: Double?, _ digits: Int) -> String {
            guard let v, v.isFinite else { return "" }
            return String(format: "%.\(digits)f", v)
        }
        func bytesGB(_ v: Double?) -> String { num(v.map { $0 / gb }, 2) }
        func minutes(_ ms: Int64?) -> String { num(ms.map { Double($0) / 60_000.0 }, 1) }
        func int(_ v: Int?) -> String { v.map(String.init) ?? "" }
        func time(_ ms: Int64?) -> String {
            guard let ms, ms > 0 else { return "" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
        }
        let speedup = scope.flatMap { $0.wallSpeedup > 0 ? $0.wallSpeedup : nil }
        let machine = a.map { "\($0.environment.chipModel) / \($0.environment.physicalMemoryText) / \($0.environment.macOSVersion)" } ?? ""

        return [
            Row(label: "Clipto Mac 版本号", value: a?.appVersion ?? ""),
            // Headline KPIs
            Row(label: "端到端分析速度 (x)", value: num(speedup, 2)),
            Row(label: "全 CMS 内存峰值 (GB)", value: bytesGB(hw?.cmsTotalMemoryBytes.max)),
            Row(label: "全 CMS CPU P95 (%，单核=100)", value: num(hw?.cmsTotalCPUPercent.p95, 1)),
            Row(label: "全 CMS GPU P95 (%)", value: num(hw?.cmsTotalGPUPercent.p95, 1)),
            // Throughput
            Row(label: "处理素材数", value: int(a?.assetsTotal)),
            Row(label: "素材总时长 (分钟)", value: minutes(a?.totalMediaDurationMs)),
            Row(label: "端到端处理耗时 (分钟)", value: minutes(scope?.wallClockMs)),
            Row(label: "任务总数", value: int(scope?.totalTasks)),
            Row(label: "失败任务数", value: int(scope?.failedTasks)),
            // CMS averages
            Row(label: "全 CMS 内存平均 (GB)", value: bytesGB(hw?.cmsTotalMemoryBytes.avg)),
            Row(label: "全 CMS CPU 平均 (%)", value: num(hw?.cmsTotalCPUPercent.avg, 1)),
            Row(label: "全 CMS GPU 平均 (%)", value: num(hw?.cmsTotalGPUPercent.avg, 1)),
            // Clipto / system
            Row(label: "Clipto 进程组内存峰值 (GB)", value: bytesGB(hw?.cliptoMemoryBytes.max)),
            Row(label: "整机内存峰值 (GB)", value: bytesGB(hw?.sysMemBytes.max)),
            Row(label: "Swap 峰值 (GB)", value: bytesGB(hw?.swapUsedBytes.max)),
            Row(label: "整机平均功耗 (W)", value: num(hw?.sysPowerWatts.avg, 2)),
            Row(label: "累计耗电 (Wh)", value: num(hw?.estimatedEnergyWh, 2)),
            Row(label: "硬件采样覆盖率 (%)", value: num(hw?.coveragePercent, 1)),
            // Context
            Row(label: "运行开始时间", value: time(a?.sliceStartMs)),
            Row(label: "运行结束时间", value: time(a?.sliceEndMs)),
            Row(label: "分析模板版本", value: a?.templateVersion ?? ""),
            Row(label: "测试机型", value: machine),
            // Appended later — keep new rows at the end so existing tracking sheets stay aligned.
            Row(label: "评测人", value: a == nil ? "" : ReportProfile.reporter),
            Row(label: "Clipto 非 CMS 进程内存峰值 (GB)", value: bytesGB(hw?.cliptoNonCMSMemoryBytes.max)),
            Row(label: "Clipto 数据目录大小 (GB)", value: bytesGB(storage?.endBytes)),
            Row(label: "Clipto 数据目录运行期间增长 (GB)", value: bytesGB(storage.flatMap { s in s.startBytes.map { s.endBytes - $0 } }))
        ]
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
