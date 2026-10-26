import AppKit
import SwiftUI

@main
enum CliptoPulseEntry {
    @MainActor
    static func main() {
        if CLIRunner.handleIfNeeded() {
            return
        }
        PulseBoardApp.main()
    }
}

struct PulseBoardApp: App {
    @NSApplicationDelegateAdaptor(PulseBoardAppDelegate.self) private var appDelegate
    @StateObject private var store: MonitorStore
    @StateObject private var localization = LocalizationManager()

    init() {
        let monitor = MonitorStore()
        _store = StateObject(wrappedValue: monitor)
        appDelegate.monitor = monitor
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarControlView()
                .environmentObject(store)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.latest?.cliptoRunning == true ? "bolt.horizontal.circle.fill" : "waveform.path.ecg")
                Text("\(Int((store.latest?.cpuUsage ?? 0).rounded()))%")
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)

        Window("CliptoPulse 原生监控与设置", id: "native-dashboard") {
            ContentView()
                .environmentObject(store)
                .environmentObject(localization)
                .environment(\.locale, localization.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("打开统一网页控制台") { store.openWebConsole() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("打开 Clipto 晨报中心") { store.openWebConsole(hash: "report") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(L10n.text("menu.export_range")) { store.exportCurrentRange() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

private struct MenuBarControlView: View {
    @EnvironmentObject private var store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CliptoPulse")
                        .font(.system(size: 14, weight: .bold))
                    Text(store.webServerRunning ? "常驻采集中 · Web 端口 :\(store.webServerPort)" : "后台采集中（Web 未启动）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(store.webServerRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
            }

            Divider()

            // Live Telemetry Grid
            VStack(alignment: .leading, spacing: 5) {
                telemetryRow(
                    title: "系统负载",
                    value: "CPU \(MetricFormat.percent(store.latest?.cpuUsage)) · GPU \(MetricFormat.percent(store.latest?.gpuUsage)) · \(MetricFormat.watts(store.latest?.systemPowerWatts))"
                )
                telemetryRow(
                    title: "系统内存",
                    value: "\(MetricFormat.bytes(store.latest?.memoryUsedBytes ?? 0)) (\(MetricFormat.percent(store.latest?.memoryUsage)))"
                )
                telemetryRow(
                    title: "Clipto 进程组",
                    value: store.latest?.cliptoRunning == true
                        ? "运行中 · CPU \(MetricFormat.percent(store.latest?.cliptoCPUPercent)) · \(MetricFormat.bytes(store.latest?.cliptoMemoryBytes ?? 0))"
                        : "当前未运行"
                )
                telemetryRow(
                    title: "CMS 进程组",
                    value: store.cmsSession.runningCount > 0
                        ? "\(store.cmsSession.runningCount) 进程 · \(MetricFormat.bytes(store.cmsSession.memory.current ?? 0))"
                        : "当前无活跃进程"
                )
            }
            .padding(9)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            if let feedback = store.menuActionFeedback {
                Text(feedback)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.green)
                    .lineLimit(2)
            }

            // Primary Web & Daily Report Actions
            VStack(spacing: 6) {
                Button {
                    store.openWebConsole()
                } label: {
                    Label("打开统一网页控制台 (127.0.0.1:\(store.webServerPort))", systemImage: "safari.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                HStack(spacing: 6) {
                    Button {
                        store.openWebConsole(hash: "dagsc")
                    } label: {
                        Label("DAGSC 泳道分析", systemImage: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.openWebConsole(hash: "report")
                    } label: {
                        Label("Clipto 晨报中心", systemImage: "doc.richtext")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 6) {
                    Button {
                        store.copyLatestDailyReportImage()
                    } label: {
                        Label("复制晨报图片", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.copyLatestDailyReportMarkdown()
                    } label: {
                        Label("复制 Markdown", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .help("基于最近一个测试批次生成晨报；请在 Clipto 全部跑完后再复制")

                Button {
                    store.copyLANAddressToPasteboard()
                } label: {
                    Label("复制局域网共享网址 (\(store.primaryLANURLString))", systemImage: "network")
                        .font(.system(size: 11.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }

            Divider()

            Toggle("防止 Mac 睡眠与 App Nap（夜跑请保持开启）", isOn: $store.preventSleep)
                .font(.system(size: 12))
                .help("阻止系统空闲睡眠并关闭 App Nap，保证整夜 1 Hz 采样；显示器仍可正常熄屏。合盖且未接电源时 macOS 仍会强制睡眠。")
            Toggle("启动时自动弹出网页控制台", isOn: $store.autoOpenWebOnLaunch)
                .font(.system(size: 12))

            HStack {
                Button("原生监控与设置…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "native-dashboard")
                }
                .buttonStyle(.link)
                .font(.system(size: 12))

                Spacer()

                Button(store.isWiping ? "正在清空…" : "清空全部记录…") {
                    store.confirmAndWipeAllRecords()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .disabled(store.isWiping)

                Spacer()

                Button("退出 CliptoPulse") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.link)
                .foregroundStyle(.red)
                .font(.system(size: 12))
            }
        }
        .padding(13)
        .frame(width: 340)
    }

    private func telemetryRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
        }
    }
}
