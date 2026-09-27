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
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationTitle("PulseBoard")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("实时采样中").font(.caption.weight(.medium))
                    }
                    Text(store.latest?.timestamp.formatted(date: .omitted, time: .standard) ?? "—")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } detail: {
            switch selection ?? .overview {
            case .overview: DashboardView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .alert("PulseBoard", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )) { Button("好", role: .cancel) {} } message: { Text(store.errorMessage ?? "") }
    }
}
