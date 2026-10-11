import Foundation

/// Bytes for one session's terminal, by the session's key. The mirror hands these on and keeps none of them.
public struct TerminalEvent: Equatable, Sendable {
    public var key: String
    public var chunk: TerminalChunk

    public init(key: String, chunk: TerminalChunk) { self.key = key; self.chunk = chunk }
}

/// What a device knows about the Mac it is connected to, and how each message from the Mac changes it.
/// It only ever follows the Mac: nothing here is sent back.
public struct RemoteMirror: Equatable, Sendable {
    public private(set) var library: RemoteLibrary?
    public private(set) var welcome: RemoteWelcome?
    /// Why the Mac turned the device away, in the Mac's words. Cleared by the next welcome.
    public private(set) var refusal: String?
    /// The flow the device asked for. The snapshot follows once the Mac has sent it.
    public private(set) var openFlowID: String?
    public private(set) var snapshot: RemoteFlowSnapshot?
    /// The revision of the last `.flow` change seen for the open flow, or 0 when its snapshot has had none yet.
    /// The Mac counts these per connection, so it says how many times the flow changed, not which copy is newer.
    public private(set) var revision = 0
    /// True once the Mac's list has come without the open flow in it. The Mac stops sending that flow then, so
    /// one that comes back has to be asked for again. Cleared by asking, and by a fresh snapshot of it.
    public private(set) var openFlowWentAway = false

    public init() {}

    /// Call just before asking the Mac for a flow, or nil for none. What was on show goes at once,
    /// so the old flow is never drawn under the new one's name.
    public mutating func willOpen(_ flowID: String?) {
        openFlowID = flowID
        snapshot = nil
        revision = 0
        openFlowWentAway = false
    }

    /// The terminal bytes a message carries for the open flow, if it carries any. Reading them changes nothing
    /// here, so a device can hand them straight to its terminals without touching what everything else draws from.
    public func terminalEvent(in message: HostMessage) -> TerminalEvent? {
        // Terminals do not wait for the snapshot: their first chunk sets the screen up.
        guard case .terminal(let id, let key, let chunk) = message, id == openFlowID else { return nil }
        return TerminalEvent(key: key, chunk: chunk)
    }

    /// Takes one message from the Mac. Returns the terminal bytes it carried, if any, for the terminals to draw.
    public mutating func apply(_ message: HostMessage) -> [TerminalEvent] {
        switch message {
        case .welcome(let welcome):
            self.welcome = welcome
            refusal = nil
        case .refused(let text):
            refusal = text
        case .library(let library):
            self.library = library
            if let openFlowID, !library.projects.contains(where: { $0.flows.contains { $0.id == openFlowID } }) {
                openFlowWentAway = true
            }
        case .opened(let snapshot):
            // The reply to an earlier open can arrive after the person has moved on to another flow.
            // A second snapshot of the open flow is a fresh start, as after reconnecting.
            guard snapshot.flow.id == openFlowID else { break }
            self.snapshot = snapshot
            revision = 0
            openFlowWentAway = false
        case .flow(let id, let revision, let flow):
            guard isShowing(id) else { break }
            snapshot?.flow = flow
            self.revision = revision
        case .run(let id, let state):
            guard isShowing(id) else { break }
            snapshot?.run = state
        case .log(let id, let lines, let reset):
            guard isShowing(id) else { break }
            if reset { snapshot?.log = lines } else { snapshot?.log += lines }
        case .messages(let id, let link, let all):
            guard isShowing(id) else { break }
            // An empty list means the link carried nothing, which the Mac shows as no entry at all.
            snapshot?.messages[link] = all.isEmpty ? nil : all
        case .history(let id, let runs):
            guard isShowing(id) else { break }
            snapshot?.runs = runs
        case .terminal:
            return terminalEvent(in: message).map { [$0] } ?? []
        }
        return []
    }

    /// A change only means something on top of the snapshot it follows.
    private func isShowing(_ flowID: String) -> Bool { flowID == openFlowID && snapshot != nil }
}
