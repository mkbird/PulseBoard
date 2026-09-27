import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var samples: [MetricSample] = []
    @Published private(set) var latest: MetricSample?
    @Published var selectedRange: HistoryRange = .fifteenMinutes {
        didSet { reloadHistory() }
    }
    @Published var customFrom: Date
    @Published var customTo: Date
    @Published var samplingInterval: TimeInterval = 1 {
        didSet { restartTimer() }
    }
    @Published var retentionDays = 30
    @Published private(set) var enhancedMetricsAvailable = false
    @Published private(set) var errorMessage: String?

    private let sampler = SystemSampler()
    private let history: HistoryStore?
    private var samplingTask: Task<Void, Never>?
    private var lastPrune = Date.distantPast
    private var appliedCustomFrom: Date
    private var appliedCustomTo: Date

    init() {
        let now = Date()
        customFrom = now.addingTimeInterval(-3_600)
        customTo = now
        appliedCustomFrom = now.addingTimeInterval(-3_600)
        appliedCustomTo = now
        do {
            history = try HistoryStore()
        } catch {
            history = nil
            errorMessage = error.localizedDescription
        }
        // Prime cumulative counters before persisting. The first CPU, disk,
        // network and IOReport deltas do not have a valid baseline yet.
        _ = sampler.sample()
        restartTimer()
    }

    var chartWindow: ClosedRange<Date> {
        if selectedRange == .custom {
            let end = max(appliedCustomFrom.addingTimeInterval(1), appliedCustomTo)
            return appliedCustomFrom...end
        }
        let end = latest?.timestamp ?? Date()
        return end.addingTimeInterval(-(selectedRange.duration ?? 900))...end
    }

    var activeWindow: (from: Date, to: Date) {
        let window = chartWindow
        return (window.lowerBound, window.upperBound)
    }

    func capture() {
        let sample = sampler.sample()
        latest = sample
        enhancedMetricsAvailable = sampler.enhancedMetricsAvailable
        do {
            try history?.append(sample)
            if Date().timeIntervalSince(lastPrune) > 3_600 {
                try history?.prune(olderThan: Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast)
                lastPrune = Date()
            }
            reloadHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyCustomRange() {
        if customTo <= customFrom {
            customTo = customFrom.addingTimeInterval(60)
        }
        appliedCustomFrom = customFrom
        appliedCustomTo = customTo
        if selectedRange == .custom { reloadHistory() }
        else { selectedRange = .custom }
    }

    func selectHistoryRange(_ range: HistoryRange) {
        if range == .custom, selectedRange != .custom {
            let end = Date()
            customTo = end
            customFrom = end.addingTimeInterval(-3_600)
            appliedCustomFrom = customFrom
            appliedCustomTo = customTo
        }
        selectedRange = range
    }

    func resumeLiveRange() {
        if selectedRange == .custom { selectedRange = .fifteenMinutes }
    }

    func reloadHistory() {
        guard let history else { return }
        let window = activeWindow
        do { samples = try history.fetch(from: window.from, to: window.to) }
        catch { errorMessage = error.localizedDescription }
    }

    func exportCurrentRange() {
        guard let history else { return }
        let window = activeWindow
        do {
            let raw = try history.fetchRaw(from: window.from, to: window.to)
            try CSVExporter.export(samples: raw)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func restartTimer() {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.samplingInterval else { return }
                try? await Task.sleep(for: .seconds(max(0.5, interval)))
                guard !Task.isCancelled else { return }
                self?.capture()
            }
        }
    }
}
