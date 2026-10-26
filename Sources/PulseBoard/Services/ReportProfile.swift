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

    /// 局域网 IP / 主机名（手动填写，不自动探测）
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

    /// "http://10.0.0.5:8766" or nil when no LAN IP has been filled in.
    static func detailURL(port: Int) -> String? {
        let host = lanHost
        return host.isEmpty ? nil : "http://\(host):\(port)"
    }
}
