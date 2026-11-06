import AppKit
import UserNotifications

/// Mac notifications for approvals and finished missions, only when Tristan is not the frontmost app.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var enabled = true
    var onOpen: (() -> Void)?
    private var configured = false

    /// Notifications need a real app bundle, so they are skipped for `swift run` and tests.
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    nonisolated static func shouldNotify(enabled: Bool, appIsActive: Bool, bundled: Bool) -> Bool { enabled && !appIsActive && bundled }

    func post(title: String, body: String) {
        guard available else { return }   // also keeps us away from NSApp, which does not exist in tests
        guard Self.shouldNotify(enabled: enabled, appIsActive: NSApp.isActive, bundled: true) else { return }
        let center = UNUserNotificationCenter.current()
        if !configured {
            configured = true
            center.delegate = self
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(180))
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.onOpen?() }
        completionHandler()
    }
}
