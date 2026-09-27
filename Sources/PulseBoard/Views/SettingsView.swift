import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MonitorStore
    @EnvironmentObject private var localization: LocalizationManager
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
                        Text(L10n.text("settings.title")).font(.system(size: 28, weight: .semibold, design: .default))
                        Text(L10n.text("settings.subtitle")).font(.callout).foregroundStyle(.secondary)
                    }
                }

                settingsSection(L10n.text("settings.language"), icon: "globe") {
                    LabeledContent(L10n.text("settings.app_language")) {
                        Picker(L10n.text("settings.app_language"), selection: $localization.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .frame(width: 190)
                    }
                    Text(L10n.text("settings.language_hint"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                settingsSection(L10n.text("settings.sampling_history"), icon: "clock.arrow.circlepath") {
                    LabeledContent(L10n.text("settings.sampling_interval")) {
                        Picker(L10n.text("settings.sampling_interval"), selection: $store.samplingInterval) {
                            Text(L10n.format("settings.seconds", 1)).tag(TimeInterval(1))
                            Text(L10n.format("settings.seconds", 2)).tag(TimeInterval(2))
                            Text(L10n.format("settings.seconds", 5)).tag(TimeInterval(5))
                            Text(L10n.format("settings.seconds", 10)).tag(TimeInterval(10))
                        }.frame(width: 140)
                    }
                    LabeledContent(L10n.text("settings.history_retention")) {
                        Picker(L10n.text("settings.history_retention"), selection: $store.retentionDays) {
                            Text(L10n.format("settings.days", 7)).tag(7)
                            Text(L10n.format("settings.days", 30)).tag(30)
                            Text(L10n.format("settings.days", 90)).tag(90)
                            Text(L10n.format("settings.days_max", MonitorStore.maximumRetentionDays)).tag(MonitorStore.maximumRetentionDays)
                        }.frame(width: 140)
                    }
                    LabeledContent(L10n.text("settings.database")) { Text("~/Library/Application Support/PulseBoard/history.sqlite").font(.caption).foregroundStyle(.secondary) }
                }

                settingsSection(L10n.text("settings.enhanced_metrics"), icon: "gauge.with.dots.needle.67percent") {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("settings.enhanced_title")).font(.headline)
                            Text(L10n.text("settings.enhanced_detail"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(
                            text: store.enhancedMetricsAvailable ? L10n.text("settings.sampling_active") : L10n.text("settings.temporarily_unavailable"),
                            color: store.enhancedMetricsAvailable ? .green : .secondary
                        )
                    }
                    Text(L10n.text("settings.power_note"))
                        .font(.caption).foregroundStyle(.tertiary)
                }

                settingsSection(L10n.text("settings.data_sources"), icon: "checkmark.shield") {
                    sourceRow(L10n.text("settings.cpu_memory"), detail: "Mach host statistics", state: L10n.text("settings.public_api"))
                    sourceRow("GPU", detail: "IOReport GPU Performance States", state: L10n.text("settings.gpu_activity"))
                    sourceRow(L10n.text("settings.disk_network"), detail: L10n.text("settings.cumulative_counters"), state: L10n.text("settings.public_api"))
                    sourceRow(L10n.text("settings.ane_power_memory"), detail: L10n.text("settings.built_in_sources"), state: L10n.text("settings.live_enhanced"))
                    sourceRow(
                        L10n.text("settings.clipto_resources"),
                        detail: L10n.text("settings.clipto_sources"),
                        state: store.latest?.cliptoRunning == true ? L10n.text("settings.tracking") : L10n.text("settings.auto_detect")
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
