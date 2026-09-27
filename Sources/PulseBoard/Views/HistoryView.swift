import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: MonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("历史与导出").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("选择任意时间窗口；长时间范围会自动降采样，导出仍保留原始记录。")
                            .foregroundStyle(.secondary)
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
                .glassPanel()

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
            .padding(24)
        }
    }
}
