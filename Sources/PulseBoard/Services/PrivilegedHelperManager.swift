import Foundation
import Security
import ServiceManagement

enum PrivilegedHelperStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var title: String {
        switch self {
        case .notRegistered: "未启用"
        case .enabled: "已启用"
        case .requiresApproval: "等待批准"
        case .notFound: "辅助进程不可用"
        }
    }
}

@MainActor
final class PrivilegedHelperManager {
    static let plistName = "com.madongpeng.PulseBoard.helper.plist"
    private static let label = "com.madongpeng.PulseBoard.helper"
    private static let legacyExecutable = "/Library/PrivilegedHelperTools/com.madongpeng.PulseBoard.helper"
    private static let legacyPlist = "/Library/LaunchDaemons/com.madongpeng.PulseBoard.helper.plist"
    private let service = SMAppService.daemon(plistName: plistName)

    var status: PrivilegedHelperStatus {
        if FileManager.default.fileExists(atPath: Self.legacyPlist),
           FileManager.default.fileExists(atPath: Self.legacyExecutable) {
            return .enabled
        }
        return switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func enable() throws -> PrivilegedHelperStatus {
        if usesAdHocSignature {
            try installDevelopmentHelper()
            return status
        }
        if service.status == .notRegistered {
            do {
                try service.register()
            } catch {
                if status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    return status
                }
                throw error
            }
        }
        let result = status
        if result == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return result
    }

    func disable() throws -> PrivilegedHelperStatus {
        if FileManager.default.fileExists(atPath: Self.legacyPlist) ||
            FileManager.default.fileExists(atPath: Self.legacyExecutable) {
            try uninstallDevelopmentHelper()
            return status
        }
        if service.status != .notRegistered { try service.unregister() }
        return status
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var usesAdHocSignature: Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return true }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return true }
        return dictionary[kSecCodeInfoTeamIdentifier as String] == nil
    }

    private func installDevelopmentHelper() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PulseBoardHelper").path
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/com.madongpeng.PulseBoard.helper.legacy.plist").path
        guard FileManager.default.isExecutableFile(atPath: executable),
              FileManager.default.fileExists(atPath: plist) else {
            throw HelperInstallError.missingBundledHelper
        }

        let command = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp \(shellQuote(executable)) \(shellQuote(Self.legacyExecutable))",
            "/usr/sbin/chown root:wheel \(shellQuote(Self.legacyExecutable))",
            "/bin/chmod 755 \(shellQuote(Self.legacyExecutable))",
            "/bin/cp \(shellQuote(plist)) \(shellQuote(Self.legacyPlist))",
            "/usr/sbin/chown root:wheel \(shellQuote(Self.legacyPlist))",
            "/bin/chmod 644 \(shellQuote(Self.legacyPlist))",
            "/bin/launchctl bootout system/\(Self.label) >/dev/null 2>&1 || true",
            "/bin/launchctl bootstrap system \(shellQuote(Self.legacyPlist))",
            "/bin/launchctl enable system/\(Self.label)",
            "/bin/launchctl kickstart -k system/\(Self.label)"
        ].joined(separator: "; ")
        try runAdministratorCommand(command)
    }

    private func uninstallDevelopmentHelper() throws {
        let command = [
            "/bin/launchctl bootout system/\(Self.label) >/dev/null 2>&1 || true",
            "/bin/rm -f \(shellQuote(Self.legacyPlist))",
            "/bin/rm -f \(shellQuote(Self.legacyExecutable))"
        ].joined(separator: "; ")
        try runAdministratorCommand(command)
    }

    private func runAdministratorCommand(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw HelperInstallError.cannotCreateAuthorizationRequest
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "管理员授权被取消或安装失败"
            throw HelperInstallError.authorizationFailed(message)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private enum HelperInstallError: LocalizedError {
    case missingBundledHelper
    case cannotCreateAuthorizationRequest
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledHelper: "App 中缺少高级监控辅助进程，请重新构建应用"
        case .cannotCreateAuthorizationRequest: "无法创建系统授权请求"
        case .authorizationFailed(let message): message
        }
    }
}
