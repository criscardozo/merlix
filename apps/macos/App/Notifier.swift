import AppKit
import UserNotifications

/// macOS notifications for sessions that need attention while you look elsewhere.
/// Clicking one brings Merlix forward with that session selected.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { await requestAuthorization() }
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            logger.info("notification authorization granted: \(granted, privacy: .public)")
        } catch {
            logger.warning("notification authorization: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.cristian.merlix"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(title: String, subtitle: String = "", body: String, sessionID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        // One notification per session: a newer one replaces the previous.
        let request = UNNotificationRequest(identifier: sessionID.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("posting a notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["sessionID"] as? String,
              let id = UUID(uuidString: raw)
        else { return }
        await MainActor.run {
            NSApp.activate()
            Workspace.shared.select(id)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
