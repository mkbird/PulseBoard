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
    /// Fixed display order: Clipto app & helpers → scheduler & media tools → CMS workers (alphabetical).
    static let majorProcessOrder: [String] = [
        "Clipto",
        "Clipto Helper",
        "Clipto Helper (Renderer)",
        "Clipto Helper (GPU)",
        "dag-schedule-center",
        "cbs",
        "cbs-worker",
        "clipto_ffmpeg",
        "clipto_ffprobe",
        "cms_a10",
        "cms_bt11",
        "cms_l2",
        "cms_r5",
        "cms_vf12"
    ]

    static func generate(
        analysis: DAGSCAnalysisResponse,
        options: MarkdownReportOptions = MarkdownReportOptions()
    ) -> String {
        var lines: [String] = []
        let env = analysis.environment
        let capabilities = env.metricCapabilities
        let semantics = env.metricSemantics
        let primaryScope = analysis.scopes.assetAnalysis
        let hw = analysis.alignedHardware.flatMap { $0.hasData ? $0 : nil }

        // Title: product + platform + version.
        lines.append("# \(reportTitle(analysis))")
        lines.append("")
        lines.append("> - **运行时段**：\(titleRange(analysis))（\(escapeMD(sliceSummary(analysis)))）")
        lines.append("> - **测试平台**：Clipto **\(escapeMD(env.osName)) 版** · \(escapeMD(env.chipModel)) · \(env.physicalMemoryText) \(escapeMD(semantics.systemMemory)) · \(env.logicalCores) 核 · \(escapeMD(env.displayOSVersion))")
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
        let cliptoGPUAvailable = capabilities.processGPU && hasMetric(hw?.cliptoGPUPercent)
        let cliptoGPUCaption = !capabilities.processGPU
            ? "当前平台不提供进程 GPU 指标"
            : (cliptoGPUAvailable ? "Clipto 进程组合计（整颗 GPU = 100%）" : "本时段无进程 GPU 采样")
        lines.append("| 端到端分析速度 | 全 CMS 内存峰值 | Clipto 进程组内存峰值 | Clipto 进程组 CPU P95 | Clipto 进程组 GPU P95 | Clipto 数据目录 |")
        lines.append("| :---: | :---: | :---: | :---: | :---: | :---: |")
        lines.append("| **\(fmtSpeedup(primaryScope.wallSpeedup))** | **\(fmtBytesOpt(hw?.cmsTotalMemoryBytes.max))** | **\(fmtBytesOpt(hw?.cliptoMemoryBytes.max))** | **\(fmtPct1(hw?.cliptoCPUPercent.p95))** | **\(cliptoGPUAvailable ? fmtPct1(hw?.cliptoGPUPercent.p95) : "—")** | **\(fmtBytesOpt(storage?.endBytes))** |")
        lines.append("| 素材 \(fmtDurationShort(analysis.totalMediaDurationMs)) ÷ 端到端 \(fmtDurationShort(primaryScope.wallClockMs)) | 所有 cms 进程内存合计（\(escapeMD(semantics.processMemory))） | Clipto 进程组内存合计（\(escapeMD(semantics.processMemory))） | Clipto 进程组合计（\(escapeMD(semantics.processCPU))） | \(cliptoGPUCaption) | \(storageGrowth.map { "运行期间 \(fmtSignedBytes($0))" } ?? "Clipto 数据目录磁盘占用") |")
        lines.append("")

        // Section 1: Throughput overview
        let assetsSucceeded = analysis.byAsset.filter { $0.status == "succeeded" }.count
        let assetsFailed = analysis.byAsset.filter { $0.status == "failed" }.count
        let assetLight = assetsFailed > 0 ? "🔴" : "🟢"
        let nodeLight = primaryScope.failedTasks > 0 ? "🟡" : "🟢"
        let overallLight = assetsFailed > 0 ? "🔴" : (primaryScope.failedTasks > 0 ? "🟡" : "🟢")

        lines.append("## 一、吞吐概览")
        lines.append("")
        lines.append("| 指标项 | 数值结果 | 口径与说明 |")
        lines.append("| :--- | :--- | :--- |")
        lines.append("| **处理媒体素材** | **\(analysis.assetsTotal) 个**（\(analysis.videoAssetsCount) 视频 + \(analysis.imageAssetsCount) 图片） | 总时长 **\(fmtDurationHuman(analysis.totalMediaDurationMs))** · 总体积 **\(fmtBytes(Double(analysis.totalMediaSizeBytes)))** |")
        lines.append("| **端到端处理耗时** | **\(fmtDurationHuman(primaryScope.wallClockMs))** | 媒体资产分析 (`clipto_asset_analysis`)\(primaryScope.batchCountInScope > 1 ? "，含 \(primaryScope.batchCountInScope) 个活跃段（已剔除长空闲）" : "") |")
        lines.append("| **端到端分析速度** | **\(fmtSpeedup(primaryScope.wallSpeedup))** | 素材总时长 ÷ 端到端处理耗时（越大越快；RTF = `\(String(format: "%.4f", primaryScope.wallRtf))`） |")
        lines.append("| **素材分析成功率** | \(assetLight) **\(assetsSucceeded) / \(analysis.assetsTotal)**（素材分析失败 **\(assetsFailed)**） | 工作流 \(analysis.workflowsTotal) 个；平均并行度 **\(String(format: "%.2fx", primaryScope.concurrency))** |")
        lines.append("| **节点执行成功率** | \(nodeLight) **\(primaryScope.succeededTasks) / \(primaryScope.totalTasks)**（节点失败 **\(primaryScope.failedTasks)**） | 节点失败会被自动重试，可能对素材分析没有实际影响 |")
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
                lines.append("| **全 CMS 进程内存** | \(fmtBytesOpt(hw.cmsTotalMemoryBytes.avg)) | \(fmtBytesOpt(hw.cmsTotalMemoryBytes.p95)) | **\(fmtBytesOpt(hw.cmsTotalMemoryBytes.max))** | `\(escapeMD(semantics.processMemory))`，\(hw.cmsProcesses.count) 类 cms 进程 |")
                lines.append("| **全 CMS CPU（\(escapeMD(semantics.processCPU))）** | \(fmtPct1(hw.cmsTotalCPUPercent.avg)) | \(fmtPct1(hw.cmsTotalCPUPercent.p95)) | **\(fmtPct1(hw.cmsTotalCPUPercent.max))** | 名称含 `cms` 的进程合计 |")
                if capabilities.processGPU && hasMetric(hw.cmsTotalGPUPercent) {
                    lines.append("| **全 CMS GPU** | \(fmtPct1(hw.cmsTotalGPUPercent.avg)) | \(fmtPct1(hw.cmsTotalGPUPercent.p95)) | **\(fmtPct1(hw.cmsTotalGPUPercent.max))** | \(escapeMD(semantics.processGPU)) |")
                }
                lines.append("| **Clipto 进程组 CPU / 内存** | \(fmtPct(hw.cliptoCPUPercent.avg)) / \(fmtBytesOpt(hw.cliptoMemoryBytes.avg)) | \(fmtPct(hw.cliptoCPUPercent.p95)) / \(fmtBytesOpt(hw.cliptoMemoryBytes.p95)) | **\(fmtPct(hw.cliptoCPUPercent.max))** / **\(fmtBytesOpt(hw.cliptoMemoryBytes.max))** | 最多 \(hw.cliptoMaxProcesses) 个子进程 |")
                lines.append("| **Clipto 非 CMS 进程内存** | \(fmtBytesOpt(hw.cliptoNonCMSMemoryBytes.avg)) | \(fmtBytesOpt(hw.cliptoNonCMSMemoryBytes.p95)) | **\(fmtBytesOpt(hw.cliptoNonCMSMemoryBytes.max))** | 进程组中名称不含 cms 的进程合计（全进程明细见网页端） |")
                if capabilities.processGPU && hasMetric(hw.cliptoGPUPercent) {
                    lines.append("| **Clipto 进程组 GPU** | \(fmtPct(hw.cliptoGPUPercent.avg)) | \(fmtPct(hw.cliptoGPUPercent.p95)) | **\(fmtPct(hw.cliptoGPUPercent.max))** | \(escapeMD(semantics.processGPU))；读峰值 \(fmtRateOpt(hw.cliptoDiskReadBps.max)) / 写峰值 \(fmtRateOpt(hw.cliptoDiskWriteBps.max)) |")
                } else if capabilities.processIO && (hasMetric(hw.cliptoDiskReadBps) || hasMetric(hw.cliptoDiskWriteBps)) {
                    lines.append("| **Clipto 进程组 I/O** | 读 \(fmtRateOpt(hw.cliptoDiskReadBps.avg)) / 写 \(fmtRateOpt(hw.cliptoDiskWriteBps.avg)) | 读 \(fmtRateOpt(hw.cliptoDiskReadBps.p95)) / 写 \(fmtRateOpt(hw.cliptoDiskWriteBps.p95)) | **读 \(fmtRateOpt(hw.cliptoDiskReadBps.max)) / 写 \(fmtRateOpt(hw.cliptoDiskWriteBps.max))** | \(escapeMD(semantics.processIO)) |")
                }
                var computeMetrics: [(String, AlignedStatMetric)] = [("CPU", hw.sysCPU)]
                if capabilities.systemGPU && hasMetric(hw.sysGPU) { computeMetrics.append(("GPU", hw.sysGPU)) }
                if capabilities.ane && hasMetric(hw.aneUsage) { computeMetrics.append(("ANE", hw.aneUsage)) }
                let computeLabel = computeMetrics.map { $0.0 }.joined(separator: " / ")
                let computeAvg = computeMetrics.map { fmtPct($0.1.avg) }.joined(separator: " / ")
                let computeP95 = computeMetrics.map { fmtPct($0.1.p95) }.joined(separator: " / ")
                let computeMax = computeMetrics.map { fmtPct($0.1.max) }.joined(separator: " / ")
                lines.append("| **整机 \(computeLabel)** | \(computeAvg) | \(computeP95) | **\(computeMax)** | 系统级利用率 |")
                lines.append("| **整机内存 / Swap** | \(fmtBytesOpt(hw.sysMemBytes.avg)) | \(fmtBytesOpt(hw.sysMemBytes.p95)) | **\(fmtBytesOpt(hw.sysMemBytes.max))** | Swap 峰值 **\(fmtBytesOpt(hw.swapUsedBytes.max))** |")
                if capabilities.power && hasMetric(hw.sysPowerWatts) {
                    let energyText = hw.estimatedEnergyWh.map { String(format: "累计耗电约 **%.2f Wh**", $0) } ?? "—"
                    lines.append("| **整机功耗** | \(fmtWatts(hw.sysPowerWatts.avg)) | \(fmtWatts(hw.sysPowerWatts.p95)) | **\(fmtWatts(hw.sysPowerWatts.max))** | \(energyText)；\(escapeMD(semantics.power))；最高热状态 **\(thermalLabel(hw.worstThermalState))** |")
                }
                lines.append("")

                if options.includeCMSProcesses {
                    let membersByName = Dictionary(hw.cliptoMembers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                    let major = majorProcessOrder.compactMap { membersByName[$0] }
                    if !major.isEmpty {
                        lines.append("### 2.2 主要进程明细")
                        lines.append("")
                        lines.append("| 进程名 | 累计使用PID数 | 平均内存 | 峰值内存 | 平均 CPU | 峰值 CPU |")
                        lines.append("| :--- | :---: | :---: | :---: | :---: | :---: |")
                        for m in major {
                            lines.append("| `\(escapeMD(m.name))` | \(m.maxInstances) | \(fmtBytesOpt(m.avgMemoryBytes)) | **\(fmtBytesOpt(m.maxMemoryBytes))** | \(fmtPct1(m.avgCPUPercent)) | **\(fmtPct1(m.maxCPUPercent))** |")
                        }
                        lines.append("")
                    } else {
                        let cmsByName = Dictionary(hw.cmsProcesses.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                        let fallbackCMS = majorProcessOrder.compactMap { cmsByName[$0] }
                        if !fallbackCMS.isEmpty {
                            // History recorded before 2.1 only has the CMS subset.
                            lines.append("### 2.2 主要进程明细")
                            lines.append("")
                            lines.append("| 进程名 | 累计使用PID数 | 平均 CPU | 峰值 CPU | 平均物理内存 | 峰值物理内存 |")
                            lines.append("| :--- | :---: | :---: | :---: | :---: | :---: |")
                            for proc in fallbackCMS {
                                lines.append("| `\(escapeMD(proc.name))` | \(proc.instanceCount) | \(fmtPct1(proc.avgCPUPercent)) | **\(fmtPct1(proc.maxCPUPercent))** | \(fmtBytesOpt(proc.avgMemoryBytes)) | **\(fmtBytesOpt(proc.maxMemoryBytes))** |")
                            }
                            lines.append("")
                        }
                    }
                }
            } else {
                lines.append("> 该分析区间内没有 CliptoPulse 硬件采样记录（采集未开启或早于历史保留期）。测试期间请保持 CliptoPulse 常驻运行。")
                lines.append("")
            }
        }

        // Section 3: User storage occupied by Clipto
        lines.append(env.platform == "windows" ? "## 三、Clipto 数据目录大小" : "## 三、com.clipto.mac大小")
        lines.append("")
        if let st = hw?.storage ?? analysis.alignedHardware?.storage {
            let growth = st.startBytes.map { st.endBytes - $0 }
            let startStr = st.startBytes.map { "**\(fmtBytes($0))**" } ?? "—"
            let endStr = "**\(fmtBytes(st.endBytes))**"
            let growthStr = growth.map { "**\(fmtSignedBytes($0))**" } ?? "—"
            let peakStr = "**\(fmtBytes(st.peakBytes))**"
            lines.append("| 指标项 | 数值结果 | 指标项 | 数值结果 |")
            lines.append("| :--- | :--- | :--- | :--- |")
            lines.append("| **任务开始前大小** | \(startStr) | **任务结束后大小** | \(endStr) |")
            lines.append("| **变化量** | \(growthStr) | **峰值** | \(peakStr) |")
            lines.append("")
        } else {
            lines.append("> 暂无数据目录测量记录。")
            lines.append("")
        }

        // Section 4: Diagnostics & notes
        lines.append("## 四、异常诊断与开发记录")
        lines.append("")
        let thermalNote = hw.map { "，运行期间最高热状态「**\(thermalLabel($0.worstThermalState))**」" } ?? ""
        if assetsFailed > 0 {
            lines.append("- \(overallLight) **运行健康度（红灯）**：素材分析成功 **\(assetsSucceeded) / \(analysis.assetsTotal)**（**素材分析失败 \(assetsFailed)**）；节点执行成功 **\(primaryScope.succeededTasks) / \(primaryScope.totalTasks)**（**节点失败 \(primaryScope.failedTasks)**，节点失败会被自动重试，可能对素材分析没有实际影响）\(thermalNote)。")
        } else if primaryScope.failedTasks > 0 {
            lines.append("- \(overallLight) **运行健康度（黄灯）**：全部 **\(analysis.assetsTotal)** 个素材分析成功（**素材分析 0 失败**）；期间发生 **\(primaryScope.failedTasks)** 次节点执行失败（节点失败会被自动重试，可能对素材分析没有实际影响）\(thermalNote)。")
        } else {
            lines.append("- \(overallLight) **运行健康度（绿灯）**：全部 **\(analysis.assetsTotal)** 个素材分析成功（**0 失败**），全部 **\(primaryScope.totalTasks)** 个节点执行成功（**0 失败**）\(thermalNote)。")
        }
        if !analysis.failedTaskSamples.isEmpty {
            lines.append("")
            lines.append("| 时间 | 资产 ID | 算法节点 | 状态 | 错误摘要 |")
            lines.append("| :--- | :---: | :--- | :---: | :--- |")
            for f in analysis.failedTaskSamples {
                lines.append("| `\(f.timestampText)` | `#\(escapeMD(f.assetID))` | `\(escapeMD(f.templateNodeID))` (`\(escapeMD(f.nodeType))`) | \(escapeMD(f.statusText)) | \(escapeMD(f.errorSummary.isEmpty ? "—" : f.errorSummary)) |")
            }
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

    /// Product + current OS + optional app version.
    static func reportTitle(_ a: DAGSCAnalysisResponse) -> String {
        let version = a.appVersion == "未知版本" ? "" : " \(a.appVersion)"
        return "Clipto \(a.environment.osName)\(version) 离线分析性能晨报"
    }

    private static func hasMetric(_ metric: AlignedStatMetric?) -> Bool {
        guard let metric else { return false }
        return metric.count > 0 || metric.avg != nil || metric.p95 != nil || metric.max != nil
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
