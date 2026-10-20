import Foundation

/// Tells macOS that the app is doing work for the person while its sessions run, so it isn't slowed down.
///
/// Without this, a window that is hidden or behind others lets App Nap throttle the app, and hand-offs and hooks
/// back up behind it. While any session is live the app opts out of App Nap. While one is working it also keeps
/// the Mac from going to sleep on its own, so a long turn isn't cut off. The display still sleeps as usual, and
/// closing the lid or choosing Sleep still puts the Mac to sleep.
enum KeepAwake {
    private static var live: Set<ObjectIdentifier> = []
    private static var working: Set<ObjectIdentifier> = []
    private static var activity: NSObjectProtocol?
    private static var activityKeepsMacAwake = false

    /// A session's state changed.
    static func note(_ session: AnyObject, live isLive: Bool, working isWorking: Bool) {
        let id = ObjectIdentifier(session)
        if isLive { live.insert(id) } else { live.remove(id) }
        if isWorking { working.insert(id) } else { working.remove(id) }
        update()
    }

    private static func update() {
        let wanted: Bool? = live.isEmpty ? nil : !working.isEmpty
        if let current = activity, wanted != activityKeepsMacAwake || wanted == nil {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        guard let keepsMacAwake = wanted, activity == nil else { return }
        activityKeepsMacAwake = keepsMacAwake
        activity = ProcessInfo.processInfo.beginActivity(
            options: keepsMacAwake ? .userInitiated : .userInitiatedAllowingIdleSystemSleep,
            reason: keepsMacAwake ? "An agent is working" : "Agents are running")
    }
}
