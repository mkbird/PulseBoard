import Foundation

struct MarkdownReportOptions: Sendable {
    /// 评测人 (manually entered; defaults to the saved profile)
    var reporter: String = ReportProfile.reporter
    /// 局域网 IP for the "查看详情" link (manual value, else first 192.168.* address; empty = no link line)
    var lanHost: String = ReportProfile.effectiveLANHost
    var changeSummary: String = ""
    var notes: String = ""
    var includeHardware: Bool = true
    var includeCMSProcesses: Bool = true
}

/// Morning-report generator. Layout contract shared with `ReportImageRenderer` and the web console:
/// `# title` → `>` meta lines → `## 🎯 头条指标` (one 3-row table: labels / values / captions) → numbered sections.
enum MarkdownReportGenerator {
    static func generate(
        analysis: DAGSCAnalysisResponse,
        options: MarkdownReportOptions = MarkdownReportOptions()
    ) -> String {
        var lines: [String] = []
        let env = analysis.environment
        let primaryScope = analysis.scopes.assetAnalysis
        let hw = analysis.alignedHardware.flatMap { $0.hasData ? $0 : nil }

        // Title: product + platform + version (we currently ship the Mac build)
        lines.append("# \(reportTitle(analysis))")
        lines.append("")
        lines.append("> - **运行时段**：\(titleRange(analysis))（\(escapeMD(sliceSummary(analysis)))）")
        lines.append("> - **测试平台**：Clipto **macOS 版** · \(env.chipModel) · \(env.physicalMemoryText) 统一内存 · \(env.logicalCores) 核 · \(env.macOSVersion)")
        lines.append("> - **分析模板**：\(analysis.templateVersion.isEmpty ? "—" : analysis.templateVersion) ｜ 生成于 \(analysis.analyzedAtText)")
        let reporter = options.reporter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reporter.isEmpty {
            lines.append("> - **评测人**：\(escapeMD(reporter))")
        }
        let change = options.changeSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !change.isEmpty {
            lines.append("> - **本轮改动**：\(escapeMD(change))")
        }
        let host = ReportProfile.normalizeHost(options.lanHost)
        if !host.isEmpty {
            lines.append("> - **查看详情**：同一局域网内用浏览器打开 http://\(host):\(env.webPort)（DAGSC 泳道、硬件曲线与历史监控）")
        }
        lines.append("")

        // Headline KPIs
        lines.append("## 🎯 头条指标")
        lines.append("")
        let storage = analysis.alignedHardware?.storage
        let storageGrowth = storage.flatMap { s in s.startBytes.map { s.endBytes - $0 } }
        lines.append("| 端到端分析速度 | 全 CMS 内存峰值 | 全 CMS CPU P95 | 全 CMS GPU P95 | Clipto 进程组内存峰值 | Clipto 数据目录 |")
        lines.append("| :---: | :---: | :---: | :---: | :---: | :---: |")
        lines.append("| **\(fmtSpeedup(primaryScope.wallSpeedup))** | **\(fmtBytesOpt(hw?.cmsTotalMemoryBytes.max))** | **\(fmtPct1(hw?.cmsTotalCPUPercent.p95))** | **\(fmtPct1(hw?.cmsTotalGPUPercent.p95))** | **\(fmtBytesOpt(hw?.cliptoMemoryBytes.max))** | **\(fmtBytesOpt(storage?.endBytes))** |")
        lines.append("| 素材 \(fmtDurationShort(analysis.totalMediaDurationMs)) ÷ 端到端 \(fmtDurationShort(primaryScope.wallClockMs)) | 所有 cms 进程物理内存合计 | 所有 cms 进程合计（单核 = 100%） | 所有 cms 进程合计（整颗 GPU = 100%） | Clipto.app 全部进程物理内存合计 | \(storageGrowth.map { "运行期间 \(fmtSignedBytes($0))" } ?? "com.clipto.mac 磁盘占用") |")
        lines.append("")

        // Section 1: Throughput overview
        lines.append("## 一、吞吐概览")
        lines.append("")
        lines.append("| 指标项 | 数值结果 | 口径与说明 |")
        lines.append("| :--- | :--- | :--- |")
        lines.append("| **处理媒体素材** | **\(analysis.assetsTotal) 个**（\(analysis.videoAssetsCount) 视频 + \(analysis.imageAssetsCount) 图片） | 总时长 **\(fmtDurationHuman(analysis.totalMediaDurationMs))** · 总体积 **\(fmtBytes(Double(analysis.totalMediaSizeBytes)))** |")
        lines.append("| **端到端处理耗时** | **\(fmtDurationHuman(primaryScope.wallClockMs))** | 媒体资产分析 (`clipto_asset_analysis`)\(primaryScope.batchCountInScope > 1 ? "，含 \(primaryScope.batchCountInScope) 个活跃段（已剔除长空闲）" : "") |")
        lines.append("| **端到端分析速度** | **\(fmtSpeedup(primaryScope.wallSpeedup))** | 素材总时长 ÷ 端到端处理耗时（越大越快；RTF = `\(String(format: "%.4f", primaryScope.wallRtf))`） |")
        lines.append("| **任务成功率** | **\(primaryScope.succeededTasks) / \(primaryScope.totalTasks)**（失败 **\(primaryScope.failedTasks)**） | 工作流 \(analysis.workflowsTotal) 个；平均并行度 **\(String(format: "%.2fx", primaryScope.concurrency))** |")
        lines.append("")

        // Section 2: Aligned hardware & process watermarks
        if options.includeHardware {
            lines.append("## 二、运行期硬件与进程资源水位")
            lines.append("")
            if let hw {
                lines.append("自动对齐分析活跃时段（\(hw.sampleCount) 个系统采样点 · \(hw.cmsFrameCount) 帧 CMS 采样 · 覆盖率 **\(String(format: "%.1f%%", hw.coveragePercent))**）")
                lines.append("")
                if hw.coveragePercent < lowCoverageThreshold {
                    lines.append("> ⚠️ 硬件采样覆盖率仅 \(String(format: "%.1f%%", hw.coveragePercent))（运行期间 CliptoPulse 未全程采集），以下硬件数据只代表部分时段。")
                    lines.append("")
                }
                lines.append("### 2.1 资源水位汇总")
                lines.append("")
                lines.append("| 监控对象与指标 | 平均值 | P95 | 峰值 | 补充信息 |")
                lines.append("| :--- | :---: | :---: | :---: | :--- |")
                lines.append("| **全 CMS 物理内存** | \(fmtBytesOpt(hw.cmsTotalMemoryBytes.avg)) | \(fmtBytesOpt(hw.cmsTotalMemoryBytes.p95)) | **\(fmtBytesOpt(hw.cmsTotalMemoryBytes.max))** | `phys_footprint`，\(hw.cmsProcesses.count) 类 cms 进程 |")
                lines.append("| **全 CMS CPU（单核=100%）** | \(fmtPct1(hw.cmsTotalCPUPercent.avg)) | \(fmtPct1(hw.cmsTotalCPUPercent.p95)) | **\(fmtPct1(hw.cmsTotalCPUPercent.max))** | 名称含 `cms` 的进程合计 |")
                lines.append("| **全 CMS GPU** | \(fmtPct1(hw.cmsTotalGPUPercent.avg)) | \(fmtPct1(hw.cmsTotalGPUPercent.p95)) | **\(fmtPct1(hw.cmsTotalGPUPercent.max))** | 按进程 GPU 时间统计（不含 ANE） |")
                lines.append("| **Clipto 进程组 CPU / 内存** | \(fmtPct(hw.cliptoCPUPercent.avg)) / \(fmtBytesOpt(hw.cliptoMemoryBytes.avg)) | \(fmtPct(hw.cliptoCPUPercent.p95)) / \(fmtBytesOpt(hw.cliptoMemoryBytes.p95)) | **\(fmtPct(hw.cliptoCPUPercent.max))** / **\(fmtBytesOpt(hw.cliptoMemoryBytes.max))** | 最多 \(hw.cliptoMaxProcesses) 个子进程 |")
                lines.append("| **Clipto 非 CMS 进程内存** | \(fmtBytesOpt(hw.cliptoNonCMSMemoryBytes.avg)) | \(fmtBytesOpt(hw.cliptoNonCMSMemoryBytes.p95)) | **\(fmtBytesOpt(hw.cliptoNonCMSMemoryBytes.max))** | 进程组中名称不含 cms 的进程合计（明细见下表） |")
                lines.append("| **Clipto 进程组 GPU** | \(fmtPct(hw.cliptoGPUPercent.avg)) | \(fmtPct(hw.cliptoGPUPercent.p95)) | **\(fmtPct(hw.cliptoGPUPercent.max))** | 磁盘读峰值 \(fmtRateOpt(hw.cliptoDiskReadBps.max)) / 写峰值 \(fmtRateOpt(hw.cliptoDiskWriteBps.max)) |")
                lines.append("| **整机 CPU / GPU / ANE** | \(fmtPct(hw.sysCPU.avg)) / \(fmtPct(hw.sysGPU.avg)) / \(fmtPct(hw.aneUsage.avg)) | \(fmtPct(hw.sysCPU.p95)) / \(fmtPct(hw.sysGPU.p95)) / \(fmtPct(hw.aneUsage.p95)) | **\(fmtPct(hw.sysCPU.max))** / **\(fmtPct(hw.sysGPU.max))** / **\(fmtPct(hw.aneUsage.max))** | 系统级利用率 |")
                lines.append("| **整机内存 / Swap** | \(fmtBytesOpt(hw.sysMemBytes.avg)) | \(fmtBytesOpt(hw.sysMemBytes.p95)) | **\(fmtBytesOpt(hw.sysMemBytes.max))** | Swap 峰值 **\(fmtBytesOpt(hw.swapUsedBytes.max))** |")
                let energyText = hw.estimatedEnergyWh.map { String(format: "累计耗电约 **%.2f Wh**", $0) } ?? "—"
                lines.append("| **整机功耗** | \(fmtWatts(hw.sysPowerWatts.avg)) | \(fmtWatts(hw.sysPowerWatts.p95)) | **\(fmtWatts(hw.sysPowerWatts.max))** | \(energyText)；最高热状态 **\(thermalLabel(hw.worstThermalState))** |")
                lines.append("")

                if options.includeCMSProcesses {
                    if !hw.cliptoMembers.isEmpty {
                        // Every process name in the Clipto group: CMS first, then the rest, each by avg memory.
                        let cms = hw.cliptoMembers.filter(\.isCMS)
                        let others = hw.cliptoMembers.filter { !$0.isCMS }
                        lines.append("### 2.2 Clipto 进程组全进程明细（\(hw.cliptoMembers.count) 个进程名：CMS \(cms.count) · 其他 \(others.count)）")
                        lines.append("")
                        lines.append("| 进程名 | 类型 | 最多实例 | 平均内存 | 峰值内存 | 平均 CPU | 峰值 CPU |")
                        lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: |")
                        for m in cms + others {
                            lines.append("| `\(escapeMD(m.name))` | \(m.isCMS ? "CMS" : "其他") | \(m.maxInstances) | \(fmtBytesOpt(m.avgMemoryBytes)) | **\(fmtBytesOpt(m.maxMemoryBytes))** | \(fmtPct1(m.avgCPUPercent)) | \(fmtPct1(m.maxCPUPercent)) |")
                        }
                        lines.append("")
                    } else if !hw.cmsProcesses.isEmpty {
                        // History recorded before 2.1 only has the CMS subset.
                        lines.append("### 2.2 CMS 进程明细（本时段无全进程组记录）")
                        lines.append("")
                        lines.append("| CMS 进程名 | 实例数 | 平均 CPU | 峰值 CPU | 平均物理内存 | 峰值物理内存 |")
                        lines.append("| :--- | :---: | :---: | :---: | :---: | :---: |")
                        for proc in hw.cmsProcesses {
                            lines.append("| `\(escapeMD(proc.name))` | \(proc.instanceCount) | \(fmtPct1(proc.avgCPUPercent)) | **\(fmtPct1(proc.maxCPUPercent))** | \(fmtBytesOpt(proc.avgMemoryBytes)) | **\(fmtBytesOpt(proc.maxMemoryBytes))** |")
                        }
                        lines.append("")
                    }
                }
            } else {
                lines.append("> 该分析区间内没有 CliptoPulse 硬件采样记录（采集未开启或早于历史保留期）。测试期间请保持菜单栏 CliptoPulse 常驻运行。")
                lines.append("")
            }
        }

        // Section 3: User storage occupied by Clipto
        lines.append("## 三、用户存储占用")
        lines.append("")
        if let st = hw?.storage ?? analysis.alignedHardware?.storage {
            let growth = st.startBytes.map { st.endBytes - $0 }
            lines.append("| 指标项 | 数值结果 | 说明 |")
            lines.append("| :--- | :--- | :--- |")
            lines.append("| **Clipto 数据目录\(st.isCurrentFallback ? "（当前）" : "（运行结束）")** | **\(fmtBytes(st.endBytes))** | `\(escapeMD((st.path as NSString).abbreviatingWithTildeInPath))` · \(st.fileCount) 个文件 · 测于 \(st.endText) |")
            lines.append("| **运行开始前** | \(st.startBytes.map(fmtBytes) ?? "—") | 每 5 分钟测量一次磁盘实际占用 |")
            lines.append("| **运行期间增长** | **\(growth.map(fmtSignedBytes) ?? "—")** | 峰值 \(fmtBytes(st.peakBytes)) |")
            lines.append("")
            if !st.breakdown.isEmpty {
                lines.append("| 子目录 / 文件 | 占用 |")
                lines.append("| :--- | :---: |")
                // Items ≥ 1 MB listed individually; smaller ones merged so the total stays exact.
                let big = st.breakdown.filter { $0.bytes >= 1_048_576 }
                let small = st.breakdown.filter { $0.bytes > 0 && $0.bytes < 1_048_576 }
                for item in big {
                    lines.append("| `\(escapeMD(item.name))` | \(fmtBytes(item.bytes)) |")
                }
                if !small.isEmpty {
                    lines.append("| 其余 \(small.count) 项（均小于 1 MB） | \(fmtBytes(small.reduce(0) { $0 + $1.bytes })) |")
                }
                lines.append("")
            }
        } else {
            lines.append("> 暂无数据目录测量记录（CliptoPulse 启动后每 5 分钟测量一次）。")
            lines.append("")
        }

        // Section 4: Diagnostics & notes
        lines.append("## 四、异常诊断与开发记录")
        lines.append("")
        if !analysis.failedTaskSamples.isEmpty {
            lines.append("| 时间 | 资产 ID | 算法节点 | 状态 | 错误摘要 |")
            lines.append("| :--- | :---: | :--- | :---: | :--- |")
            for f in analysis.failedTaskSamples {
                lines.append("| `\(f.timestampText)` | `#\(escapeMD(f.assetID))` | `\(escapeMD(f.templateNodeID))` (`\(escapeMD(f.nodeType))`) | \(escapeMD(f.statusText)) | \(escapeMD(f.errorSummary.isEmpty ? "—" : f.errorSummary)) |")
            }
            lines.append("")
        } else {
            let thermalNote = hw.map { "，运行期间最高热状态「**\(thermalLabel($0.worstThermalState))**」" } ?? ""
            lines.append("- **任务健康度**：全部 **\(primaryScope.totalTasks)** 个任务执行成功（**0 失败**）\(thermalNote)。")
        }

        let trimmedNotes = options.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            lines.append("")
            lines.append("### 开发备注与跟进事项")
            lines.append("")
            lines.append(trimmedNotes)
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// "批次 #3 · 47 素材 · 3371 任务" for batch slices, otherwise the slice label.
    static func sliceSummary(_ a: DAGSCAnalysisResponse) -> String {
        if a.sliceMode == "batch", let bid = a.selectedBatchID,
           let b = a.availableBatches.first(where: { $0.batchID == bid }) {
            return "批次 #\(b.index) · \(b.assetCount) 素材 · \(b.taskCount) 任务"
        }
        return a.sliceLabel
    }

    /// "Clipto Mac v0.9.288 (0.9-beta) 离线分析性能晨报"
    static func reportTitle(_ a: DAGSCAnalysisResponse) -> String {
        let version = a.appVersion == "未知版本" ? "" : " \(a.appVersion)"
        return "Clipto Mac\(version) 离线分析性能晨报"
    }

    /// "7h29m" / "15.4s" — compact duration for KPI captions.
    static func fmtDurationShort(_ ms: Int64) -> String {
        let totalSec = Double(max(0, ms)) / 1_000.0
        let h = Int(totalSec / 3_600)
        let m = Int(totalSec.truncatingRemainder(dividingBy: 3_600) / 60)
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m\(String(format: "%02d", Int(totalSec.truncatingRemainder(dividingBy: 60))))s" }
        return String(format: "%.1fs", totalSec)
    }

    // MARK: - Title & File Naming

    /// Hardware coverage below this percentage gets an explicit warning in the report.
    static let lowCoverageThreshold: Double = 90

    /// "10-26 20:15 → 10-27 03:40" (or "2026-10-26 20:15 → 23:40" for same-day runs).
    static func titleRange(_ a: DAGSCAnalysisResponse) -> String {
        guard a.sliceStartMs > 0 else { return String(a.analyzedAtText.prefix(16)) }
        let start = Date(timeIntervalSince1970: Double(a.sliceStartMs) / 1_000)
        let end = Date(timeIntervalSince1970: Double(max(a.sliceEndMs, a.sliceStartMs)) / 1_000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let sameDay = f.string(from: start) == f.string(from: end)
        f.dateFormat = sameDay ? "yyyy-MM-dd HH:mm" : "MM-dd HH:mm"
        let s = f.string(from: start)
        f.dateFormat = sameDay ? "HH:mm" : "MM-dd HH:mm"
        return "\(s) → \(f.string(from: end))"
    }

    /// "Clipto离线分析晨报_20261026-2015" — used for .md / .png downloads.
    static func fileStem(_ a: DAGSCAnalysisResponse) -> String {
        let ms = a.sliceStartMs > 0 ? a.sliceStartMs : Int64(Date().timeIntervalSince1970 * 1_000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "Clipto离线分析晨报_\(f.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000)))"
    }

    // MARK: - Formatting Helpers

    private static func escapeMD(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func fmtDurationHuman(_ ms: Int64) -> String {
        let totalSec = Double(max(0, ms)) / 1_000.0
        let h = Int(totalSec / 3_600)
        let m = Int(totalSec.truncatingRemainder(dividingBy: 3_600) / 60)
        let s = totalSec.truncatingRemainder(dividingBy: 60)
        if h > 0 { return String(format: "%dh %dm %.3fs", h, m, s) }
        if m > 0 { return String(format: "%dm %.3fs", m, s) }
        return String(format: "%.3fs", s)
    }

    private static func fmtSec(_ ms: Int64) -> String {
        String(format: "%.3f s", Double(ms) / 1_000.0)
    }

    private static func fmtSpeedup(_ v: Double) -> String {
        guard v > 0, v.isFinite else { return "—" }
        return String(format: "%.2fx", v)
    }

    private static func fmtPct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.1f%%", v)
    }

    private static func fmtPct1(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.1f%%", v)
    }

    private static func fmtWatts(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        if v < 1 { return String(format: "%.0f mW", v * 1_000) }
        return String(format: "%.2f W", v)
    }

    private static func fmtGBps(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.2f GB/s", v)
    }

    private static func fmtBytes(_ bytes: Double) -> String {
        guard bytes > 0, bytes.isFinite else { return "0 MB" }
        let gb = bytes / (1_024 * 1_024 * 1_024)
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = bytes / (1_024 * 1_024)
        return String(format: "%.1f MB", mb)
    }

    private static func fmtSignedBytes(_ bytes: Double) -> String {
        bytes < 0 ? "−\(fmtBytes(-bytes))" : "+\(fmtBytes(bytes))"
    }

    private static func fmtBytesOpt(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite else { return "—" }
        return fmtBytes(bytes)
    }

    private static func fmtRateOpt(_ bps: Double?) -> String {
        guard let bps, bps.isFinite else { return "—" }
        return "\(fmtBytes(bps))/s"
    }

    private static func thermalLabel(_ state: String) -> String {
        switch state {
        case "nominal", "正常", "Normal": "正常"
        case "fair", "温热", "Warm": "温热"
        case "serious", "较高", "High": "较高"
        case "critical", "严重", "Critical": "严重"
        default: "未知"
        }
    }
}
