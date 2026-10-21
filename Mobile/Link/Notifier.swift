import Foundation
import Observation
import QueenBeeCore
import UIKit
import UserNotifications

/// Notifications about runs on the Mac, shown while the app is in the background and still connected: a message
/// held for approval or a script waiting, which can be answered from the notification by a device that can
/// control the Mac, a session asking something, and a run ending. They are made on this device from what the Mac
/// sends: nothing comes from a server, so once iOS stops the app in the background, nothing more arrives.
@Observable
final class Notifier: NSObject {
    static let enabledKey = "notifies"

    /// The setting in the app's settings. On unless turned off.
    var isOn: Bool {
        get { access(keyPath: \.isOn); return UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            withMutation(keyPath: \.isOn) { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
            if !newValue { clearAll() }
        }
    }
    /// What iOS lets the app do: nil until asked, then whether notifications may be shown.
    private(set) var isAllowed: Bool?

    @ObservationIgnored weak var client: RemoteClient?
    @ObservationIgnored private var notices = RemoteNotices()
    /// Whether iOS has been asked this time the app ran, so it is asked once at most.
    @ObservationIgnored private var hasAsked = false

    private enum Action {
        static let approve = "approve", reject = "reject", allow = "allow", refuse = "refuse"
    }

    /// Runs once at launch: the buttons notifications can have, and who hears them pressed.
    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Answering for the person is done only on a device that is unlocked.
        let sure: UNNotificationActionOptions = [.authenticationRequired]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: RemoteNotice.Answer.approval.rawValue, actions: [
                UNNotificationAction(identifier: Action.approve, title: "Approve", options: sure),
                UNNotificationAction(identifier: Action.reject, title: "Reject", options: sure.union(.destructive)),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: RemoteNotice.Answer.script.rawValue, actions: [
                UNNotificationAction(identifier: Action.allow, title: "Allow", options: sure),
                UNNotificationAction(identifier: Action.refuse, title: "Don't Allow", options: sure.union(.destructive)),
            ], intentIdentifiers: []),
        ])
        Task { await refreshPermission() }
    }

    /// Reads again what iOS allows, as after coming back from Settings.
    func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        isAllowed = switch status {
        case .notDetermined: nil
        case .denied: false
        default: true
        }
    }

    /// The Mac has let the device in. The first time the app is connected and on screen is when it asks iOS, once:
    /// that is when notifications start to mean something.
    func connected() {
        guard isOn, !hasAsked, UIApplication.shared.applicationState == .active else { return }
        hasAsked = true
        Task { await ask() }
    }

    /// Asks iOS, if it hasn't been asked. For the switch in the app's settings too.
    func ask() async {
        await refreshPermission()
        guard isAllowed == nil else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshPermission()
    }

    /// Looks at what the Mac sent. What is new is shown when the app is in the background; what was new while it
    /// was on screen was seen there, and is not shown later.
    func look(at mirror: RemoteMirror, inBackground: Bool) {
        let (new, gone) = notices.update(from: mirror)
        let center = UNUserNotificationCenter.current()
        if !gone.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: gone)
            center.removePendingNotificationRequests(withIdentifiers: gone)
        }
        guard inBackground, isOn, isAllowed == true else { return }
        for notice in new { post(notice) }
    }

    private func post(_ notice: RemoteNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.flowID
        content.categoryIdentifier = notice.answer?.rawValue ?? ""
        var info: [String: String] = ["flowID": notice.flowID]
        info["holdID"] = notice.holdID
        info["text"] = notice.heldText
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    /// An answer given from a notification that the Mac turned down, or couldn't be sent.
    func tell(couldNotAnswer reason: String) {
        guard isOn, isAllowed == true else { return }
        post(RemoteNotice(id: "answer-\(UUID().uuidString)", title: "That answer didn't go through", body: reason, flowID: ""))
    }

    /// The device has left its Mac: nothing it was told about is current any more.
    func forget() {
        notices = RemoteNotices()
        clearAll()
    }

    private func clearAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// A notification's button was pressed, or the notification itself.
    private func respond(to action: String, flowID: String?, holdID: String?, text: String?) async {
        guard let client, let flowID, !flowID.isEmpty else { return }
        let command: RemoteCommand? = switch (action, holdID) {
        case (Action.approve, let holdID?): .approve(flowID: flowID, holdID: holdID, text: text ?? "")
        case (Action.reject, let holdID?): .reject(flowID: flowID, holdID: holdID, note: "")
        case (Action.allow, let holdID?): .allowScript(flowID: flowID, holdID: holdID)
        case (Action.refuse, let holdID?): .refuseScript(flowID: flowID, holdID: holdID)
        default: nil
        }
        if let command {
            await client.answerFromNotification(command)
        } else if action == UNNotificationDefaultActionIdentifier, client.mirror.library?.projects.contains(where: { $0.flows.contains { $0.id == flowID } }) == true {
            // The notification itself opens its flow.
            client.open(flowID)
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// On screen, what a notification would say is on the screen already.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let flowID = info["flowID"] as? String, holdID = info["holdID"] as? String, text = info["text"] as? String
        await respond(to: action, flowID: flowID, holdID: holdID, text: text)
    }
}
