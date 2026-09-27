import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: MonitorStore
    @EnvironmentObject private var localization: LocalizationManager

    private let grid = Array(repeating: GridItem(.flexible(minimum: 245), spacing: 16), count: 3)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                if store.selectedRange == .custom {
                    customRangePanel
                }
                LazyVGrid(columns: grid, spacing: 16) {
                    MetricCard(title: "CPU", icon: "cpu", value: MetricFormat.percent(store.latest?.cpuUsage), subtitle: cpuSubtitle, tint: .cyan, samples: store.samples, timeDomain: store.chartWindow, comparison: cliptoCPUComparison, barMaximum: 100) { $0.cpuUsage }
                    MetricCard(title: "GPU", icon: "rectangle.3.group", value: MetricFormat.percent(store.latest?.gpuUsage), subtitle: gpuSubtitle, tint: .purple, samples: store.samples, timeDomain: store.chartWindow, comparison: cliptoGPUComparison, barMaximum: 100) { $0.gpuUsage }
                    MetricCard(title: L10n.text("metric.memory"), icon: "memorychip", value: MetricFormat.percent(store.latest?.memoryUsage), subtitle: memorySubtitle, tint: .orange, samples: store.samples, timeDomain: store.chartWindow, comparison: cliptoMemoryComparison, barMaximum: 100) { $0.memoryUsage }
                    MetricCard(title: L10n.text("metric.ane_power"), icon: "brain.head.profile", value: MetricFormat.watts(store.latest?.anePowerWatts), subtitle: "", tint: .pink, samples: store.samples, timeDomain: store.chartWindow) { $0.anePowerWatts }
                    MetricCard(title: L10n.text("metric.system_power"), icon: "bolt.fill", value: MetricFormat.watts(store.latest?.systemPowerWatts), subtitle: "", tint: .yellow, samples: store.samples, timeDomain: store.chartWindow) { $0.systemPowerWatts }
                    MetricCard(title: "Swap", icon: "arrow.left.arrow.right.square", value: swapUsed, subtitle: L10n.format("metric.swap_used_total", swapTotal), tint: .green, samples: store.samples, timeDomain: store.chartWindow, barMaximum: 100) { sample in
                        sample.swapTotalBytes > 0 ? sample.swapUsedBytes / sample.swapTotalBytes * 100 : nil
                    }
                }

                TelemetryChart(
                    title: L10n.text("metric.processor_load"), subtitle: processorSubtitle, icon: "waveform.path.ecg", samples: store.samples,
                    series: processorSeries, suffix: "%", timeDomain: store.chartWindow
                )

                TelemetryChart(
                    title: L10n.text("metric.memory_usage"), subtitle: memoryUsageSubtitle, icon: "memorychip", samples: store.samples,
                    series: memoryUsageSeries, suffix: "%", timeDomain: store.chartWindow
                )

                HStack(alignment: .top, spacing: 16) {
                    TelemetryChart(
                        title: L10n.text("metric.memory_bandwidth"), subtitle: L10n.text("subtitle.memory_io"), icon: "memorychip", samples: store.samples,
                        series: [
                            .init(name: L10n.text("series.read"), color: .orange, value: { $0.memoryReadGBps }),
                            .init(name: L10n.text("series.write"), color: .red, value: { $0.memoryWriteGBps })
                        ], suffix: " GB/s", timeDomain: store.chartWindow
                    )
                    TelemetryChart(
                        title: L10n.text("metric.network_bandwidth"), subtitle: L10n.text("subtitle.network"), icon: "network", samples: store.samples,
                        series: [
                            .init(name: L10n.text("series.download"), color: .blue, value: { $0.networkDownBytesPerSecond / 1_000_000 }),
                            .init(name: L10n.text("series.upload"), color: .mint, value: { $0.networkUpBytesPerSecond / 1_000_000 })
                        ], suffix: " MB/s", timeDomain: store.chartWindow
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    TelemetryChart(
                        title: L10n.text("metric.disk_throughput"), subtitle: diskSubtitle, icon: "internaldrive", samples: store.samples,
                        series: diskSeries, suffix: " MB/s", timeDomain: store.chartWindow
                    )
                    TelemetryChart(
                        title: L10n.text("metric.chip_power"), subtitle: L10n.text("subtitle.chip_power"), icon: "bolt.fill", samples: store.samples,
                        series: [
                            .init(name: "CPU", color: .cyan, value: { $0.cpuPowerWatts }),
                            .init(name: "GPU", color: .purple, value: { $0.gpuPowerWatts }),
                            .init(name: "ANE", color: .pink, value: { $0.anePowerWatts })
                        ], suffix: " W", timeDomain: store.chartWindow
                    )
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .background(AppBackground())
        .environment(\.locale, localization.locale)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 13) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(PulseTheme.cyan)
                    .frame(width: 34, height: 34)
                    .background(PulseTheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("dashboard.title")).font(.system(size: 28, weight: .semibold, design: .default))
                    Text(L10n.text("dashboard.subtitle")).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker(L10n.text("dashboard.time_range"), selection: Binding(
                get: { store.selectedRange },
                set: { store.selectHistoryRange($0) }
            )) {
                ForEach(HistoryRange.allCases) { range in Text(range.title).tag(range) }
            }
            .pickerStyle(.segmented)
            .frame(width: 460)
            Button { store.exportCurrentRange() } label: { Label(L10n.text("common.export"), systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var customRangePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.text("dashboard.custom_range"), systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                StatusPill(text: L10n.text("dashboard.fixed_range"), color: .orange)
                Text(L10n.format("dashboard.sample_count", store.samples.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 12) {
                DateTimeField(title: L10n.text("dashboard.start"), icon: "calendar.badge.clock", tint: PulseTheme.cyan, date: $store.customFrom)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                DateTimeField(title: L10n.text("dashboard.end"), icon: "calendar.badge.checkmark", tint: PulseTheme.violet, date: $store.customTo)
            }

            HStack {
                if store.customTo <= store.customFrom {
                    Label(L10n.text("dashboard.invalid_range"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(customRangeSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(L10n.text("common.now")) { store.customTo = Date() }
                    .help(L10n.text("dashboard.set_end_now_help"))
                Button(L10n.text("common.apply")) { store.applyCustomRange() }
                    .buttonStyle(.borderedProminent)
                    .help(L10n.text("dashboard.apply_range_help"))
            }
        }
        .padding(16)
        .glassPanel()
    }

    private var customRangeSummary: String {
        let interval = max(0, store.customTo.timeIntervalSince(store.customFrom))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        return L10n.format("dashboard.range_span", formatter.string(from: interval) ?? "—")
    }

    private var memorySubtitle: String {
        guard let latest = store.latest else { return L10n.text("metric.sampling") }
        if let cliptoMemory = latest.cliptoMemoryBytes {
            return "Clipto \(MetricFormat.bytes(cliptoMemory))"
        }
        return "\(MetricFormat.bytes(latest.memoryUsedBytes)) / \(MetricFormat.bytes(latest.memoryTotalBytes))"
    }

    private var cpuSubtitle: String {
        guard let latest = store.latest else { return L10n.text("metric.sampling") }
        guard let clipto = cliptoCPUShare(latest) else { return latest.thermalStateLabel }
        return L10n.format("subtitle.clipto_cpu", MetricFormat.percent(clipto))
    }

    private var gpuSubtitle: String {
        guard let value = store.latest?.cliptoGPUPercent else { return L10n.text("metric.device_utilization") }
        return "Clipto \(MetricFormat.percent(value))"
    }

    private var processorSubtitle: String {
        hasCliptoSamples
            ? L10n.text("subtitle.processor_clipto")
            : L10n.text("subtitle.processor")
    }

    private var diskSubtitle: String {
        hasCliptoSamples ? L10n.text("subtitle.disk_clipto") : L10n.text("subtitle.disk")
    }

    private var hasCliptoSamples: Bool {
        store.samples.contains { $0.cliptoRunning }
    }

    private var hasCliptoGPUSamples: Bool {
        store.samples.contains { $0.cliptoGPUPercent != nil }
    }

    private var hasCliptoMemorySamples: Bool {
        store.samples.contains { cliptoMemoryShare($0) != nil }
    }

    private var processorSeries: [TelemetrySeries] {
        var result: [TelemetrySeries] = [
            .init(name: "CPU", color: .cyan, value: { $0.cpuUsage }),
            .init(name: "GPU", color: .purple, value: { $0.gpuUsage }),
            .init(name: "ANE", color: .pink, value: { $0.aneUsage })
        ]
        if hasCliptoSamples {
            result.append(.init(name: "Clipto CPU", color: .yellow, value: cliptoCPUShare))
        }
        if hasCliptoGPUSamples {
            result.append(.init(name: "Clipto GPU", color: .orange, value: { $0.cliptoGPUPercent }))
        }
        return result
    }

    private var cliptoCPUComparison: TelemetrySeries? {
        guard hasCliptoSamples else { return nil }
        return .init(name: "Clipto", color: .yellow, value: cliptoCPUShare)
    }

    private var cliptoGPUComparison: TelemetrySeries? {
        guard hasCliptoGPUSamples else { return nil }
        return .init(name: "Clipto", color: .orange, value: { $0.cliptoGPUPercent })
    }

    private var cliptoMemoryComparison: TelemetrySeries? {
        guard hasCliptoMemorySamples else { return nil }
        return .init(name: "Clipto", color: .yellow, value: cliptoMemoryShare)
    }

    private var memoryUsageSubtitle: String {
        hasCliptoMemorySamples
            ? L10n.text("subtitle.memory_usage_clipto")
            : L10n.text("subtitle.memory_usage")
    }

    private var memoryUsageSeries: [TelemetrySeries] {
        var result: [TelemetrySeries] = [
            .init(name: L10n.text("series.system_memory"), color: .orange, value: { $0.memoryUsage })
        ]
        if hasCliptoMemorySamples {
            result.append(.init(name: L10n.text("series.clipto_memory"), color: .yellow, value: cliptoMemoryShare))
        }
        return result
    }

    private var diskSeries: [TelemetrySeries] {
        var result: [TelemetrySeries] = [
            .init(name: L10n.text("series.read"), color: .green, value: { $0.diskReadBytesPerSecond / 1_000_000 }),
            .init(name: L10n.text("series.write"), color: .teal, value: { $0.diskWriteBytesPerSecond / 1_000_000 })
        ]
        if hasCliptoSamples {
            result.append(.init(name: L10n.text("series.clipto_read"), color: .orange, value: { $0.cliptoDiskReadBytesPerSecond.map { $0 / 1_000_000 } }))
            result.append(.init(name: L10n.text("series.clipto_write"), color: .pink, value: { $0.cliptoDiskWriteBytesPerSecond.map { $0 / 1_000_000 } }))
        }
        return result
    }

    private func cliptoCPUShare(_ sample: MetricSample) -> Double? {
        sample.cliptoCPUPercent.map { $0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) }
    }

    private func cliptoMemoryShare(_ sample: MetricSample) -> Double? {
        guard let bytes = sample.cliptoMemoryBytes, sample.memoryTotalBytes > 0 else { return nil }
        return bytes / sample.memoryTotalBytes * 100
    }

    private var swapUsed: String { store.latest.map { MetricFormat.bytes($0.swapUsedBytes) } ?? "—" }
    private var swapTotal: String { store.latest.map { MetricFormat.bytes($0.swapTotalBytes) } ?? "—" }
}
