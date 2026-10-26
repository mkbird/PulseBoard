import AppKit
import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    static let maximumRetentionDays = 120
    private static let retentionDefaultsKey = "PulseBoard.retentionDays"
    private static let webPortDefaultsKey = "CliptoPulse.webPort"
    private static let autoOpenWebDefaultsKey = "CliptoPulse.autoOpenWebOnLaunch"

    @Published private(set) var samples: [MetricSample] = []
    @Published private(set) var latest: MetricSample?
    @Published private(set) var cmsSession: CMSSessionSnapshot
    @Published var selectedRange: HistoryRange = .fifteenMinutes {
        didSet { reloadHistory() }
    }
    @Published var customFrom: Date
    @Published var customTo: Date
    @Published var samplingInterval: TimeInterval = 1 {
        didSet { restartTimer() }
    }
    @Published var retentionDays = maximumRetentionDays {
        didSet {
            let clamped = min(max(1, retentionDays), Self.maximumRetentionDays)
            if retentionDays != clamped {
                retentionDays = clamped
            } else {
                UserDefaults.standard.set(clamped, forKey: Self.retentionDefaultsKey)
            }
        }
    }
    @Published var autoOpenWebOnLaunch: Bool = true {
        didSet {
            UserDefaults.standard.set(autoOpenWebOnLaunch, forKey: Self.autoOpenWebDefaultsKey)
        }
    }
    @Published private(set) var webServerPort: Int = 8766
    @Published private(set) var webServerRunning = false
    @Published private(set) var menuActionFeedback: String?
    @Published private(set) var enhancedMetricsAvailable = false
    @Published private(set) var errorMessage: String?

    private let sampler = SystemSampler()
    private let cmsSampler = CMSProcessSampler()
    private var cmsStatistics: CMSProcessSession
    private let cmsSessionID = UUID().uuidString
    private var cmsSequence: Int64 = 0
    private var cmsSegment: Int64 = 0
    private var workspaceSubscriptions = Set<AnyCancellable>()
    private var isSleeping = false
    private var isTerminating = false
    let history = HistoryRepository()
    private var webServer: LocalWebServer?
    private var samplingTask: Task<Void, Never>?
    private var historyReloadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var feedbackClearTask: Task<Void, Never>?
    private var historyRequest = 0
    private var lastPrune = Date.distantPast
    private var appliedCustomFrom: Date
    private var appliedCustomTo: Date

    init(enableWebServer: Bool = true) {
        let now = Date()
        let cmsStatistics = CMSProcessSession(startedAt: now)
        self.cmsStatistics = cmsStatistics
        cmsSession = cmsStatistics.snapshot
        customFrom = now.addingTimeInterval(-3_600)
        customTo = now
        appliedCustomFrom = now.addingTimeInterval(-3_600)
        appliedCustomTo = now
        let savedRetention = UserDefaults.standard.integer(forKey: Self.retentionDefaultsKey)
        if savedRetention > 0 {
            retentionDays = min(savedRetention, Self.maximumRetentionDays)
        }
        if UserDefaults.standard.object(forKey: Self.autoOpenWebDefaultsKey) != nil {
            autoOpenWebOnLaunch = UserDefaults.standard.bool(forKey: Self.autoOpenWebDefaultsKey)
        }
        let savedPort = UserDefaults.standard.integer(forKey: Self.webPortDefaultsKey)
        if savedPort >= 1_024 && savedPort <= 65_535 {
            webServerPort = savedPort
        }
        let cliArgs = CommandLine.arguments
        for idx in cliArgs.indices {
            if cliArgs[idx] == "--port", idx + 1 < cliArgs.count, let p = Int(cliArgs[idx + 1]), (1_024...65_535).contains(p) {
                webServerPort = p
            } else if cliArgs[idx].hasPrefix("--port="), let p = Int(cliArgs[idx].dropFirst("--port=".count)), (1_024...65_535).contains(p) {
                webServerPort = p
            }
        }
        // Prime cumulative counters before persisting. The first CPU, disk,
        // network and IOReport deltas do not have a valid baseline yet.
        _ = sampler.sample()
        observeSleepAndWake()
        restartTimer()

        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if enableWebServer && !isRunningTests {
            startWebConsoleServer()
            let args = CommandLine.arguments
            let suppressBrowser = args.contains("--no-browser") || args.contains("--background")
            if autoOpenWebOnLaunch && !suppressBrowser {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    self?.openWebConsole()
                }
            }
        }
    }

    var localWebURLString: String {
        "http://127.0.0.1:\(webServerPort)"
    }

    var primaryLANURLString: String {
        let ips = SystemEnvironmentService.lanIPv4Addresses()
        if let first = ips.first {
            return "http://\(first):\(webServerPort)"
        }
        return localWebURLString
    }

    func startWebConsoleServer(preferredPort: Int? = nil) {
        webServer?.stop()
        let targetPort = preferredPort ?? webServerPort
        let historyRef = self.history
        let server = LocalWebServer { [weak self] request in
            guard let self else {
                return .jsonError(503, "服务正在关闭")
            }
            return await WebConsoleRouter.handle(request: request, monitor: self, history: historyRef)
        }
        do {
            let bound = try server.start(preferredPort: targetPort)
            webServer = server
            webServerPort = bound
            webServerRunning = true
            UserDefaults.standard.set(bound, forKey: Self.webPortDefaultsKey)
        } catch {
            webServerRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func openWebConsole(hash: String = "") {
        let suffix = hash.isEmpty ? "" : (hash.hasPrefix("#") ? hash : "#\(hash)")
        guard let url = URL(string: "\(localWebURLString)/\(suffix)") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyLANAddressToPasteboard() {
        let urlStr = primaryLANURLString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
        showMenuFeedback("✓ 已复制访问地址：\(urlStr)")
    }

    func copyLatestDailyReportMarkdown() {
        let port = webServerPort
        let historyRef = history
        Task {
            do {
                let dbURL = (try? await historyRef.resolvedDatabaseURL())
                    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("PulseBoard/history.sqlite")
                let env = SystemEnvironmentService.current(webPort: port, historyDBURL: dbURL)
                var result = try DAGSCAnalyzer.analyze(options: DAGSCQueryOptions(sliceMode: "auto"), environment: env)
                result.alignedHardware = try? await historyRef.fetchAlignedReport(
                    activeIntervalsMs: result.activeIntervalsMs,
                    fallbackStartMs: result.sliceStartMs,
                    fallbackEndMs: result.sliceEndMs
                )
                let md = MarkdownReportGenerator.generate(analysis: result)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(md, forType: .string)
                    self.showMenuFeedback("✓ 已复制 Markdown 日报（可直接粘贴至飞书/Notion）")
                }
            } catch {
                await MainActor.run {
                    self.showMenuFeedback("日报生成失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func showMenuFeedback(_ text: String) {
        menuActionFeedback = text
        feedbackClearTask?.cancel()
        feedbackClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.menuActionFeedback = nil
        }
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

    func capture() async {
        guard let frame = await captureCMS() else { return }
        let sample: MetricSample?
        if !Task.isCancelled, !isSleeping, !isTerminating {
            sample = sampler.sample()
            latest = sample
            enhancedMetricsAvailable = sampler.enhancedMetricsAvailable
        } else {
            sample = nil
        }
        await persist(system: sample, cms: frame)
        guard !Task.isCancelled, !isSleeping, !isTerminating else { return }
        reloadHistory()
    }

    private func persist(system: MetricSample?, cms: CMSHistoryFrame) async {
        do {
            try await history.append(system: system, cms: cms)
            if Date().timeIntervalSince(lastPrune) > 3_600 {
                let effectiveRetentionDays = min(max(1, retentionDays), Self.maximumRetentionDays)
                if try await history.prune(olderThan: Calendar.current.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) ?? .distantPast) {
                    lastPrune = Date()
                }
            }
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
        guard !isTerminating else { return }
        historyReloadTask?.cancel()
        historyRequest += 1
        let request = historyRequest
        let window = activeWindow
        historyReloadTask = Task { [weak self, history] in
            guard !Task.isCancelled else { return }
            do {
                let values = try await history.fetch(from: window.from, to: window.to)
                guard let self, !Task.isCancelled, !isTerminating, request == historyRequest else { return }
                samples = values
            } catch {
                guard let self, !Task.isCancelled, request == historyRequest else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportCurrentRange() {
        guard exportTask == nil, !isTerminating else { return }
        let window = activeWindow
        exportTask = Task { [weak self, history] in
            defer { self?.exportTask = nil }
            do {
                let raw = try await history.fetchRaw(from: window.from, to: window.to)
                guard let self, !Task.isCancelled, !isTerminating else { return }
                try CSVExporter.export(samples: raw)
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func exportCMSCurrentRange() {
        guard exportTask == nil, !isTerminating else { return }
        let window = activeWindow
        guard let destination = CMSCSVExporter.chooseDestination() else { return }
        exportTask = Task { [weak self, history] in
            defer { self?.exportTask = nil }
            do {
                try await history.exportCMS(from: window.from, to: window.to, destination: destination)
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func prepareForTermination() async {
        isTerminating = true
        webServer?.stop()
        webServerRunning = false
        samplingTask?.cancel()
        historyReloadTask?.cancel()
        exportTask?.cancel()
        feedbackClearTask?.cancel()
        await samplingTask?.value
        await exportTask?.value
        await history.flush()
    }

    func dismissError() {
        errorMessage = nil
    }

    private func restartTimer() {
        let previousTask = samplingTask
        previousTask?.cancel()
        guard !isSleeping, !isTerminating else { return }
        samplingTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            if let frame = await self?.captureCMS() {
                await self?.persist(system: nil, cms: frame)
                if !Task.isCancelled { self?.reloadHistory() }
            }
            while !Task.isCancelled {
                guard let interval = self?.samplingInterval else { return }
                try? await Task.sleep(for: .seconds(max(0.5, interval)))
                guard !Task.isCancelled else { return }
                await self?.capture()
            }
        }
    }

    private func captureCMS() async -> CMSHistoryFrame? {
        let raw = await cmsSampler.sample()
        guard !Task.isCancelled, !isSleeping, !isTerminating else { return nil }
        let maximumGap = max(30, samplingInterval * 3)
        cmsStatistics.consume(raw, maximumGap: maximumGap)
        cmsSession = cmsStatistics.snapshot
        cmsSequence += 1
        return CMSHistoryFrame.capture(
            sessionID: cmsSessionID, sequence: cmsSequence, segment: cmsSegment,
            maximumGap: maximumGap, raw: raw, statistics: cmsSession
        )
    }

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    isSleeping = true
                    samplingTask?.cancel()
                    cmsStatistics.suspend()
                    cmsSegment += 1
                    cmsSession = cmsStatistics.snapshot
                }
            }
            .store(in: &workspaceSubscriptions)
        center.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    isSleeping = false
                    _ = sampler.sample()
                    restartTimer()
                }
            }
            .store(in: &workspaceSubscriptions)
    }
}
