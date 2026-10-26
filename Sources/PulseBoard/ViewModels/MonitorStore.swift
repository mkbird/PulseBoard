import AppKit
import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    static let maximumRetentionDays = 120
    private static let retentionDefaultsKey = "PulseBoard.retentionDays"
    private static let webPortDefaultsKey = "CliptoPulse.webPort"
    private static let autoOpenWebDefaultsKey = "CliptoPulse.autoOpenWebOnLaunch"
    private static let preventSleepDefaultsKey = "CliptoPulse.preventSleep"

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
    /// Keeps the Mac awake (idle system sleep) and opts out of App Nap so overnight runs are sampled at 1 Hz.
    @Published var preventSleep: Bool = true {
        didSet {
            UserDefaults.standard.set(preventSleep, forKey: Self.preventSleepDefaultsKey)
            applySleepPolicy()
        }
    }
    @Published private(set) var isWiping = false
    /// 评测人（手动填写，晨报 / CSV 使用）
    @Published var reporterName: String = ReportProfile.reporter {
        didSet { if ReportProfile.reporter != reporterName { ReportProfile.reporter = reporterName } }
    }
    /// 局域网 IP（手动填写，用于晨报「查看详情」链接和复制共享网址）
    @Published var reportLANHost: String = ReportProfile.lanHost {
        didSet { if ReportProfile.lanHost != reportLANHost { ReportProfile.lanHost = reportLANHost } }
    }
    @Published private(set) var webServerPort: Int = 8766
    @Published private(set) var webServerRunning = false
    @Published private(set) var menuActionFeedback: String?
    @Published private(set) var enhancedMetricsAvailable = false
    @Published private(set) var errorMessage: String?

    private let sampler = SystemSampler()
    private let cmsSampler = CMSProcessSampler()
    private var cmsStatistics: CMSProcessSession
    private var cmsSessionID = UUID().uuidString
    private var sleepActivity: NSObjectProtocol?
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
        if UserDefaults.standard.object(forKey: Self.preventSleepDefaultsKey) != nil {
            preventSleep = UserDefaults.standard.bool(forKey: Self.preventSleepDefaultsKey)
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
        if !isRunningTests {
            applySleepPolicy()
        }
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
        if let manual = ReportProfile.detailURL(port: webServerPort) { return manual }
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

    /// Builds the latest-batch report (same as the web console's default "auto" slice).
    private func buildLatestReport() async throws -> (analysis: DAGSCAnalysisResponse, markdown: String) {
        let port = webServerPort
        let historyRef = history
        let dbURL = (try? await historyRef.resolvedDatabaseURL())
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PulseBoard/history.sqlite")
        let env = SystemEnvironmentService.current(webPort: port, historyDBURL: dbURL)
        // Heavy SQLite work happens off the main actor so sampling keeps its 1 Hz cadence.
        var result = try await Task.detached(priority: .userInitiated) {
            try DAGSCAnalyzer.analyze(options: DAGSCQueryOptions(sliceMode: "auto"), environment: env)
        }.value
        result.alignedHardware = try? await historyRef.fetchAlignedReport(
            activeIntervalsMs: result.activeIntervalsMs,
            fallbackStartMs: result.sliceStartMs,
            fallbackEndMs: result.sliceEndMs
        )
        return (result, MarkdownReportGenerator.generate(analysis: result))
    }

    func copyLatestDailyReportMarkdown() {
        Task {
            do {
                let report = try await buildLatestReport()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.markdown, forType: .string)
                showMenuFeedback("✓ 已复制 Markdown 晨报（可直接粘贴至飞书/Notion）")
            } catch {
                showMenuFeedback("晨报生成失败：\(error.localizedDescription)")
            }
        }
    }

    /// Copies the single-column CSV values (row 1 = version) for pasting into the tracking sheet.
    func copyLatestReportCSVColumn() {
        Task {
            do {
                let report = try await buildLatestReport()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ReportCSVGenerator.columnText(analysis: report.analysis), forType: .string)
                showMenuFeedback("✓ 已复制 CSV 列（第 1 行版本号），可直接粘贴到表格")
            } catch {
                showMenuFeedback("CSV 生成失败：\(error.localizedDescription)")
            }
        }
    }

    func copyLatestDailyReportImage() {
        Task {
            do {
                let report = try await buildLatestReport()
                let png = try ReportImageRenderer.renderPNG(markdown: report.markdown)
                ReportImageRenderer.copyToPasteboard(png: png)
                showMenuFeedback("✓ 已复制晨报图片，可直接粘贴到飞书/微信群")
            } catch {
                showMenuFeedback("晨报图片生成失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sleep / App Nap

    private func applySleepPolicy() {
        if preventSleep && !isTerminating {
            guard sleepActivity == nil else { return }
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "CliptoPulse 正在持续采集 Clipto 夜间运行数据"
            )
        } else if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: - Wipe all records

    /// Asks for confirmation, then deletes every CliptoPulse record except exported reports.
    func confirmAndWipeAllRecords() {
        guard !isWiping, !isTerminating else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清空 CliptoPulse 全部记录？"
        alert.informativeText = """
        将删除：
        • 本机全部硬件 / Clipto / CMS 采样历史（history.sqlite）
        • 分析时产生的临时快照文件
        • 清空时刻之前的 Clipto 测试批次将不再出现在批次列表和晨报中

        不会删除：已导出的晨报（.md / .png / .csv）、软件设置，以及 Clipto 自己的数据库（Clipto 本身不受任何影响）。

        此操作不可撤销。建议在开始新一轮夜跑之前执行。
        """
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await wipeAllRecords() }
    }

    func wipeAllRecords() async {
        guard !isWiping, !isTerminating else { return }
        isWiping = true
        defer { isWiping = false }

        // Stop sampling so no frame from the old CMS session lands in the fresh database.
        let running = samplingTask
        running?.cancel()
        samplingTask = nil
        historyReloadTask?.cancel()
        await running?.value

        do {
            try await history.wipeAll()
            RecordsEpoch.markNow()
            Self.removeTemporarySnapshots()
            let now = Date()
            cmsStatistics = CMSProcessSession(startedAt: now)
            cmsSession = cmsStatistics.snapshot
            cmsSessionID = UUID().uuidString
            cmsSequence = 0
            cmsSegment = 0
            samples = []
            lastPrune = .distantPast
            showMenuFeedback("✓ 已清空全部记录，从现在开始重新采集")
        } catch {
            errorMessage = error.localizedDescription
            showMenuFeedback("清空失败：\(error.localizedDescription)")
        }

        _ = sampler.sample() // re-prime counters after the pause
        restartTimer()
    }

    private static func removeTemporarySnapshots() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("cliptopulse_") {
            try? FileManager.default.removeItem(at: item)
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
        applySleepPolicy()
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
