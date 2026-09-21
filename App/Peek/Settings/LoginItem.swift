import Foundation
import OSLog
import ServiceManagement

/// Launch-at-login, via `SMAppService`.
///
/// The supported modern API — the old `LSSharedFileList` approach is
/// deprecated and the login-item helper bundle pattern is unnecessary for
/// registering the main app itself.
enum LoginItem {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "loginitem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user has disabled the item in System Settings, which the
    /// app cannot override and should not silently fight.
    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            logger.error("login item change failed status=\(SMAppService.mainApp.status.rawValue, privacy: .public)")
            return false
        }
    }
}
