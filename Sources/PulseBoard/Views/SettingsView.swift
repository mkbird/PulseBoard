import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MonitorStore
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 13) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(PulseTheme.cyan)
                        .frame(width: 34, height: 34)
                        .background(PulseTheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设置").font(.system(size: 28, weight: .semibold, design: .default))
                        Text("采样、历史记录与数据源").font(.callout).foregroundStyle(.secondary)
                    }
                }

                settingsSection("采样与历史", icon: "clock.arrow.circlepath") {
                    LabeledContent("采样间隔") {
                        Picker("采样间隔", selection: $store.samplingInterval) {
                            Text("1 秒").tag(TimeInterval(1))
                            Text("2 秒").tag(TimeInterval(2))
                            Text("5 秒").tag(TimeInterval(5))
                            Text("10 秒").tag(TimeInterval(10))
                        }.frame(width: 140)
                    }
                    LabeledContent("历史保留") {
                        Picker("历史保留", selection: $store.retentionDays) {
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                            Text("90 天").tag(90)
                        }.frame(width: 140)
                    }
                    LabeledContent("数据库") { Text("~/Library/Application Support/PulseBoard/history.sqlite").font(.caption).foregroundStyle(.secondary) }
                }

                settingsSection("增强指标", icon: "gauge.with.dots.needle.67percent") {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ANE、分项功耗与应用级 GPU").font(.headline)
                            Text("整机指标优先使用内置 IOReport/SMC；启用辅助进程后，还可获得 Clipto GPU、网络与 Energy Impact。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(text: store.enhancedMetricsAvailable ? "正在采样" : store.helperStatus.title, color: helperColor)
                    }
                    HStack {
                        Text(store.enhancedMetricsFile.path).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        switch store.helperStatus {
                        case .enabled:
                            Button("停用", role: .destructive) { store.disableEnhancedMonitoring() }
                        case .requiresApproval:
                            Button("打开系统设置") { store.openHelperApprovalSettings() }
                                .buttonStyle(.borderedProminent)
                        case .notRegistered, .notFound:
                            Button("启用高级监控") { store.enableEnhancedMonitoring() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    DisclosureGroup("终端兼容模式") {
                        HStack {
                            Text("无法启用辅助进程时，可复制命令并在终端中运行。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                store.copyEnhancedMetricsCommand()
                                copied = true
                                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                            } label: {
                                Label(copied ? "已复制" : "复制命令", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                        }.padding(.top, 8)
                    }
                    Text("IOReport 与 SMC 的功耗属于系统估算值，适合观察同一设备的变化趋势，不适合跨设备比较。")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                settingsSection("数据来源", icon: "checkmark.shield") {
                    sourceRow("CPU、内存", detail: "Mach host statistics", state: "公开 API")
                    sourceRow("GPU", detail: "IOKit PerformanceStatistics", state: "公开系统数据")
                    sourceRow("磁盘、网络", detail: "IOKit / getifaddrs 累计计数器", state: "公开 API")
                    sourceRow("ANE、功耗、内存带宽", detail: "内置 IOReport / SMC", state: "实时增强")
                    sourceRow(
                        "Clipto 应用资源",
                        detail: "libproc；GPU/网络/能耗使用 powermetrics",
                        state: store.latest?.cliptoRunning == true ? "正在跟踪" : "自动检测"
                    )
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AppBackground())
    }

    private var helperColor: Color {
        if store.enhancedMetricsAvailable { return .green }
        switch store.helperStatus {
        case .enabled: return .blue
        case .requiresApproval: return .orange
        case .notRegistered, .notFound: return .secondary
        }
    }

    private func settingsSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.title3.bold())
            content()
        }
        .padding(20)
        .glassPanel()
    }

    private func sourceRow(_ title: String, detail: String, state: String) -> some View {
        HStack {
            Text(title).frame(width: 170, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
            Spacer()
            Text(state)
                .font(.caption.weight(.medium))
                .foregroundStyle(PulseTheme.cyan)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(PulseTheme.cyan.opacity(0.10), in: Capsule())
        }
    }
}
