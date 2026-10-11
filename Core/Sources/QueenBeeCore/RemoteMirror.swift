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

    public init() {}

    /// Call just before asking the Mac for a flow, or nil for none. What was on show goes at once,
    /// so the old flow is never drawn under the new one's name.
    public mutating func willOpen(_ flowID: String?) {
        openFlowID = flowID
        snapshot = nil
        revision = 0
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
        case .opened(let snapshot):
            // The reply to an earlier open can arrive after the person has moved on to another flow.
            // A second snapshot of the open flow is a fresh start, as after reconnecting.
            guard snapshot.flow.id == openFlowID else { break }
            self.snapshot = snapshot
            revision = 0
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
        case .terminal(let id, let key, let chunk):
            // Terminals do not wait for the snapshot: their first chunk sets the screen up.
            guard id == openFlowID else { break }
            return [TerminalEvent(key: key, chunk: chunk)]
        }
        return []
    }

    /// A change only means something on top of the snapshot it follows.
    private func isShowing(_ flowID: String) -> Bool { flowID == openFlowID && snapshot != nil }
}
