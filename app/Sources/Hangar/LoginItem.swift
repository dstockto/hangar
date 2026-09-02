import Foundation
import ServiceManagement

/// Open-at-login, via SMAppService. No helper bundle and no privileged install:
/// the app registers itself, and macOS shows it in System Settings under General,
/// Login Items, where the user can revoke it independently of Hangar.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// What macOS currently thinks, which is not always what we asked for: the user
    /// can turn it off in System Settings, and a build running from somewhere other
    /// than Applications is refused outright.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:              return "Hangar opens at login."
        case .notRegistered:        return "Hangar does not open at login."
        case .requiresApproval:     return "Waiting for approval in System Settings, Login Items."
        case .notFound:             return "Not available: move Hangar to Applications first."
        @unknown default:           return "Unknown login item state."
        }
    }

    /// Returns nil on success, or a message to show the user.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    return "Approve Hangar in System Settings, General, Login Items."
                }
                return nil
            }
            guard SMAppService.mainApp.status != .notRegistered else { return nil }
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            return "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
