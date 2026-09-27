import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: MonitorStore

    private let grid = [GridItem(.adaptive(minimum: 245), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                if store.selectedRange == .custom {
                    customRangePanel
                }
                LazyVGrid(columns: grid, spacing: 16) {
                    MetricCard(title: "CPU", icon: "cpu", value: MetricFormat.percent(store.latest?.cpuUsage), subtitle: cpuSubtitle, tint: .cyan, samples: store.samples, timeDomain: store.chartWindow, comparison: cliptoCPUComparison, barMaximum: 100) { $0.cpuUsage }
                    MetricCard(title: "GPU", icon: "rectangle.3.group", value: MetricFormat.percent(store.latest?.gpuUsage), subtitle: gpuSubtitle, tint: .purple, samples: store.samples, timeDomain: store.chartWindow, comparison: cliptoGPUComparison, barMaximum: 100) { $0.gpuUsage }
                    MetricCard(title: "内存", icon: "memorychip", value: MetricFormat.percent(store.latest?.memoryUsage), subtitle: memorySubtitle, tint: .orange, samples: store.samples, timeDomain: store.chartWindow, comparison: cliptoMemoryComparison, barMaximum: 100) { $0.memoryUsage }
                    MetricCard(title: "ANE 功耗", icon: "brain.head.profile", value: MetricFormat.watts(store.latest?.anePowerWatts), subtitle: "", tint: .pink, samples: store.samples, timeDomain: store.chartWindow) { $0.anePowerWatts }
                    MetricCard(title: "整机功耗", icon: "bolt.fill", value: MetricFormat.watts(store.latest?.systemPowerWatts), subtitle: "", tint: .yellow, samples: store.samples, timeDomain: store.chartWindow) { $0.systemPowerWatts }
                    MetricCard(title: "Swap", icon: "arrow.left.arrow.right.square", value: swapUsed, subtitle: "已用 / 共 \(swapTotal)", tint: .green, samples: store.samples, timeDomain: store.chartWindow, barMaximum: 100) { sample in
                        sample.swapTotalBytes > 0 ? sample.swapUsedBytes / sample.swapTotalBytes * 100 : nil
                    }
                }

                TelemetryChart(
                    title: "处理器负载", subtitle: processorSubtitle, icon: "waveform.path.ecg", samples: store.samples,
                    series: processorSeries, suffix: "%", timeDomain: store.chartWindow
                )

                HStack(alignment: .top, spacing: 16) {
                    TelemetryChart(
                        title: "内存带宽", subtitle: "IOReport AMC 的 DRAM 读写计数器", icon: "memorychip", samples: store.samples,
                        series: [
                            .init(name: "读取", color: .orange, value: { $0.memoryReadGBps }),
                            .init(name: "写入", color: .red, value: { $0.memoryWriteGBps })
                        ], suffix: " GB/s", timeDomain: store.chartWindow
                    )
                    TelemetryChart(
                        title: "网络带宽", subtitle: "所有活跃网络接口的实时吞吐", icon: "network", samples: store.samples,
                        series: [
                            .init(name: "下载", color: .blue, value: { $0.networkDownBytesPerSecond / 1_000_000 }),
                            .init(name: "上传", color: .mint, value: { $0.networkUpBytesPerSecond / 1_000_000 })
                        ], suffix: " MB/s", timeDomain: store.chartWindow
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    TelemetryChart(
                        title: "磁盘吞吐", subtitle: diskSubtitle, icon: "internaldrive", samples: store.samples,
                        series: diskSeries, suffix: " MB/s", timeDomain: store.chartWindow
                    )
                    TelemetryChart(
                        title: "芯片功耗", subtitle: "IOReport 能耗模型，适合趋势观察", icon: "bolt.fill", samples: store.samples,
                        series: [
                            .init(name: "CPU", color: .cyan, value: { $0.cpuPowerWatts }),
                            .init(name: "GPU", color: .purple, value: { $0.gpuPowerWatts }),
                            .init(name: "ANE", color: .pink, value: { $0.anePowerWatts })
                        ], suffix: " W", timeDomain: store.chartWindow
                    )
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .background(AppBackground())
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 13) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(PulseTheme.cyan)
                    .frame(width: 34, height: 34)
                    .background(PulseTheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("资源总览").font(.system(size: 28, weight: .semibold, design: .default))
                    Text("性能、带宽与能耗，一览无余").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("时间范围", selection: Binding(
                get: { store.selectedRange },
                set: { store.selectHistoryRange($0) }
            )) {
                ForEach(HistoryRange.allCases) { range in Text(range.title).tag(range) }
            }
            .pickerStyle(.segmented)
            .frame(width: 460)
            Button { store.exportCurrentRange() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var customRangePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("自定义时间范围", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                StatusPill(text: "固定区间", color: .orange)
                Text("\(store.samples.count) 个采样点")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 12) {
                DateTimeField(title: "开始", icon: "calendar.badge.clock", tint: PulseTheme.cyan, date: $store.customFrom)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                DateTimeField(title: "结束", icon: "calendar.badge.checkmark", tint: PulseTheme.violet, date: $store.customTo)
            }

            HStack {
                if store.customTo <= store.customFrom {
                    Label("结束时间需要晚于开始时间", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(customRangeSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("现在") { store.customTo = Date() }
                    .help("将结束时间设为当前时间")
                Button("应用") { store.applyCustomRange() }
                    .buttonStyle(.borderedProminent)
                    .help("应用自定义时间范围")
            }
        }
        .padding(16)
        .glassPanel()
    }

    private var customRangeSummary: String {
        let interval = max(0, store.customTo.timeIntervalSince(store.customFrom))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return "跨度 \(formatter.string(from: interval) ?? "—")"
    }

    private var memorySubtitle: String {
        guard let latest = store.latest else { return "采样中" }
        if let cliptoMemory = latest.cliptoMemoryBytes {
            return "Clipto \(MetricFormat.bytes(cliptoMemory))"
        }
        return "\(MetricFormat.bytes(latest.memoryUsedBytes)) / \(MetricFormat.bytes(latest.memoryTotalBytes))"
    }

    private var cpuSubtitle: String {
        guard let latest = store.latest else { return "采样中" }
        guard let clipto = cliptoCPUShare(latest) else { return latest.thermalState }
        return "Clipto \(MetricFormat.percent(clipto)) 整机"
    }

    private var gpuSubtitle: String {
        guard let value = store.latest?.cliptoGPUPercent else { return "设备利用率" }
        return "Clipto \(MetricFormat.percent(value))"
    }

    private var processorSubtitle: String {
        hasCliptoSamples
            ? "CPU/GPU 为系统计数器；Clipto 为整机 CPU 占比；ANE 为活跃度估算"
            : "CPU/GPU 为系统计数器；ANE 为活跃度估算"
    }

    private var diskSubtitle: String {
        hasCliptoSamples ? "内部存储总吞吐与 Clipto 进程组吞吐" : "内部存储实时读写速率"
    }

    private var hasCliptoSamples: Bool {
        store.samples.contains { $0.cliptoRunning }
    }

    private var hasCliptoGPUSamples: Bool {
        store.samples.contains { $0.cliptoGPUPercent != nil }
    }

    private var processorSeries: [TelemetrySeries] {
        var result: [TelemetrySeries] = [
            .init(name: "CPU", color: .cyan, value: { $0.cpuUsage }),
            .init(name: "GPU", color: .purple, value: { $0.gpuUsage }),
            .init(name: "ANE", color: .pink, value: { $0.aneUsage })
        ]
        if hasCliptoSamples {
            result.append(.init(name: "Clipto CPU", color: .yellow, value: cliptoCPUShare))
        }
        if hasCliptoGPUSamples {
            result.append(.init(name: "Clipto GPU", color: .orange, value: { $0.cliptoGPUPercent }))
        }
        return result
    }

    private var cliptoCPUComparison: TelemetrySeries? {
        guard hasCliptoSamples else { return nil }
        return .init(name: "Clipto", color: .yellow, value: cliptoCPUShare)
    }

    private var cliptoGPUComparison: TelemetrySeries? {
        guard hasCliptoGPUSamples else { return nil }
        return .init(name: "Clipto", color: .orange, value: { $0.cliptoGPUPercent })
    }

    private var cliptoMemoryComparison: TelemetrySeries? {
        guard hasCliptoSamples else { return nil }
        return .init(name: "Clipto", color: .yellow, value: { sample in
            guard let bytes = sample.cliptoMemoryBytes, sample.memoryTotalBytes > 0 else { return nil }
            return bytes / sample.memoryTotalBytes * 100
        })
    }

    private var diskSeries: [TelemetrySeries] {
        var result: [TelemetrySeries] = [
            .init(name: "读取", color: .green, value: { $0.diskReadBytesPerSecond / 1_000_000 }),
            .init(name: "写入", color: .teal, value: { $0.diskWriteBytesPerSecond / 1_000_000 })
        ]
        if hasCliptoSamples {
            result.append(.init(name: "Clipto 读取", color: .orange, value: { $0.cliptoDiskReadBytesPerSecond.map { $0 / 1_000_000 } }))
            result.append(.init(name: "Clipto 写入", color: .pink, value: { $0.cliptoDiskWriteBytesPerSecond.map { $0 / 1_000_000 } }))
        }
        return result
    }

    private func cliptoCPUShare(_ sample: MetricSample) -> Double? {
        sample.cliptoCPUPercent.map { $0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) }
    }

    private var swapUsed: String { store.latest.map { MetricFormat.bytes($0.swapUsedBytes) } ?? "—" }
    private var swapTotal: String { store.latest.map { MetricFormat.bytes($0.swapTotalBytes) } ?? "—" }
}
