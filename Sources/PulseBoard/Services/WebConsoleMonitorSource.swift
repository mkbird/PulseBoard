import Foundation
import CliptoPulseCore

/// Platform-neutral state consumed by the web console.
///
/// A platform host owns sampling and lifecycle concerns, then exposes only this
/// snapshot to the HTTP router. This keeps the router independent from the
/// macOS SwiftUI store and gives a future Windows host the same integration
/// boundary.
struct WebConsoleLiveSnapshot: Sendable {
    let latest: MetricSample?
    let cmsSession: CMSSessionSnapshot
    let samplingInterval: TimeInterval
    let retentionDays: Int
    let enhancedMetricsAvailable: Bool
}

@MainActor
protocol WebConsoleMonitorSource: AnyObject {
    var webConsolePort: Int { get }

    func webConsoleLiveSnapshot() -> WebConsoleLiveSnapshot
    func updateReportProfile(reporter: String?, lanHost: String?)
}

extension MonitorStore: WebConsoleMonitorSource {
    var webConsolePort: Int { webServerPort }

    func webConsoleLiveSnapshot() -> WebConsoleLiveSnapshot {
        WebConsoleLiveSnapshot(
            latest: latest,
            cmsSession: cmsSession,
            samplingInterval: samplingInterval,
            retentionDays: retentionDays,
            enhancedMetricsAvailable: enhancedMetricsAvailable
        )
    }

    func updateReportProfile(reporter: String?, lanHost: String?) {
        if let reporter { reporterName = reporter }
        if let lanHost { reportLANHost = lanHost }
    }
}
