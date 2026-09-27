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

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("时间范围", systemImage: "calendar")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        StatusPill(
                            text: store.selectedRange == .custom ? "固定区间" : "实时滚动",
                            color: store.selectedRange == .custom ? .orange : .green
                        )
                        Text("\(store.samples.count) 个采样点")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }

                    Picker("时间范围", selection: Binding(
                        get: { store.selectedRange },
                        set: { store.selectHistoryRange($0) }
                    )) {
                        ForEach(HistoryRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if store.selectedRange == .custom {
                        Divider()
                        HStack(alignment: .center, spacing: 12) {
                            DateTimeField(title: "开始", icon: "calendar.badge.clock", tint: PulseTheme.cyan, date: $store.customFrom)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            DateTimeField(title: "结束", icon: "calendar.badge.checkmark", tint: PulseTheme.violet, date: $store.customTo)
                        }
                        HStack {
                            if store.customTo <= store.customFrom {
                                Label("结束时间需要晚于开始时间", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                Text(customRangeSummary)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("结束设为现在") { store.customTo = Date() }
                            Button("应用时间范围") { store.applyCustomRange() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(16)
                .glassPanel()

                TelemetryChart(
                    title: "CPU / GPU / ANE", subtitle: "查看处理器负载变化与相关性", icon: "chart.xyaxis.line", samples: store.samples,
                    series: [
                        .init(name: "CPU", color: .cyan, value: { $0.cpuUsage }),
                        .init(name: "GPU", color: .purple, value: { $0.gpuUsage }),
                        .init(name: "ANE", color: .pink, value: { $0.aneUsage })
                    ], suffix: "%", timeDomain: store.chartWindow
                )
                HStack(alignment: .top, spacing: 16) {
                    TelemetryChart(
                        title: "内存带宽", subtitle: "DRAM 读取与写入历史", icon: "memorychip", samples: store.samples,
                        series: [
                            .init(name: "读取", color: .orange, value: { $0.memoryReadGBps }),
                            .init(name: "写入", color: .red, value: { $0.memoryWriteGBps })
                        ], suffix: " GB/s", timeDomain: store.chartWindow
                    )
                    TelemetryChart(
                        title: "网络带宽", subtitle: "所有活跃网络接口的吞吐历史", icon: "network", samples: store.samples,
                        series: [
                            .init(name: "下载", color: .blue, value: { $0.networkDownBytesPerSecond / 1_000_000 }),
                            .init(name: "上传", color: .mint, value: { $0.networkUpBytesPerSecond / 1_000_000 })
                        ], suffix: " MB/s", timeDomain: store.chartWindow
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    TelemetryChart(
                        title: "磁盘吞吐", subtitle: "内部存储读取与写入历史", icon: "internaldrive", samples: store.samples,
                        series: [
                            .init(name: "读取", color: .green, value: { $0.diskReadBytesPerSecond / 1_000_000 }),
                            .init(name: "写入", color: .teal, value: { $0.diskWriteBytesPerSecond / 1_000_000 })
                        ], suffix: " MB/s", timeDomain: store.chartWindow
                    )
                    TelemetryChart(
                        title: "系统功耗", subtitle: "整机与 CPU、GPU、ANE 分项历史", icon: "bolt", samples: store.samples,
                        series: [
                            .init(name: "整机", color: .yellow, value: { $0.systemPowerWatts }),
                            .init(name: "CPU", color: .cyan, value: { $0.cpuPowerWatts }),
                            .init(name: "GPU", color: .purple, value: { $0.gpuPowerWatts }),
                            .init(name: "ANE", color: .pink, value: { $0.anePowerWatts })
                        ], suffix: " W", timeDomain: store.chartWindow
                    )
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .background(AppBackground())
    }

    private var customRangeSummary: String {
        let interval = max(0, store.customTo.timeIntervalSince(store.customFrom))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return "跨度 \(formatter.string(from: interval) ?? "—")"
    }
}

private struct DateTimeField: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var date: Date
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(dateLabel)
                        Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                            .font(.body.monospacedDigit().weight(.medium))
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(PulseTheme.stroke) }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            editor
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择\(title)时间").font(.headline)
                Spacer()
                Button("完成") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            HStack(alignment: .top, spacing: 18) {
                DatePicker("日期", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: 180, alignment: .center)

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    Text("时间").font(.subheadline.weight(.medium))

                    HStack(spacing: 8) {
                        timeMenu(unit: "时", selection: hour, values: 0..<24)

                        Text(":").foregroundStyle(.secondary)

                        timeMenu(unit: "分", selection: minute, values: 0..<60)
                    }

                    Divider()

                    Text("快速调整").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        adjustmentButton("−1 小时", seconds: -3_600)
                        adjustmentButton("+1 小时", seconds: 3_600)
                        adjustmentButton("−15 分", seconds: -900)
                        adjustmentButton("+15 分", seconds: 900)
                    }
                }
                .frame(width: 190)
            }
        }
        .padding(18)
        .frame(width: 430)
    }

    private var dateLabel: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private var hour: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.hour, from: date) },
            set: { update(hour: $0, minute: Calendar.current.component(.minute, from: date)) }
        )
    }

    private var minute: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.minute, from: date) },
            set: { update(hour: Calendar.current.component(.hour, from: date), minute: $0) }
        )
    }

    private func update(hour: Int, minute: Int) {
        if let value = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date) {
            date = value
        }
    }

    private func adjustmentButton(_ label: String, seconds: TimeInterval) -> some View {
        Button(label) { date = date.addingTimeInterval(seconds) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
    }

    private func timeMenu(unit: String, selection: Binding<Int>, values: Range<Int>) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button(String(format: "%02d %@", value, unit)) {
                    selection.wrappedValue = value
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(String(format: "%02d %@", selection.wrappedValue, unit))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(width: 82, height: 30)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PulseTheme.stroke) }
        }
        .menuStyle(.borderlessButton)
    }
}
