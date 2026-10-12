import Foundation

// What holds a paired device's edits to less than the Mac's own canvas is held to, worked out here so it
// can be checked without a Mac: how much a device may send and how fast, what counts as changing what a
// flow does, and how often the log is told.

extension Remote {
    /// The same caps as `nameLimit` and `textLimit`, in bytes of UTF-8. A character can be made of any
    /// number of marks stacked on a letter, so a count of characters alone caps nothing. These leave room
    /// for four bytes to every character, and for the biggest patch to fit in what the Mac takes from a
    /// device in one message, 64 KB, with room to spare.
    public static let nameByteLimit = 800
    public static let textByteLimit = 48_000
    public static let pathByteLimit = 4_000
    /// The most agent cards a flow may have and still be given another from a device. Each agent is a
    /// Claude Code session on the Mac.
    public static let agentLimit = 12
    /// The biggest a flow's file may be made from a device, in bytes. A bigger one, made on the Mac, can be
    /// changed from a device and not grown.
    public static let flowByteLimit = 2_000_000
    /// As much of a name as is copied into a line of the Mac's log, in characters.
    public static let logNameLimit = 60

    /// A name for a line of the Mac's log: on one line, safe to show, and short. A long one is cut off with "…".
    public static func logName(_ name: String, or fallback: String = "a device") -> String {
        let line = plainLine(name)
        guard !line.isEmpty else { return fallback }
        return line.count > logNameLimit ? String(line.prefix(logNameLimit)) + "…" : line
    }

    /// Whether a one-line setting from a device fits, by characters and by bytes.
    static func fitsName(_ text: String) -> Bool { text.utf8.count <= nameByteLimit && text.count <= nameLimit }
    /// Whether a long text from a device fits, by characters and by bytes.
    static func fitsText(_ text: String, characters: Int = textLimit) -> Bool { text.utf8.count <= textByteLimit && text.count <= characters }
    static func fitsPath(_ text: String) -> Bool { text.utf8.count <= pathByteLimit && text.count <= pathLimit }

    /// What the Mac answers a device that sends commands faster than a person makes changes.
    public static let tooFastRefusal = "Too many changes at once. Try again in a moment."
    /// As many commands as a device may send in a burst, which is what a drag's steps come to, and as many
    /// a second as it may keep sending.
    public static let commandBurst = 60.0
    public static let commandsASecond = 20.0
}

extension Flow {
    /// Whether this flow does anything different from `old` when it runs. Where a card is, how big it is,
    /// which group it is in and what the flow is called make no difference, and nor does a note, which
    /// nothing is linked to. Everything else does: a link, a card added or taken away, and any setting.
    ///
    /// A schedule runs a flow with nobody watching, so when a paired device changes what the flow does,
    /// its schedules go off.
    public func changesWhatItDoes(from old: Flow) -> Bool {
        func parts(_ flow: Flow) -> [Card] {
            flow.cards.filter { $0.kind != .note }.map { card in
                var card = card
                card.x = 0; card.y = 0; card.width = 0; card.height = 0
                // The session behind a card is not part of what the person agreed the flow does.
                card.sessionID = nil
                return card
            }.sorted { $0.id < $1.id }
        }
        func links(_ flow: Flow) -> [Link] { flow.links.sorted { $0.id < $1.id } }
        return parts(self) != parts(old) || links(self) != links(old) || subflowLimit != old.subflowLimit
    }
}

/// How fast one device may send commands: so many in a burst, refilled at so many a second.
public struct TokenBucket: Sendable {
    public let capacity: Double
    public let refill: Double
    private var tokens: Double
    private var last: Date

    public init(capacity: Double = Remote.commandBurst, refill: Double = Remote.commandsASecond, now: Date = Date()) {
        self.capacity = capacity; self.refill = refill; tokens = capacity; last = now
    }

    /// True when there was room for one more, which is then taken.
    public mutating func take(now: Date = Date()) -> Bool {
        tokens = min(capacity, tokens + max(0, now.timeIntervalSince(last)) * refill)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// Counts each kind of thing a device does over and over, so the log is told of the first and, when the
/// time is up, how many more there were: one line, or two, for any number of them.
public struct EditTally: Sendable {
    /// How long one kind of edit is counted before the log is told again.
    public static let window: TimeInterval = 30
    private var counts: [String: Int] = [:]

    public init() {}

    /// Counts one more. True for the first since the count was last closed: that one is put in the log now.
    public mutating func count(_ key: String) -> Bool {
        counts[key, default: 0] += 1
        return counts[key] == 1
    }

    /// Ends the count, and says how many there were after the first.
    public mutating func close(_ key: String) -> Int {
        max(0, (counts.removeValue(forKey: key) ?? 0) - 1)
    }

    /// "3 more times", "once more".
    public static func more(_ extra: Int) -> String { extra == 1 ? "once more" : "\(extra) more times" }
}

/// A flow a device asked the Mac to make, and is waiting to see in the Mac's list so as to open it.
///
/// Only that flow is opened. A flow that turns up in the project later, or under another name, was made by
/// somebody else, at the Mac or on another device, and opening it would take the person somewhere they did
/// not ask to go.
public struct NewFlowAwaited: Equatable, Sendable {
    public var projectID: String
    /// The flows the project had when the new one was asked for.
    public var known: Set<String>
    /// The name asked for, as the Mac keeps a name: on one line, with no space at either end. Empty when
    /// the Mac was left to name it.
    public var name: String
    /// When the Mac answered that the flow was made.
    public var answered: Date

    /// How long after the Mac's answer its list may take to show the flow, in seconds.
    public static let patience: TimeInterval = 5

    public init(projectID: String, known: Set<String>, name: String, answered: Date) {
        self.projectID = projectID; self.known = known; self.name = Remote.plainLine(name); self.answered = answered
    }

    public func isOver(at now: Date = Date()) -> Bool { now.timeIntervalSince(answered) > Self.patience }

    /// The flow to open, out of the project's flows as the Mac now lists them. Nil when it isn't there, or
    /// can't be told apart from another.
    public func flow(among flows: [RemoteFlowSummary], now: Date = Date()) -> RemoteFlowSummary? {
        guard !isOver(at: now) else { return nil }
        let new = flows.filter { !known.contains($0.id) }
        // Named: the one with that name. Left to the Mac: the only new one, since any of several could be it.
        if !name.isEmpty { return new.first { $0.name == name } }
        return new.count == 1 ? new[0] : nil
    }
}
