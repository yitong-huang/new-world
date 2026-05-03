import Foundation
import ServiceManagement

enum HelperInstallerError: LocalizedError {
    case registerFailed(String)

    var errorDescription: String? {
        switch self {
        case let .registerFailed(s): return s
        }
    }
}

enum HelperInstaller {
    private static let plistName = "com.newworld.NewWorldVPN.helper.plist"

    /// 将内嵌的 LaunchDaemon 描述注册到系统（用户可能需在「系统设置 → 登录项 / 后台」中允许）。
    static func registerDaemonIfNeeded() async throws {
        let svc = SMAppService.daemon(plistName: plistName)
        switch svc.status {
        case .enabled:
            return
        case .requiresApproval:
            try await svc.register()
        case .notRegistered, .notFound:
            try await svc.register()
        @unknown default:
            try await svc.register()
        }
    }

    static func unregisterDaemon() async throws {
        let svc = SMAppService.daemon(plistName: plistName)
        try await svc.unregister()
    }
}
