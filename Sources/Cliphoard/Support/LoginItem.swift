import Foundation
import ServiceManagement

/// Launch-at-login state, shared by the menu and the in-bar settings.
@MainActor
enum LoginItem {
    static var enabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func set(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Cliphoard: launch-at-login toggle failed: \(error)")
        }
    }
}
