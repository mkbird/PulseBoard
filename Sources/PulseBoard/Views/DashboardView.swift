import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: MonitorStore

    private let grid = [GridItem(.adaptive(minimum: 245), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                LazyVGrid(columns: grid, spacing: 16) {
                    MetricCard(title: "CPU", icon: "cpu", value: MetricFormat.percent(store.latest?.cpuUsage), subtitle: store.latest?.thermalState ?? "采样中", tint: .cyan, samples: store.samples, timeDomain: store.chartWindow) { $0.cpuUsage }
                    MetricCard(title: "GPU", icon: "rectangle.3.group", value: MetricFormat.percent(store.latest?.gpuUsage), subtitle: "设备利用率", tint: .purple, samples: store.samples, timeDomain: store.chartWindow) { $0.gpuUsage }
                    MetricCard(title: "内存", icon: "memorychip", value: MetricFormat.percent(store.latest?.memoryUsage), subtitle: memorySubtitle, tint: .orange, samples: store.samples, timeDomain: store.chartWindow) { $0.memoryUsage }
                    MetricCard(title: "ANE 功耗", icon: "brain.head.profile", value: MetricFormat.watts(store.latest?.anePowerWatts), subtitle: "", tint: .pink, samples: store.samples, timeDomain: store.chartWindow) { $0.anePowerWatts }
                    MetricCard(title: "整机功耗", icon: "bolt.fill", value: MetricFormat.watts(store.latest?.systemPowerWatts), subtitle: "", tint: .yellow, samples: store.samples, timeDomain: store.chartWindow) { $0.systemPowerWatts }
                    MetricCard(title: "磁盘空间", icon: "internaldrive", value: diskFree, subtitle: "可用 / \(diskTotal)", tint: .green, samples: store.samples, timeDomain: store.chartWindow) { sample in
                        sample.diskTotalBytes > 0 ? (1 - sample.diskFreeBytes / sample.diskTotalBytes) * 100 : nil
                    }
                }

                if let latest = store.latest, latest.cliptoRunning {
                    CliptoResourcePanel(
                        latest: latest,
                        samples: store.samples,
                        timeDomain: store.chartWindow
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                TelemetryChart(
                    title: "处理器负载", subtitle: "CPU/GPU 为系统计数器；ANE 为活跃度估算", icon: "waveform.path.ecg", samples: store.samples,
                    series: [
                        .init(name: "CPU", color: .cyan, value: { $0.cpuUsage }),
                        .init(name: "GPU", color: .purple, value: { $0.gpuUsage }),
                        .init(name: "ANE", color: .pink, value: { $0.aneUsage })
                    ], suffix: "%", timeDomain: store.chartWindow
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
                        title: "磁盘吞吐", subtitle: "内部存储实时读写速率", icon: "internaldrive", samples: store.samples,
                        series: [
                            .init(name: "读取", color: .green, value: { $0.diskReadBytesPerSecond / 1_000_000 }),
                            .init(name: "写入", color: .teal, value: { $0.diskWriteBytesPerSecond / 1_000_000 })
                        ], suffix: " MB/s", timeDomain: store.chartWindow
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
        .onAppear { store.resumeLiveRange() }
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
            StatusPill(text: store.enhancedMetricsAvailable ? "增强指标在线" : "标准采样", color: store.enhancedMetricsAvailable ? .green : .orange)
            Picker("时间范围", selection: $store.selectedRange) {
                ForEach(HistoryRange.allCases.filter { $0 != .custom }) { range in Text(range.title).tag(range) }
            }
            .pickerStyle(.segmented)
            .frame(width: 390)
            Button { store.exportCurrentRange() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var memorySubtitle: String {
        guard let latest = store.latest else { return "采样中" }
        return "\(MetricFormat.bytes(latest.memoryUsedBytes)) / \(MetricFormat.bytes(latest.memoryTotalBytes))"
    }
    private var diskFree: String { store.latest.map { MetricFormat.bytes($0.diskFreeBytes) } ?? "—" }
    private var diskTotal: String { store.latest.map { MetricFormat.bytes($0.diskTotalBytes) } ?? "—" }
}

private struct CliptoResourcePanel: View {
    let latest: MetricSample
    let samples: [MetricSample]
    let timeDomain: ClosedRange<Date>

    private var cpuPoints: [CliptoCPUPoint] {
        samples.compactMap { sample in
            guard timeDomain.contains(sample.timestamp), let value = sample.cliptoCPUPercent else { return nil }
            return CliptoCPUPoint(timestamp: sample.timestamp, value: value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "app.badge")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PulseTheme.cyan)
                    .frame(width: 30, height: 30)
                    .background(PulseTheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clipto 资源").font(.headline)
                    Text("主进程、Helper 与分析服务合计").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                StatusPill(text: "运行中 · \(latest.cliptoProcessCount ?? 0) 个进程", color: .green)
            }

            HStack(alignment: .top, spacing: 24) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    CliptoMetric(title: "CPU", value: cpuText, note: "多核可超过 100%", color: .cyan)
                    CliptoMetric(title: "内存", value: byteText(latest.cliptoMemoryBytes), note: "物理占用估算", color: .orange)
                    CliptoMetric(title: "磁盘读取", value: rateText(latest.cliptoDiskReadBytesPerSecond), note: "当前速率", color: .green)
                    CliptoMetric(title: "磁盘写入", value: rateText(latest.cliptoDiskWriteBytesPerSecond), note: "当前速率", color: .teal)
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 146)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("CPU 趋势").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(cpuText).font(.callout.monospacedDigit()).foregroundStyle(PulseTheme.cyan)
                    }
                    Chart(cpuPoints) { point in
                        AreaMark(
                            x: .value("时间", point.timestamp),
                            y: .value("CPU", point.value)
                        )
                        .foregroundStyle(LinearGradient(
                            colors: [PulseTheme.cyan.opacity(0.18), PulseTheme.cyan.opacity(0.005)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value("CPU", point.value)
                        )
                        .foregroundStyle(PulseTheme.cyan)
                        .lineStyle(.init(lineWidth: 1.7))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.quaternary)
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text("\(number, format: .number.precision(.fractionLength(0)))%")
                                }
                            }
                        }
                    }
                    .chartXScale(domain: timeDomain)
                    .frame(height: 116)
                }
                .frame(maxWidth: .infinity)
            }

            Text("GPU、ANE 与功耗无法通过 macOS 公共接口可靠归属到单个 App，仍显示整机数据。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .glassPanel()
    }

    private var cpuText: String {
        latest.cliptoCPUPercent.map { String(format: "%.1f%%", $0) } ?? "—"
    }

    private func byteText(_ value: Double?) -> String {
        value.map(MetricFormat.bytes) ?? "—"
    }

    private func rateText(_ value: Double?) -> String {
        value.map(MetricFormat.rate) ?? "—"
    }
}

private struct CliptoMetric: View {
    let title: String
    let value: String
    let note: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 19, weight: .medium)).monospacedDigit().lineLimit(1)
            Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(PulseTheme.stroke) }
    }
}

private struct CliptoCPUPoint: Identifiable {
    let timestamp: Date
    let value: Double
    var id: Date { timestamp }
}
