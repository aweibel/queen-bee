import AppKit
import UserNotifications

/// System notifications for what can happen while you are in another app: an agent waiting
/// on you, or a run ending. Clicking one brings the app forward on the flow, and the card.
enum Notifier {
    static let settingKey = "notifies"

    /// On unless switched off in Settings.
    static var isOn: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    private static let delegate = Delegate()

    static func start() {
        guard !TestHarness.isEnabled else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Posts a notification, unless the app is in front, notifications are off, or this is a
    /// test run. The Mac asks for permission the first time.
    static func post(title: String, body: String, flowID: String, cardID: String?) {
        guard isOn, !TestHarness.isEnabled, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["flow": flowID, "card": cardID ?? ""]
        // One notification per card, or per flow: a newer one replaces the older.
        let request = UNNotificationRequest(identifier: "\(flowID)/\(cardID ?? "run")", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let info = response.notification.request.content.userInfo
            let flow = info["flow"] as? String, card = info["card"] as? String
            await MainActor.run {
                // Opens the window again if it was closed, as clicking the Dock icon does.
                guard let flow else { return AppServices.shared.showWorkspace() }
                AppServices.shared.reveal(flowID: flow, cardID: card?.isEmpty == false ? card : nil)
            }
        }
    }
}
