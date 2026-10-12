import Foundation

/// What a session is doing, as Claude Code's hooks report it.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case notStarted, starting, idle, working, needsYou, failed, exited

    public var label: String {
        switch self {
        case .notStarted: "Not started"
        case .starting: "Starting"
        case .idle: "Idle"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .exited: "Exited"
        }
    }
}

/// Where the run on show has been, for one card.
public struct RunMark: Equatable, Sendable, Codable {
    /// Messages that reached the card along a link.
    public var arrivals = 0
    /// Times a message left the card.
    public var passes = 0
    /// How many times it left by each output, and the output it left by last.
    public var ports: [String: Int] = [:]
    public var lastPort: String?
    /// Arrivals since it last passed anything on: what an And is holding, what an Or dropped.
    public var holding = 0
    /// The run stopped at this card.
    public var failed = false

    public init() {}
}

/// A message waiting at an Approval or Script card in the run that is going.
public struct PendingHold: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let cardID: String
    public let kind: CardKind
    /// The message that is waiting.
    public let text: String
    public let from: String
    /// What the card is running: a Script card's command, or the name of the flow a Flow card runs.
    public var command: String
    /// A script whose command the person hasn't allowed yet.
    public var needsAllow: Bool
    /// True for a script whose command was last written, or brought back, from a paired device. Such a
    /// command is allowed at the Mac and nowhere else: no device may answer for the person there. Left out
    /// when it isn't so, so a hold reads the same to a device that knows nothing of this.
    public var allowOnMac: Bool?

    /// Whether a paired device may allow this script's command.
    public var canBeAllowedFromDevice: Bool { kind == .script && needsAllow && allowOnMac != true }

    public init(id: String, cardID: String, kind: CardKind, text: String, from: String, command: String = "", needsAllow: Bool = false,
                allowOnMac: Bool? = nil) {
        self.id = id; self.cardID = cardID; self.kind = kind; self.text = text; self.from = from
        self.command = command; self.needsAllow = needsAllow; self.allowOnMac = allowOnMac
    }
}

/// What a flow needs from you right now, for its row in the sidebar.
public enum FlowActivity: String, Codable, Sendable {
    case quiet, running, needsYou, failed
}

public struct LogLine: Identifiable, Equatable, Sendable, Codable {
    public var id = UUID()
    public let date: Date
    public let text: String

    public init(date: Date, text: String) { self.date = date; self.text = text }
}

/// One message a link carried in a run.
public struct LinkMessage: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public let date: Date
    public let from: String
    public let text: String

    public init(date: Date, from: String, text: String) { self.date = date; self.from = from; self.text = text }
}

/// What a Claude Code session has used: tokens, and what they would cost at API prices.
public struct Usage: Codable, Equatable, Sendable {
    public var cost = 0.0
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(cost: Double = 0, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.cost = cost; self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }

    public var tokens: Int { input + output + cacheRead + cacheWrite }
    public var isZero: Bool { cost == 0 && tokens == 0 }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(cost: a.cost + b.cost, input: a.input + b.input, output: a.output + b.output,
              cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    /// What was used since `earlier`, never less than nothing.
    public func since(_ earlier: Usage) -> Usage {
        Usage(cost: max(0, cost - earlier.cost), input: max(0, input - earlier.input), output: max(0, output - earlier.output),
              cacheRead: max(0, cacheRead - earlier.cacheRead), cacheWrite: max(0, cacheWrite - earlier.cacheWrite))
    }

    /// "$0.37", "<$0.01", "$124".
    public var price: String {
        if cost <= 0 { return "$0.00" }
        if cost < 0.01 { return "<$0.01" }
        return cost >= 100 ? String(format: "$%.0f", cost) : String(format: "$%.2f", cost)
    }

    /// "182k tokens", "1.2M tokens".
    public var tokenCount: String {
        let n = Double(tokens)
        if n >= 1_000_000 { return String(format: "%.1fM tokens", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk tokens", n / 1_000) }
        return "\(tokens) tokens"
    }
}

/// One run, kept so it can be looked at again: where it went, what each link carried and how it ended.
public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case finished, stopped, failed }

    public let id: String
    public let started: Date
    public var ended: Date
    public var outcome: Outcome
    /// What the run began with, in a few words.
    public var command: String
    public var log: [LogLine]
    public var results: [String: String]
    public var marks: [String: RunMark]
    public var linkPasses: [String: Int]
    public var messages: [String: [LinkMessage]]
    public var handOffs: Int
    /// What each agent's session used during the run, by card id. Filled in a moment after the run ends.
    public var usage: [String: Usage]?

    public init(id: String, started: Date, ended: Date, outcome: Outcome, command: String, log: [LogLine],
                results: [String: String], marks: [String: RunMark], linkPasses: [String: Int],
                messages: [String: [LinkMessage]], handOffs: Int, usage: [String: Usage]? = nil) {
        self.id = id; self.started = started; self.ended = ended; self.outcome = outcome; self.command = command
        self.log = log; self.results = results; self.marks = marks; self.linkPasses = linkPasses
        self.messages = messages; self.handOffs = handOffs; self.usage = usage
    }

    public var cost: Usage { (usage ?? [:]).values.reduce(Usage(), +) }
}
