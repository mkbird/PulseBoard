import AppKit
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case history = "历史"
    case settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .history: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: MonitorStore
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                        .shadow(color: PulseTheme.cyan.opacity(0.22), radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PulseBoard").font(.headline)
                        Text("Mac 性能中心").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 17)
                .padding(.top, 18)
                .padding(.bottom, 14)

                List(AppSection.allCases, selection: $selection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .font(.system(size: 14, weight: .medium))
                        .padding(.vertical, 5)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 7) {
                        Circle().fill(.green).frame(width: 7, height: 7).shadow(color: .green, radius: 4)
                        Text("实时采样中").font(.caption.weight(.semibold))
                        Spacer()
                        Text(store.latest?.timestamp.formatted(date: .omitted, time: .shortened) ?? "—")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 12) {
                        sidebarMetric("CPU", value: MetricFormat.percent(store.latest?.cpuUsage), color: .cyan)
                        sidebarMetric("GPU", value: MetricFormat.percent(store.latest?.gpuUsage), color: .purple)
                    }
                }
                .padding(12)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.08)) }
                .padding(12)
            }
            .background(PulseTheme.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 235)
        } detail: {
            switch selection ?? .overview {
            case .overview: DashboardView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .preferredColorScheme(.dark)
        .tint(PulseTheme.cyan)
        .alert("PulseBoard", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )) { Button("好", role: .cancel) {} } message: { Text(store.errorMessage ?? "") }
    }

    private func sidebarMetric(_ name: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
    }
}
