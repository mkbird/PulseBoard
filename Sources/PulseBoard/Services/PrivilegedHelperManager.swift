import Foundation
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
    private let service = SMAppService.daemon(plistName: plistName)

    var status: PrivilegedHelperStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func enable() throws -> PrivilegedHelperStatus {
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
        if service.status != .notRegistered { try service.unregister() }
        return status
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
