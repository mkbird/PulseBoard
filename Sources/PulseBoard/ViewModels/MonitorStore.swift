import AppKit
import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var samples: [MetricSample] = []
    @Published private(set) var latest: MetricSample?
    @Published var selectedRange: HistoryRange = .fifteenMinutes {
        didSet { reloadHistory() }
    }
    @Published var customFrom = Date().addingTimeInterval(-3_600)
    @Published var customTo = Date()
    @Published var samplingInterval: TimeInterval = 1 {
        didSet { restartTimer() }
    }
    @Published var retentionDays = 30
    @Published private(set) var enhancedMetricsAvailable = false
    @Published private(set) var helperStatus: PrivilegedHelperStatus = .notRegistered
    @Published private(set) var errorMessage: String?

    private let sampler = SystemSampler()
    private let helperManager = PrivilegedHelperManager()
    private let history: HistoryStore?
    private var samplingTask: Task<Void, Never>?
    private var lastPrune = Date.distantPast

    init() {
        do {
            history = try HistoryStore()
        } catch {
            history = nil
            errorMessage = error.localizedDescription
        }
        helperStatus = helperManager.status
        // Prime cumulative counters before persisting. The first CPU, disk,
        // network and IOReport deltas do not have a valid baseline yet.
        _ = sampler.sample()
        restartTimer()
    }

    var enhancedMetricsFile: URL { sampler.enhancedMetricsFile }

    var chartWindow: ClosedRange<Date> {
        if selectedRange == .custom {
            let end = max(customFrom.addingTimeInterval(1), customTo)
            return customFrom...end
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
        helperStatus = helperManager.status
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
        selectedRange = .custom
        reloadHistory()
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

    func copyEnhancedMetricsCommand() {
        let destination = enhancedMetricsFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let temporary = destination + ".tmp"
        let command = "while true; do sudo /usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power --show-extra-power-info -n 1 -i 1000 -b 1 -o '\(temporary)' && mv '\(temporary)' '\(destination)'; sleep 1; done"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func enableEnhancedMonitoring() {
        do { helperStatus = try helperManager.enable() }
        catch { errorMessage = "无法启用高级监控：\(error.localizedDescription)" }
    }

    func disableEnhancedMonitoring() {
        do { helperStatus = try helperManager.disable() }
        catch { errorMessage = "无法停用高级监控：\(error.localizedDescription)" }
    }

    func openHelperApprovalSettings() {
        helperManager.openApprovalSettings()
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
