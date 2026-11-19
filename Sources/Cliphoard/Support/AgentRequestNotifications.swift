import Foundation
import UserNotifications

/// Notifications never contain agent-provided text, paths, or credentials.
@MainActor
final class AgentRequestNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let identifier = "cliphoard.agent-requests"
    static let title = "An agent is asking for permission to save clips"
    private let center = UNUserNotificationCenter.current()
    var onOpen: (() -> Void)?
#if !APP_STORE || LOCAL_PERFORMANCE_PRO
    var onOpenUpdate: (() -> Void)?
    static let updateIdentifier = "cliphoard.direct-update"

    func notifyUpdate(_ release: DirectRelease) async -> Bool {
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]),
                  DirectUpdateChecker.shared.automaticChecks else { return false }
            let content = UNMutableNotificationContent()
            content.title = "A Cliphoard update is available"
            content.body = "\(release.label) is ready for Free and Pro. Open Cliphoard to view the release."
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: Self.updateIdentifier,
                                                       content: content, trigger: nil))
            return true
        } catch { return false } // The persistent in-app notice remains available.
    }
#endif

    override init() {
        super.init()
        center.delegate = self
    }

    // Called only after the user explicitly enables an agent connection.
    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(count: Int) {
        guard count > 0 else { clear(); return }
        let content = UNMutableNotificationContent()
        content.title = Self.title
        content.body = "\(count) pending \(count == 1 ? "clip" : "clips"). Open Cliphoard to accept or reject each one."
        content.sound = .default
        // A single identifier replaces the previous queue notice instead of
        // producing one notification per clip. Denial leaves the in-app queue usable.
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    func clear() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
#if !APP_STORE || LOCAL_PERFORMANCE_PRO
        if response.notification.request.identifier == "cliphoard.direct-update",
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor [weak self] in self?.onOpenUpdate?(); completionHandler() }
            return
        }
#endif
        guard response.notification.request.identifier == "cliphoard.agent-requests",
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
        Task { @MainActor [weak self] in self?.onOpen?(); completionHandler() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
