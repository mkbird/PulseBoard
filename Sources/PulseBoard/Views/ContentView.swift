import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
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
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(PulseTheme.cyan)
                        .frame(width: 30, height: 30)
                        .background(PulseTheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(PulseTheme.stroke) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PulseBoard").font(.headline)
                        Text("Mac 性能中心").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 17)
                .padding(.top, 16)
                .padding(.bottom, 12)

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
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("实时采样中").font(.caption.weight(.semibold))
                    }
                }
                .padding(12)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.07)) }
                .padding(12)
            }
            .background(PulseTheme.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 235)
        } detail: {
            switch selection ?? .overview {
            case .overview: DashboardView()
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
}
