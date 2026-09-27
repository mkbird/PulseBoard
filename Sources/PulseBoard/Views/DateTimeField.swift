import SwiftUI

struct DateTimeField: View {
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
                Text(L10n.format("datetime.choose", title)).font(.headline)
                Spacer()
                Button(L10n.text("common.done")) { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            HStack(alignment: .top, spacing: 18) {
                DatePicker(L10n.text("datetime.date"), selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(width: 180, alignment: .center)

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("datetime.time")).font(.subheadline.weight(.medium))

                    HStack(spacing: 8) {
                        timeMenu(unit: L10n.text("datetime.hour_unit"), selection: hour, values: 0..<24)

                        Text(":").foregroundStyle(.secondary)

                        timeMenu(unit: L10n.text("datetime.minute_unit"), selection: minute, values: 0..<60)
                    }

                    Divider()

                    Text(L10n.text("datetime.quick_adjust")).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        adjustmentButton(L10n.text("datetime.minus_hour"), seconds: -3_600)
                        adjustmentButton(L10n.text("datetime.plus_hour"), seconds: 3_600)
                        adjustmentButton(L10n.text("datetime.minus_minutes"), seconds: -900)
                        adjustmentButton(L10n.text("datetime.plus_minutes"), seconds: 900)
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
