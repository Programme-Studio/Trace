import Foundation
import ServiceManagement

/// Wraps SMAppService so the setting is a toggle rather than a trip to System Settings.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a message to show the user.
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Couldn't change the login item: \(error.localizedDescription)"
        }
    }
}
