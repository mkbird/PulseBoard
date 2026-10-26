import Foundation

/// Manually entered report metadata, persisted in UserDefaults and shared by the menu bar,
/// the web console (`/api/report/profile`) and the CLI, so every export path prints the same values.
enum ReportProfile {
    private static let reporterKey = "CliptoPulse.reporter"
    private static let lanHostKey = "CliptoPulse.lanHost"

    /// 评测人
    static var reporter: String {
        get { UserDefaults.standard.string(forKey: reporterKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: reporterKey) }
    }

    /// 局域网 IP / 主机名（手动填写；留空则自动使用工作局域网 IP，见 `effectiveLANHost`）
    static var lanHost: String {
        get { UserDefaults.standard.string(forKey: lanHostKey) ?? "" }
        set { UserDefaults.standard.set(normalizeHost(newValue), forKey: lanHostKey) }
    }

    /// Accepts "10.0.0.5", "http://10.0.0.5:8766/" or "10.0.0.5:8766" and keeps just the host.
    static func normalizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        // Strip a trailing ":port" (IPv4 / hostname only).
        if let colon = s.lastIndex(of: ":"), s.filter({ $0 == ":" }).count == 1 {
            s = String(s[..<colon])
        }
        return s
    }

    /// The work LAN is the first detected `192.168.*` address (VPN / proxy TUN adapters such as
    /// `198.18.*` are ignored). Re-detected every time so DHCP changes are picked up.
    static func pickWorkLANHost(from addresses: [String]) -> String {
        addresses.first { $0.hasPrefix("192.168.") } ?? ""
    }

    static var autoLANHost: String {
        pickWorkLANHost(from: SystemEnvironmentService.lanIPv4Addresses())
    }

    /// Manual value wins; otherwise the auto-detected work LAN IP; empty if neither exists.
    static var effectiveLANHost: String {
        let manual = lanHost
        return manual.isEmpty ? autoLANHost : manual
    }

    /// "http://192.168.2.247:8766" or nil when no LAN IP is known.
    static func detailURL(port: Int) -> String? {
        let host = effectiveLANHost
        return host.isEmpty ? nil : "http://\(host):\(port)"
    }
}
