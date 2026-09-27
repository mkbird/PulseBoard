import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack {
                    HStack(spacing: 13) {
                        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(PulseTheme.violet)
                            .frame(width: 34, height: 34)
                            .background(PulseTheme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("历史与导出").font(.system(size: 28, weight: .semibold, design: .default))
                            Text("探索任意时间窗口，导出始终保留原始记录").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { store.exportCurrentRange() } label: { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 14) {
                    DatePicker("开始", selection: $store.customFrom)
                    DatePicker("结束", selection: $store.customTo)
                    Button("应用") { store.applyCustomRange() }
                    Spacer()
                    Text("当前显示 \(store.samples.count) 个采样点")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .glassPanel(tint: PulseTheme.violet)

                TelemetryChart(
                    title: "CPU / GPU / ANE / 内存", subtitle: "跨指标查看负载变化与相关性", icon: "chart.xyaxis.line", samples: store.samples,
                    series: [
                        .init(name: "CPU", color: .cyan, value: { $0.cpuUsage }),
                        .init(name: "GPU", color: .purple, value: { $0.gpuUsage }),
                        .init(name: "ANE", color: .pink, value: { $0.aneUsage }),
                        .init(name: "内存", color: .orange, value: { $0.memoryUsage })
                    ], suffix: "%", timeDomain: store.chartWindow
                )
                TelemetryChart(
                    title: "系统功耗", subtitle: "CPU、GPU、ANE 分项历史", icon: "bolt", samples: store.samples,
                    series: [
                        .init(name: "CPU", color: .cyan, value: { $0.cpuPowerWatts }),
                        .init(name: "GPU", color: .purple, value: { $0.gpuPowerWatts }),
                        .init(name: "ANE", color: .pink, value: { $0.anePowerWatts })
                    ], suffix: " W", timeDomain: store.chartWindow
                )
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .background(AppBackground())
    }
}
