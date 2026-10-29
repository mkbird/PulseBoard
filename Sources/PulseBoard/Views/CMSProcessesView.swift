import SwiftUI
import CliptoPulseCore

struct CMSProcessesView: View {
    let session: CMSSessionSnapshot
    let exportHistory: () -> Void

    @State private var sortMetric: SortMetric = .cpu
    @State private var ascending = false
    @State private var showExited = true
    @State private var tableViewportWidth: CGFloat = 0

    private enum SortMetric: String, CaseIterable, Identifiable {
        case cpu, memory
        var id: Self { self }
        var title: String { L10n.text(self == .cpu ? "cms.sort_cpu" : "cms.sort_memory") }
    }

    private let columnSpacing: CGFloat = 10

    private struct TableColumns {
        let name: CGFloat
        let value: CGFloat
        let pid: CGFloat = 60
        let state: CGFloat = 84
        let spacing: CGFloat = 10
        // Keep the last value clear of macOS's always-visible vertical scroller.
        let scrollerInset: CGFloat = 16

        init(viewportWidth: CGFloat) {
            let extra = max(0, viewportWidth - 982)
            name = 190 + extra * 0.28
            value = 92 + extra * 0.72 / 6
        }

        var identity: CGFloat { name + pid + state + spacing * 2 }
        var metricGroup: CGFloat { value * 3 + spacing * 2 }
        var content: CGFloat { identity + metricGroup * 2 + spacing * 2 }
        var table: CGFloat { content + scrollerInset }
    }

    private struct TableViewportWidthKey: PreferenceKey {
        static var defaultValue: CGFloat { 0 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    cpuSummary
                    memorySummary
                }
                VStack(spacing: 12) {
                    cpuSummary
                    memorySummary
                }
            }

            controls

            if sortedProcesses.isEmpty {
                Label(emptyMessage, systemImage: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            } else {
                processTable
            }

            Text(L10n.text("cms.statistics_note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .glassPanel(tint: PulseTheme.cyan)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label(L10n.text("cms.title"), systemImage: "square.stack.3d.up")
                    .font(.headline)
                Text(L10n.format("cms.session_started", session.startedAt.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)
                )))
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(L10n.text("cms.session_scope"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                StatusPill(text: statusText, color: statusColor)
                Text(L10n.format("cms.process_count", session.runningCount, session.processes.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cpuSummary: some View {
        summary(
            title: "CPU", icon: "cpu", detail: L10n.text("cms.cpu_units"),
            statistics: session.cpu, tint: PulseTheme.cyan, format: percent
        )
    }

    private var memorySummary: some View {
        summary(
            title: L10n.text("metric.memory"), icon: "memorychip", detail: L10n.text("cms.memory_units"),
            statistics: session.memory, tint: .orange, format: memory
        )
    }

    private func summary(
        title: String, icon: String, detail: String, statistics: CMSMetricStatistics,
        tint: Color, format: (Double?) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.format("cms.total_metric", title), systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                summaryValue("cms.current", value: format(session.isSuspended ? nil : statistics.current), prominent: true)
                summaryValue("cms.average", value: format(statistics.average))
                summaryValue("cms.peak", value: format(statistics.peak))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("cms.total_scope"))
                Text(L10n.format("cms.valid_duration", duration(statistics.validDuration)))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 330, maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.12))
        }
    }

    private func summaryValue(_ key: String, value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(key))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: prominent ? 25 : 20, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker(L10n.text("cms.sort"), selection: $sortMetric) {
                ForEach(SortMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Button {
                ascending.toggle()
            } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.bordered)
            .help(L10n.text(ascending ? "cms.sort_ascending" : "cms.sort_descending"))
            .accessibilityLabel(L10n.text(ascending ? "cms.sort_ascending" : "cms.sort_descending"))
            Spacer(minLength: 12)
            Button(action: exportHistory) {
                Label(L10n.text("cms.export_history"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .help(L10n.text("cms.export_history_help"))
            Toggle(L10n.text("cms.show_exited"), isOn: $showExited)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }

    private var processTable: some View {
        let columns = TableColumns(viewportWidth: tableViewportWidth)
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                tableHeader(columns)
                Divider().overlay(PulseTheme.stroke)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sortedProcesses) { process in
                            processRow(process, columns: columns)
                            Divider().opacity(0.35)
                        }
                    }
                    .frame(width: columns.content, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(330, CGFloat(sortedProcesses.count) * 48))
            }
            .frame(width: columns.table, alignment: .leading)
            .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TableViewportWidthKey.self, value: geometry.size.width)
            }
        }
        .onPreferenceChange(TableViewportWidthKey.self) { width in
            if abs(tableViewportWidth - width) > 0.5 { tableViewportWidth = width }
        }
    }

    private func tableHeader(_ columns: TableColumns) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: columnSpacing) {
                Text(L10n.text("cms.process_name")).frame(width: columns.name, alignment: .leading)
                Text("PID").frame(width: columns.pid, alignment: .trailing)
                Text(L10n.text("cms.state")).frame(width: columns.state, alignment: .leading)
                Text("CPU").foregroundStyle(PulseTheme.cyan).frame(width: columns.metricGroup)
                Text(L10n.text("metric.memory")).foregroundStyle(.orange).frame(width: columns.metricGroup)
            }
            HStack(spacing: columnSpacing) {
                Color.clear.frame(width: columns.identity, height: 1)
                statisticHeaders(columns)
                statisticHeaders(columns)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
    }

    private func statisticHeaders(_ columns: TableColumns) -> some View {
        HStack(spacing: columnSpacing) {
            Text(L10n.text("cms.current")).frame(width: columns.value, alignment: .trailing)
            Text(L10n.text("cms.average")).frame(width: columns.value, alignment: .trailing)
            Text(L10n.text("cms.peak")).frame(width: columns.value, alignment: .trailing)
        }
    }

    private func processRow(_ process: CMSProcessRow, columns: TableColumns) -> some View {
        HStack(spacing: columnSpacing) {
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: columns.name, alignment: .leading)
                .help(process.name)
            Text(String(process.id.pid))
                .foregroundStyle(.secondary)
                .frame(width: columns.pid, alignment: .trailing)
            Text(processState(process.state))
                .font(.caption)
                .foregroundStyle(processStateColor(process.state))
                .frame(width: columns.state, alignment: .leading)
            metricValues(process.cpu, columns: columns, format: percent)
            metricValues(process.memory, columns: columns, format: memory)
        }
        .font(.callout.monospacedDigit())
        .frame(height: 47)
        .help(L10n.format(
            "cms.process_duration", duration(process.cpu.validDuration), duration(process.memory.validDuration)
        ))
    }

    private func metricValues(_ statistics: CMSMetricStatistics, columns: TableColumns, format: (Double?) -> String) -> some View {
        HStack(spacing: columnSpacing) {
            Text(format(session.isSuspended ? nil : statistics.current))
                .frame(width: columns.value, alignment: .trailing)
            Text(format(statistics.average))
                .foregroundStyle(.secondary)
                .frame(width: columns.value, alignment: .trailing)
            Text(format(statistics.peak))
                .foregroundStyle(.secondary)
                .frame(width: columns.value, alignment: .trailing)
        }
    }

    private var sortedProcesses: [CMSProcessRow] {
        session.processes.filter { showExited || !isExited($0.state) }.sorted { lhs, rhs in
            let left = sortMetric == .cpu ? lhs.cpu.current : lhs.memory.current
            let right = sortMetric == .cpu ? rhs.cpu.current : rhs.memory.current
            switch (left, right) {
            case let (.some(left), .some(right)) where left != right:
                return ascending ? left < right : left > right
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                if lhs.id.pid != rhs.id.pid { return lhs.id.pid < rhs.id.pid }
                return lhs.id.startTime < rhs.id.startTime
            }
        }
    }

    private var statusText: String {
        if session.isSuspended { return L10n.text("cms.suspended") }
        if !session.isComplete { return L10n.text("cms.read_failed") }
        if session.runningCount == 0 { return L10n.text("cms.no_running") }
        if session.cpu.current == nil && session.processes.contains(where: { $0.state == .running }) {
            return L10n.text("cms.warming_up")
        }
        return L10n.text("cms.tracking")
    }

    private var statusColor: Color {
        if session.isSuspended { return .secondary }
        if !session.isComplete { return .orange }
        return session.runningCount > 0 ? .green : .secondary
    }

    private var emptyMessage: String {
        if session.isSuspended { return L10n.text("cms.suspended_detail") }
        if !session.isComplete { return L10n.text("cms.unavailable_detail") }
        if !session.processes.isEmpty { return L10n.text("cms.exited_hidden") }
        return L10n.text("cms.empty")
    }

    private func processState(_ state: CMSProcessState) -> String {
        switch state {
        case .running: L10n.text("cms.state_running")
        case .exited: L10n.text("cms.state_exited")
        case .unavailable: L10n.text("cms.state_unavailable")
        }
    }

    private func processStateColor(_ state: CMSProcessState) -> Color {
        switch state {
        case .running: .green
        case .exited: .secondary
        case .unavailable: .orange
        }
    }

    private func isExited(_ state: CMSProcessState) -> Bool {
        if case .exited = state { return true }
        return false
    }

    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", locale: L10n.locale, value)
    }

    private func memory(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        if value == 0 { return "0 B" }
        return MetricFormat.bytes(value)
    }

    private func duration(_ value: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        return formatter.string(from: max(0, value)) ?? "—"
    }
}
