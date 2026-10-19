import Foundation

/// Bytes for one session's terminal, by the session's key. The mirror hands these on and keeps none of them.
public struct TerminalEvent: Equatable, Sendable {
    public var key: String
    public var chunk: TerminalChunk

    public init(key: String, chunk: TerminalChunk) { self.key = key; self.chunk = chunk }
}

/// A command the Mac turned down, with the Mac's reason.
public struct RemoteRefusal: Equatable, Sendable {
    public var id: Int
    public var command: RemoteCommand
    public var text: String

    public init(id: Int, command: RemoteCommand, text: String) { self.id = id; self.command = command; self.text = text }
}

/// What a device knows about the Mac it is connected to, and how each message from the Mac changes it.
/// It only ever follows the Mac. A command changes nothing here by being sent: what it did on the Mac comes
/// back as the same updates a watching device gets.
///
/// Commands, for the views that send them:
/// - `canControl` says whether to offer controls at all. It is a courtesy: the Mac checks every command itself.
/// - `willSend(_:)` gives a command its id and records it as waiting. Send `.command(id:command:)` with that id.
///   A step of a drag that isn't the last is never answered, so it is given an id and not waited for.
/// - While `isWaiting(for:)` is true for a command, its button should be disabled.
/// - The Mac's `.answer` stops the wait. A refusal is kept in `lastRefusal` until `clearRefusal()` or the
///   next refusal, for a short message in the Mac's words.
/// - `giveUpWaiting(for:)` is for a command the Mac has taken too long over: it may yet be done.
/// - `dropWaiting()` is for when the link drops: those commands will never be answered. A new welcome does
///   the same, because it starts a new connection.
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
    /// Whether the Mac lets this device do more than watch. False until the Mac says otherwise.
    public private(set) var canControl = false
    /// The commands sent and not yet answered, by id.
    public private(set) var waiting: [Int: RemoteCommand] = [:]
    /// The last command the Mac turned down, and why.
    public private(set) var lastRefusal: RemoteRefusal?
    private var lastCommandID = 0

    public init() {}

    /// Call just before sending a command. Returns the id to send it with.
    public mutating func willSend(_ command: RemoteCommand) -> Int {
        lastCommandID += 1
        // The Mac sends no answer to a step of a drag, so waiting for one would never end.
        if command.isAnswered { waiting[lastCommandID] = command }
        return lastCommandID
    }

    /// Whether this very command has been sent and not yet answered.
    public func isWaiting(for command: RemoteCommand) -> Bool { waiting.values.contains(command) }

    /// The link dropped, so nothing that was waiting will be answered. Returns the ids that were.
    @discardableResult
    public mutating func dropWaiting() -> [Int] {
        defer { waiting.removeAll() }
        return waiting.keys.sorted()
    }

    /// The Mac has been given long enough to answer one command and hasn't. It stops being waited for, so its
    /// button can be pressed again. Whether it was done is not known: an answer that comes later is let pass,
    /// and what it changed arrives with the updates as ever. Returns the command, or nil if it wasn't waiting.
    @discardableResult
    public mutating func giveUpWaiting(for id: Int) -> RemoteCommand? { waiting.removeValue(forKey: id) }

    public mutating func clearRefusal() { lastRefusal = nil }

    /// Call just before asking the Mac for a flow, or nil for none. What was on show goes at once,
    /// so the old flow is never drawn under the new one's name. Returns false, and changes nothing, for the
    /// flow already open: the Mac doesn't send that one again, so clearing it would leave nothing on show.
    /// A flow that went from the Mac's list is asked for afresh, since the Mac stopped sending it then.
    @discardableResult
    public mutating func willOpen(_ flowID: String?) -> Bool {
        guard flowID != openFlowID || openFlowWentAway else { return false }
        openFlowID = flowID
        snapshot = nil
        revision = 0
        openFlowWentAway = false
        return true
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
            canControl = welcome.canControl
            // A welcome starts a new connection, and answers to what the old one was sent will never come.
            waiting.removeAll()
        case .refused(let text):
            refusal = text
            canControl = false
        case .control(let canControl):
            self.canControl = canControl
        case .answer(let id, let refusal):
            // An answer to nothing that is waiting is one from before the link dropped.
            guard let command = waiting.removeValue(forKey: id) else { break }
            if let refusal { lastRefusal = RemoteRefusal(id: id, command: command, text: refusal) }
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
        case .edit(let id, let state):
            guard isShowing(id) else { break }
            snapshot?.edit = state
        case .log(let id, let lines, let reset):
            guard isShowing(id) else { break }
            // A log at its cap loses its oldest lines as new ones come, as the Mac's does.
            if reset { snapshot?.log = lines } else if let log = snapshot?.log { snapshot?.log = RemoteSnapshot.appending(lines, to: log) }
        case .messages(let id, let link, let all):
            guard isShowing(id) else { break }
            // An empty list means the link carried nothing, which the Mac shows as no entry at all.
            snapshot?.messages[link] = all.isEmpty ? nil : all
        case .history(let id, let runs):
            guard isShowing(id) else { break }
            snapshot?.runs = runs
        case .terminal:
            return terminalEvent(in: message).map { [$0] } ?? []
        // A card's browser is drawn from its own feed, as a terminal is, and changes nothing here.
        case .browserPage, .browserFrame, .browserCopied:
            break
        }
        return []
    }

    /// A change only means something on top of the snapshot it follows.
    private func isShowing(_ flowID: String) -> Bool { flowID == openFlowID && snapshot != nil }
}
