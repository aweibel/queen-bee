import Foundation

/// What a card on the canvas is: an agent (a live Claude Code session) or one of the logic cards.
public enum CardKind: String, Codable, CaseIterable, Sendable {
    case agent, start
    case ifElse = "if"
    case switchCard = "switch"
    case and, or, prompt, loop, end, note
    /// Holds a message until the person approves or rejects it.
    case approval
    /// Runs a shell command and routes on whether it succeeded.
    case script
    /// Runs another flow in the same project as one step of this one.
    case flow

    public var label: String {
        switch self {
        case .agent: "Agent"
        case .start: "Start"
        case .ifElse: "If / Else"
        case .switchCard: "Switch"
        case .and: "And"
        case .or: "Or"
        case .prompt: "Prompt"
        case .loop: "Loop until"
        case .end: "End"
        case .note: "Note"
        case .approval: "Approval"
        case .script: "Script"
        case .flow: "Flow"
        }
    }
}

/// How an If or Loop card checks a message.
public enum CheckKind: String, Codable, CaseIterable, Sendable {
    case judge, contains
    case notContains = "not-contains"
    case regex
}

public struct Card: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: CardKind
    public var name: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    // Agent
    /// A standing brief, added to the session's system prompt.
    public var instructions: String?
    /// A model alias or id for `claude --model`; nil for the person's default.
    public var model: String?
    /// low, medium, high, xhigh or max; nil for the model's default.
    public var effort: String?
    /// manual, acceptEdits, plan or auto; nil for the person's default.
    public var permissionMode: String?
    /// The only modes a card may ask for. A mode that skips permission checks is never one of them,
    /// whether it comes from a flow file, the orchestrator's tools or the settings panel.
    public static let permissionModes = ["manual", "acceptEdits", "plan", "auto"]
    /// The only effort levels a card may ask for.
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    /// The folder the session runs in; nil for the project folder.
    public var cwd: String?
    /// The Claude Code session behind the card, set the first time it starts.
    public var sessionID: String?
    /// The saved role the agent was made from, if any: an id from the app's own list of roles.
    public var role: String?
    /// The card has a web browser beside its terminal, which the agent can use. Nil means it doesn't.
    public var browser: Bool?

    // Start
    /// The command a run begins with.
    public var command: String?
    /// What starts a run from this card besides the Run button. Nil for only the button.
    public var trigger: Trigger?

    // Flow
    /// The id of the flow this card runs, in the same project.
    public var flowRef: String?

    // If, Loop
    public var check: CheckKind?
    /// The text, pattern or plain-English statement the check tests.
    public var value: String?
    /// Loop: tries before it gives up and takes Done.
    public var maxTries: Int?

    // Switch
    public var branches: [String]?

    // Prompt
    /// The rewritten message; `{{message}}` and `{{from}}` are filled in.
    public var template: String?

    // End
    /// A file to save the final answer to, relative to the project folder.
    public var saveTo: String?

    // Note
    public var text: String?

    public init(id: String, kind: CardKind, name: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.kind = kind; self.name = name
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// A new card of `kind` with that kind's default settings and size.
    public static func make(kind: CardKind, id: String = Flow.newID(), name: String, x: Double, y: Double) -> Card {
        var c = Card(id: id, kind: kind, name: name, x: x, y: y, width: 240, height: 96)
        switch kind {
        case .agent: c.width = 560; c.height = 380; c.instructions = ""
        case .start: c.command = ""
        case .ifElse: c.check = .judge; c.value = ""
        case .switchCard: c.branches = ["A", "B"]
        case .loop: c.check = .judge; c.value = ""; c.maxTries = 3
        case .prompt: c.template = ""
        case .end: c.saveTo = ""
        case .note: c.text = ""; c.height = 120
        case .approval: c.text = ""
        case .script: c.command = ""
        case .and, .or, .flow: break
        }
        c.height = max(c.height, Card.minimumHeight(for: c))
        return c
    }

    /// Room for the title, a summary line and one row per named output.
    public static func minimumHeight(for card: Card) -> Double {
        if card.kind == .agent { return 200 }
        let named = ports(of: card).count > 1 ? Double(ports(of: card).count) * 24 : 0
        return 72 + named
    }
}

/// A connection from one card's output to another card's input.
public struct Link: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var from: String
    /// The output of `from` it leaves: out, yes, no, a branch name, other, done or again.
    public var port: String
    public var to: String
    /// How many times it may fire in one run, so loops always end.
    public var maxPasses: Int

    public init(id: String = Flow.newID(), from: String, port: String = "out", to: String, maxPasses: Int = 3) {
        self.id = id; self.from = from; self.port = port; self.to = to; self.maxPasses = maxPasses
    }
}

public struct Flow: Codable, Identifiable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var name: String
    public var cards: [Card]
    public var links: [Link]
    /// The Claude Code session of the flow's orchestrator, set the first time it starts.
    public var orchestratorSessionID: String?
    /// Post a notice to the orchestrator when a run finishes, stalls or hits a limit.
    public var notifyOrchestrator: Bool
    /// How many levels of sub-flow may sit below this flow when it is the one at the top. Nil for the usual three.
    public var subflowLimit: Int?
    /// True for a flow made to live inside a Flow card: it is listed under the flows that use it.
    public var isSubflow: Bool?
    /// Named sets of cards that are framed together and can be folded into one card. Nil in
    /// a file from before groups.
    public var groups: [CardGroup]?

    public init(id: String = Flow.newID(), name: String, cards: [Card] = [], links: [Link] = []) {
        self.version = Flow.currentVersion
        self.id = id; self.name = name; self.cards = cards; self.links = links
        self.orchestratorSessionID = nil
        self.notifyOrchestrator = true
    }

    /// Eight hex characters: short enough to read in a log, long enough not to collide in one project.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// What the app calls a flow's orchestrator session where a card's id would go. No card may have it.
    public static let orchestratorKey = "orchestrator"

    /// Whether the ids are ones the app could have made. Each session is known to the app as
    /// "<flow id>/<card id>", with the orchestrator's as "<flow id>/orchestrator", and what a session
    /// may do follows from that name. A file that calls a card "orchestrator", or puts a slash in
    /// an id, would get an agent's session treated as some other one.
    public var hasSafeIDs: Bool {
        func plain(_ id: String) -> Bool { !id.isEmpty && !id.contains("/") }
        return plain(id) && cards.allSatisfy { plain($0.id) && $0.id != Self.orchestratorKey }
    }

    public func card(_ id: String) -> Card? { cards.first { $0.id == id } }
    public func links(from id: String, port: String? = nil) -> [Link] {
        links.filter { $0.from == id && (port == nil || $0.port == port) }
    }
    public func links(into id: String) -> [Link] { links.filter { $0.to == id } }
}

/// Several cards framed together under a name. Folded, they show as one card.
public struct CardGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var cardIDs: [String]
    public var isFolded: Bool

    public init(id: String = Flow.newID(), name: String, cardIDs: [String], isFolded: Bool = false) {
        self.id = id; self.name = name; self.cardIDs = cardIDs; self.isFolded = isFolded
    }
}

/// A card's outputs, top to bottom.
public func ports(of card: Card) -> [String] {
    switch card.kind {
    case .ifElse: ["yes", "no"]
    case .switchCard: (card.branches ?? []) + ["other"]
    case .loop: ["done", "again"]
    case .approval: ["approved", "rejected"]
    case .script: ["pass", "fail"]
    case .flow: ["done", "fail"]
    case .end, .note: []
    case .agent, .start, .and, .or, .prompt: ["out"]
    }
}

/// Whether messages can be linked into a card.
public func acceptsInput(_ card: Card) -> Bool {
    card.kind != .start && card.kind != .note
}

public func portLabel(_ port: String) -> String {
    switch port {
    case "out": "Out"
    case "yes": "Yes"
    case "no": "No"
    case "other": "Other"
    case "done": "Done"
    case "again": "Again"
    case "approved": "Approved"
    case "rejected": "Rejected"
    case "pass": "Pass"
    case "fail": "Fail"
    default: port
    }
}

/// Changes to a card's settings. A nil field is left as it is.
public struct CardPatch: Equatable, Sendable {
    public var name: String?
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var instructions: String?
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    public var cwd: String?
    public var browser: Bool?
    public var command: String?
    public var check: CheckKind?
    public var value: String?
    public var maxTries: Int?
    public var branches: [String]?
    public var template: String?
    public var saveTo: String?
    public var text: String?
    public var flowRef: String?

    public init() {}
}
