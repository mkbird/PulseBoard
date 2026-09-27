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
                    MetricCard(title: "ANE", icon: "brain.head.profile", value: MetricFormat.watts(store.latest?.anePowerWatts), subtitle: store.enhancedMetricsAvailable ? "IOReport 神经引擎功耗" : "需要增强采样", tint: .pink, samples: store.samples, timeDomain: store.chartWindow) { $0.anePowerWatts }
                    MetricCard(title: "整机功耗", icon: "bolt.fill", value: MetricFormat.watts(store.latest?.systemPowerWatts), subtitle: "SMC 整机功耗", tint: .yellow, samples: store.samples, timeDomain: store.chartWindow) { $0.systemPowerWatts }
                    MetricCard(title: "磁盘空间", icon: "internaldrive", value: diskFree, subtitle: "可用 / \(diskTotal)", tint: .green, samples: store.samples, timeDomain: store.chartWindow) { sample in
                        sample.diskTotalBytes > 0 ? (1 - sample.diskFreeBytes / sample.diskTotalBytes) * 100 : nil
                    }
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
            .padding(24)
        }
        .background(background)
        .onAppear { store.resumeLiveRange() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("资源总览").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("持续记录这台 Mac 的性能、带宽与能耗趋势").foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: store.enhancedMetricsAvailable ? "增强指标在线" : "标准采样", color: store.enhancedMetricsAvailable ? .green : .orange)
            Picker("时间范围", selection: $store.selectedRange) {
                ForEach(HistoryRange.allCases.filter { $0 != .custom }) { range in Text(range.title).tag(range) }
            }
            .pickerStyle(.segmented)
            .frame(width: 410)
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
    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [.cyan.opacity(0.08), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
        }.ignoresSafeArea()
    }
}
