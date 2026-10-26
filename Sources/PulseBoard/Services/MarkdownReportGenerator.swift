import Foundation

struct MarkdownReportOptions: Sendable {
    var reporter: String = ""
    var changeSummary: String = ""
    var notes: String = ""
    var topNodeLimit: Int = 10
    var topSlowAssetLimit: Int = 5
    var includeHardware: Bool = true
    var includeCMSProcesses: Bool = true
}

enum MarkdownReportGenerator {
    static func generate(
        analysis: DAGSCAnalysisResponse,
        options: MarkdownReportOptions = MarkdownReportOptions()
    ) -> String {
        var lines: [String] = []
        let env = analysis.environment
        let primaryScope = analysis.scopes.assetAnalysis
        let primaryScopeTitle = "媒体资产分析 (`clipto_asset_analysis`)"

        let reportDate: String = {
            if let d = analysis.selectedDay, !d.isEmpty { return d }
            if analysis.sliceStartMs > 0 { return DAGSCAnalyzer.formatDayLocal(analysis.sliceStartMs) }
            return String(analysis.analyzedAtText.prefix(10))
        }()

        lines.append("# Clipto 运行与性能开发日报（\(reportDate)）")
        lines.append("")
        lines.append("> - **统计范围**：\(escapeMD(analysis.sliceLabel))")
        lines.append("> - **时间窗口**：`\(analysis.sliceStartText)` → `\(analysis.sliceEndText)`")
        lines.append("> - **软件版本**：Clipto `\(analysis.appVersion)` ｜ 分析模板 `\(analysis.templateVersion.isEmpty ? "—" : analysis.templateVersion)`")
        lines.append("> - **测试机型**：`\(env.chipModel)` · `\(env.physicalMemoryText)` 统一内存 · \(env.logicalCores) 逻辑核 · `\(env.macOSVersion)`")
        if !options.reporter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("> - **测试记录人**：\(escapeMD(options.reporter.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        if !options.changeSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("> - **本轮版本/改动说明**：\(escapeMD(options.changeSummary.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        lines.append("> - **日报生成时间**：`\(analysis.analyzedAtText)`")
        lines.append("")

        // Section 1: Throughput & Speedup Summary
        lines.append("## 一、核心吞吐与处理倍速总览")
        lines.append("")
        lines.append("| 指标项 | 数值结果 | 口径与说明 |")
        lines.append("| :--- | :--- | :--- |")
        lines.append("| **处理媒体素材规模** | **\(analysis.assetsTotal) 个**（\(analysis.videoAssetsCount) 视频 + \(analysis.imageAssetsCount) 图片） | 数据源：`\(escapeMD((analysis.dagscDir as NSString).abbreviatingWithTildeInPath))` |")
        lines.append("| **基准素材总时长 / 总体积** | **\(fmtDurationHuman(analysis.totalMediaDurationMs))**（\(fmtSec(analysis.totalMediaDurationMs))） / **\(fmtBytes(Double(analysis.totalMediaSizeBytes)))** | 平均单视频时长：\(analysis.videoAssetsCount > 0 ? fmtDurationHuman(analysis.totalMediaDurationMs / Int64(analysis.videoAssetsCount)) : "—") |")
        lines.append("| **实际处理总耗时** | **\(fmtDurationHuman(primaryScope.wallClockMs))**（\(fmtSec(primaryScope.wallClockMs))） | \(primaryScopeTitle)\(primaryScope.batchCountInScope > 1 ? "（含 \(primaryScope.batchCountInScope) 个活跃批次累计，首尾总跨度 \(fmtDurationHuman(primaryScope.spanWallClockMs))）" : "") |")
        lines.append("| **整体实时处理倍速 (Speedup)** | **\(fmtSpeedup(primaryScope.wallSpeedup))** | 素材总时长 ÷ 实际处理耗时（数值越大越快；耗时比 RTF = `\(String(format: "%.4fx", primaryScope.wallRtf))`） |")
        lines.append("| **任务规模与成功率** | **\(primaryScope.succeededTasks) / \(primaryScope.totalTasks)** 成功（失败 **\(primaryScope.failedTasks)**） | 工作流总数：\(analysis.workflowsTotal) 个；平均并行加速比：**\(String(format: "%.2fx", primaryScope.concurrency))** |")
        lines.append("")

        // Section 2: Aligned Hardware & Process Watermarks
        if options.includeHardware {
            lines.append("## 二、运行期硬件与进程资源水位（PulseBoard 自动对齐）")
            lines.append("")
            if let hw = analysis.alignedHardware, hw.hasData {
                lines.append("已自动对齐分析活跃时段（共匹配 **\(hw.sampleCount)** 个系统采样点、**\(hw.cmsFrameCount)** 帧 CMS 采样，覆盖率 **\(String(format: "%.1f%%", hw.coveragePercent))**）：")
                lines.append("")
                lines.append("| 监控对象与指标 | 区间平均值 | P95 水位 | 采样峰值 | 补充信息 |")
                lines.append("| :--- | :---: | :---: | :---: | :--- |")
                lines.append("| **Clipto 进程组 CPU（单核=100%）** | \(fmtPct(hw.cliptoCPUPercent.avg)) | \(fmtPct(hw.cliptoCPUPercent.p95)) | **\(fmtPct(hw.cliptoCPUPercent.max))** | 多核累计口径；最多 \(hw.cliptoMaxProcesses) 个子进程 |")
                lines.append("| **Clipto 进程组物理内存** | \(fmtBytesOpt(hw.cliptoMemoryBytes.avg)) | \(fmtBytesOpt(hw.cliptoMemoryBytes.p95)) | **\(fmtBytesOpt(hw.cliptoMemoryBytes.max))** | 活跃采样帧：\(hw.cliptoActiveSamples) 点 |")
                lines.append("| **Clipto 进程组 GPU / 磁盘读写** | GPU \(fmtPct(hw.cliptoGPUPercent.avg)) | GPU \(fmtPct(hw.cliptoGPUPercent.p95)) | GPU **\(fmtPct(hw.cliptoGPUPercent.max))** | 读峰值 \(fmtRateOpt(hw.cliptoDiskReadBps.max)) / 写峰值 \(fmtRateOpt(hw.cliptoDiskWriteBps.max)) |")
                lines.append("| **CMS 进程组总 CPU（单核=100%）** | \(fmtPct1(hw.cmsTotalCPUPercent.avg)) | \(fmtPct1(hw.cmsTotalCPUPercent.p95)) | **\(fmtPct1(hw.cmsTotalCPUPercent.max))** | 匹配名称含 `cms` 的算法子进程合计 |")
                lines.append("| **CMS 进程组物理内存 (`phys_footprint`)** | \(fmtBytesOpt(hw.cmsTotalMemoryBytes.avg)) | \(fmtBytesOpt(hw.cmsTotalMemoryBytes.p95)) | **\(fmtBytesOpt(hw.cmsTotalMemoryBytes.max))** | 共识别 \(hw.cmsProcesses.count) 类 CMS 进程名 |")
                lines.append("| **整机 CPU / GPU / ANE 活跃度** | CPU \(fmtPct(hw.sysCPU.avg)) / GPU \(fmtPct(hw.sysGPU.avg)) / ANE \(fmtPct(hw.aneUsage.avg)) | CPU \(fmtPct(hw.sysCPU.p95)) | CPU **\(fmtPct(hw.sysCPU.max))** / GPU **\(fmtPct(hw.sysGPU.max))** / ANE **\(fmtPct(hw.aneUsage.max))** | 系统级硬件利用率 |")
                lines.append("| **整机内存与 Swap 占用** | 内存 \(fmtBytesOpt(hw.sysMemBytes.avg))（\(fmtPct(hw.sysMemPct.avg))） | \(fmtBytesOpt(hw.sysMemBytes.p95)) | **\(fmtBytesOpt(hw.sysMemBytes.max))**（\(fmtPct(hw.sysMemPct.max))） | Swap 峰值：**\(fmtBytesOpt(hw.swapUsedBytes.max))** |")
                let energyText = hw.estimatedEnergyWh.map { String(format: "区间累计耗电约 **%.2f Wh**", $0) } ?? "—"
                lines.append("| **整机功耗与分项功耗** | 整机 **\(fmtWatts(hw.sysPowerWatts.avg))**（CPU \(fmtWatts(hw.cpuPowerWatts.avg)) / GPU \(fmtWatts(hw.gpuPowerWatts.avg)) / ANE \(fmtWatts(hw.anePowerWatts.avg))） | 整机 \(fmtWatts(hw.sysPowerWatts.p95)) | 整机 **\(fmtWatts(hw.sysPowerWatts.max))** | \(energyText)；最高热状态：**\(thermalLabel(hw.worstThermalState))** |")
                if (hw.dramReadGBps.max ?? 0) > 0 || (hw.dramWriteGBps.max ?? 0) > 0 {
                    lines.append("| **DRAM 内存带宽 & 整机磁盘吞吐** | 读 \(fmtGBps(hw.dramReadGBps.avg)) / 写 \(fmtGBps(hw.dramWriteGBps.avg)) | 读 \(fmtGBps(hw.dramReadGBps.p95)) | 读 **\(fmtGBps(hw.dramReadGBps.max))** / 写 **\(fmtGBps(hw.dramWriteGBps.max))** | 磁盘读峰值 \(fmtRateOpt(hw.diskReadBps.max)) / 写峰值 \(fmtRateOpt(hw.diskWriteBps.max)) |")
                } else {
                    lines.append("| **整机磁盘读写吞吐** | 读 \(fmtRateOpt(hw.diskReadBps.avg)) / 写 \(fmtRateOpt(hw.diskWriteBps.avg)) | 读 \(fmtRateOpt(hw.diskReadBps.p95)) | 读 **\(fmtRateOpt(hw.diskReadBps.max))** / 写 **\(fmtRateOpt(hw.diskWriteBps.max))** | DRAM 带宽通道：当前机型未开放 |")
                }
                lines.append("")

                if options.includeCMSProcesses, !hw.cmsProcesses.isEmpty {
                    lines.append("### 2.1 CMS 子进程资源明细")
                    lines.append("")
                    lines.append("| CMS 进程名 | 实例数 | 平均 CPU | 峰值 CPU | 平均物理内存 | 峰值物理内存 |")
                    lines.append("| :--- | :---: | :---: | :---: | :---: | :---: |")
                    for proc in hw.cmsProcesses.prefix(12) {
                        lines.append("| `\(escapeMD(proc.name))` | \(proc.instanceCount) | \(fmtPct1(proc.avgCPUPercent)) | **\(fmtPct1(proc.maxCPUPercent))** | \(fmtBytesOpt(proc.avgMemoryBytes)) | **\(fmtBytesOpt(proc.maxMemoryBytes))** |")
                    }
                    lines.append("")
                }
            } else {
                lines.append("> 该历史分析区间内未查询到对应的 PulseBoard 本地硬件采样记录（可能是分析当时后台采集尚未开启，或早于历史保留期）。建议测试期间保持菜单栏 `CliptoPulse` 常驻运行。")
                lines.append("")
            }
        }

        // Section 3: Top Algorithm Node Bottlenecks
        if !primaryScope.byNodeType.isEmpty && options.topNodeLimit > 0 {
            let topNodes = Array(primaryScope.byNodeType.prefix(options.topNodeLimit))
            lines.append("## 三、算法服务耗时瓶颈排行（Top \(topNodes.count) `node_type`）")
            lines.append("")
            lines.append("| # | 算法服务 (`node_type`) | 执行器 | 任务数 (成/败) | 累计耗时 | 占总累计耗时 | 单服务实时倍速 | 平均耗时 | 最大耗时 | 泳道 Busy% |")
            lines.append("| :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")
            for (idx, row) in topNodes.enumerated() {
                lines.append("| \(idx + 1) | `\(escapeMD(row.nodeType))` | `\(escapeMD(row.executor))` | \(row.count) (\(row.succeeded)/\(row.failed)) | **\(fmtSec(row.sumMs))** | **\(String(format: "%.2f%%", row.pctCumulative))** | \(fmtSpeedup(row.speedup)) | \(fmtSecDouble(row.avgMs)) | \(fmtSec(row.maxMs)) | \(String(format: "%.1f%%", row.busyPct)) |")
            }
            lines.append("")
        }

        // Section 4: Slowest Long-Tail Assets
        if !analysis.byAsset.isEmpty && options.topSlowAssetLimit > 0 {
            let slowest = Array(
                analysis.byAsset
                    .sorted { $0.wallSpanMs > $1.wallSpanMs }
                    .prefix(options.topSlowAssetLimit)
            )
            lines.append("## 四、长尾慢素材排行（单资产耗时 Top \(slowest.count)）")
            lines.append("")
            lines.append("| 资产 ID | 素材文件名 | 素材时长 | 单资产处理耗时 | 单资产实时倍速 | 最耗时算法服务 |")
            lines.append("| :---: | :--- | :---: | :---: | :---: | :--- |")
            for a in slowest {
                let mediaStr = (a.assetType == "image" || a.mediaDurationMs == 0)
                    ? "图片 (0s)"
                    : "\(fmtDurationHuman(a.mediaDurationMs)) (\(fmtSec(a.mediaDurationMs)))"
                let speedStr = (a.assetType == "image" || a.mediaDurationMs == 0)
                    ? "—"
                    : fmtSpeedup(a.wallSpeedup)
                let topNodeStr = a.topNodeType.isEmpty ? "—" : "`\(escapeMD(a.topNodeType))` (\(fmtSec(a.topNodeMs)))"
                lines.append("| `#\(escapeMD(a.assetID))` | \(escapeMD(a.filename)) | \(mediaStr) | **\(fmtDurationHuman(a.wallSpanMs))** | **\(speedStr)** | \(topNodeStr) |")
            }
            lines.append("")
        }

        // Section 5: Diagnostics & Developer Notes
        lines.append("## 五、异常诊断与开发记录")
        lines.append("")
        if !analysis.failedTaskSamples.isEmpty {
            lines.append("### 5.1 失败/异常任务明细")
            lines.append("")
            lines.append("| 时间 | 资产 ID | 算法节点 | 状态 | 错误摘要 |")
            lines.append("| :--- | :---: | :--- | :---: | :--- |")
            for f in analysis.failedTaskSamples {
                lines.append("| `\(f.timestampText)` | `#\(escapeMD(f.assetID))` | `\(escapeMD(f.templateNodeID))` (`\(escapeMD(f.nodeType))`) | \(escapeMD(f.statusText)) | \(escapeMD(f.errorSummary.isEmpty ? "—" : f.errorSummary)) |")
            }
            lines.append("")
        } else {
            let thermalNote: String
            if let hw = analysis.alignedHardware, hw.hasData {
                thermalNote = "，运行期间最高热状态为「**\(thermalLabel(hw.worstThermalState))**」"
            } else {
                thermalNote = ""
            }
            lines.append("- **任务健康度**：本次统计区间内全部 **\(primaryScope.totalTasks)** 个任务均执行成功（**0 失败**）\(thermalNote)。")
            if let top1 = primaryScope.byNodeType.first {
                lines.append("- **首要耗时服务**：`\(top1.nodeType)` 占累计总耗时的 **\(String(format: "%.2f%%", top1.pctCumulative))**（累计 \(fmtDurationHuman(top1.sumMs))，泳道无空泡率 `\(String(format: "%.1f%%", top1.busyPct))`）。")
            }
        }

        let trimmedNotes = options.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            lines.append("")
            lines.append("### 开发备注与跟进事项")
            lines.append("")
            lines.append(trimmedNotes)
        } else {
            lines.append("- **开发记录备注**：（可在此补充今日优化改动、模型版本对比结论或待排查问题）")
        }
        lines.append("")

        return lines.joined(separator: "\n")
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

    private static func fmtSecDouble(_ ms: Double) -> String {
        String(format: "%.3f s", ms / 1_000.0)
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
