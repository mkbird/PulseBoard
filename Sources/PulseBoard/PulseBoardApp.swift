import SwiftUI

@main
struct PulseBoardApp: App {
    @StateObject private var store = MonitorStore()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .saveItem) {
                Button(L10n.text("menu.export_range")) { store.exportCurrentRange() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("PulseBoard").font(.headline)
                Divider()
                Text("CPU  \(MetricFormat.percent(store.latest?.cpuUsage))")
                Text("GPU  \(MetricFormat.percent(store.latest?.gpuUsage))")
                Text(L10n.format("menu.memory", MetricFormat.percent(store.latest?.memoryUsage)))
                Divider()
                Button(L10n.text("menu.export_range")) { store.exportCurrentRange() }
                Button(L10n.text("menu.quit")) { NSApplication.shared.terminate(nil) }
            }
            .padding(8)
        } label: {
            Label("\(Int(store.latest?.cpuUsage ?? 0))%", systemImage: "waveform.path.ecg")
        }
    }
}
