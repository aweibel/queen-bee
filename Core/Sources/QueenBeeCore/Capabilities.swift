import Foundation

/// One setting of a card, as the orchestrator may set it.
public struct SettingCapability: Sendable {
    /// The name the orchestrator's tools take it by, such as "permission_mode".
    public let key: String
    /// Its JSON type and limits, without a description.
    public let schema: JSONValue
    /// What it is for, in a sentence or two.
    public let about: String

    init(_ key: String, _ schema: JSONValue, _ about: String) {
        self.key = key; self.schema = schema; self.about = about
    }

    /// A setting that is plain text.
    init(_ key: String, _ about: String) {
        self.init(key, ["type": "string"], about)
    }
}

/// What one kind of card can do.
public struct CardCapability: Sendable {
    public let kind: CardKind
    /// What the card does when a run reaches it.
    public let does: String
    /// Said in place of the list of outputs when the outputs depend on the card's settings.
    public let outputsNote: String?
    public let settings: [SettingCapability]
    /// Rules and limits the orchestrator has to build within.
    public let notes: [String]

    init(_ kind: CardKind, does: String, outputsNote: String? = nil, settings: [SettingCapability] = [], notes: [String] = []) {
        self.kind = kind; self.does = does; self.outputsNote = outputsNote; self.settings = settings; self.notes = notes
    }

    /// The card's outputs in words, read off the same code the canvas draws its dots from.
    public var outputs: String {
        if let outputsNote { return outputsNote }
        let names = ports(of: Card.make(kind: kind, name: kind.label, x: 0, y: 0))
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

/// The one place that says what Queen Bee can do. The orchestrator's instructions, its tools' settings and
/// `CAPABILITIES.md` are all made from this, so they can't disagree, and none of them is written by hand.
///
/// To add or change a capability, change it here. A new kind of card doesn't compile until `card(_:)` describes
/// it, a setting that isn't listed here can't be set by the orchestrator, and the tests fail if a setting in
/// `CardPatch` is missing or `CAPABILITIES.md` is out of date. `./scripts/build.sh` rewrites that file.
public enum Capabilities {
    /// A Script card's command that hasn't finished by now is stopped and goes out fail.
    public static let scriptTimeout: Duration = .seconds(600)
    /// As much of what a Script card's command printed as is passed on: the end of it, where a failure usually is.
    public static let scriptOutputLimit = 20_000

    public static func card(_ kind: CardKind) -> CardCapability {
        switch kind {
        case .agent:
            CardCapability(.agent,
                does: "A live Claude Code agent that does work. When its turn ends, its reply goes out along its links.",
                settings: [
                    SettingCapability("instructions", "A standing brief the agent always follows. Name the files and folders it reads and writes. It finds files with ls, find and grep in the shell, which need no approval, so don't forbid the shell outright."),
                    SettingCapability("model", "A model alias or id, such as opus, sonnet or haiku. An empty string goes back to the person's default."),
                    SettingCapability("effort", "One of: \(Card.effortLevels.joined(separator: ", ")). An empty string goes back to the model's default."),
                    SettingCapability("permission_mode", "One of: \(Card.permissionModes.joined(separator: ", ")). An empty string goes back to the person's default."),
                    SettingCapability("cwd", "The folder the agent works in. An empty string goes back to the project folder."),
                    SettingCapability("browser", ["type": "boolean"], "true gives the agent a web browser in its card, which the person can watch and use too, and makes the card twice as wide. Turn it on only for an agent whose work needs the web. Its tools and limits are listed under \"An agent with a browser\"."),
                ],
                notes: ["New settings apply the next time the agent's session starts."])
        case .start:
            CardCapability(.start,
                does: "Holds the command a run begins with, and sends it to every card linked from it. Takes no input.",
                settings: [SettingCapability("command", "The message a run begins with.")],
                notes: ["It may carry a schedule the person set. You can't set one, and changing a scheduled Start card's command switches its schedule off until the person turns it back on."])
        case .ifElse:
            CardCapability(.ifElse,
                does: "Checks the message and sends it out yes or no.",
                settings: checkSettings,
                notes: [judgeNote("no")])
        case .switchCard:
            CardCapability(.switchCard,
                does: "Claude picks the one branch that fits the message.",
                outputsNote: "one per branch name, plus other",
                settings: [SettingCapability("branches", ["type": "array", "items": ["type": "string"]], "The branch names. Each one becomes an output.")],
                notes: ["Changing the branches removes links from branches that no longer exist.", judgeNote("other")])
        case .and:
            CardCapability(.and,
                does: "Waits for a message from every card linked into it, then passes them on together.",
                notes: ["Don't feed it from different outputs of one If or Switch card: a message leaves by one output, so it would wait for ever and the run would end with no answer."])
        case .or:
            CardCapability(.or,
                does: "Passes on the first message that reaches it and drops later ones.",
                notes: ["It passes on one message per run. Inside a loop, it passes on one per round: each time a Loop card goes out again, every Or that again leads to passes on the next first message."])
        case .prompt:
            CardCapability(.prompt,
                does: "Rewrites the message from a template.",
                settings: [SettingCapability("template", "The rewritten message. {{message}} becomes the incoming message and {{from}} the name of the agent it came from.")])
        case .loop:
            CardCapability(.loop,
                does: "Checks the message. It goes out done when the check holds or max_tries is used up, and again otherwise.",
                settings: checkSettings + [
                    SettingCapability("max_tries", ["type": "integer", "minimum": 1, "maximum": 50], "Tries before it gives up and takes done. Defaults to 3."),
                ],
                notes: [judgeNote("a failed try"), "Link something to done, or a run that passes its check stops there with no answer. A run whose Loop gave up is recorded as having given up, even if an answer reaches an End card after it."])
        case .end:
            CardCapability(.end,
                does: "Records the final answer, and saves it to a file if save_to is set.",
                settings: [SettingCapability("save_to", "A file to save the final answer to, relative to the project folder. Not inside \(Checks.protectedSaveFolders.joined(separator: ", ")).")])
        case .note:
            CardCapability(.note,
                does: "Text for people. It carries no messages and can't be linked.",
                settings: [SettingCapability("text", "The note's text.")])
        case .approval:
            CardCapability(.approval,
                does: "Holds the message until the person approves or rejects it. They can edit it first.",
                settings: [SettingCapability("text", "What the person should check before approving.")],
                notes: ["Put one before anything that can't be taken back, such as sending an email."])
        case .script:
            CardCapability(.script,
                does: "Runs a shell command in the project folder, with the message on its standard input and in $QB_MESSAGE. It goes out pass when the command exits with 0 and fail otherwise, and what it printed is passed on.",
                settings: [SettingCapability("command", "The shell command to run.")],
                notes: [
                    "The person is asked to allow a command they did not type themselves the first time a run reaches it.",
                    "A command that hasn't finished after \(minutes(scriptTimeout)) minutes is stopped and goes out fail.",
                    "Only the last \(grouped(scriptOutputLimit)) characters of what it printed are passed on.",
                ])
        case .flow:
            CardCapability(.flow,
                does: "Runs another flow in this project as one step, giving it the message as its command. It goes out done with that flow's final answer, or fail.",
                settings: [SettingCapability("flow", "The name of the flow to run, one of other_flows from get_flow.")],
                notes: [
                    "To make a new sub-flow, use create_subflow, which also adds this card. To reuse a flow that exists, set flow to one of the other_flows that get_flow lists. Never write flow files yourself.",
                    "Sub-flows only nest as deep as the person allows on the flow at the top. get_flow gives sub_flow_levels_left: at 0 this flow can't have a Flow card. An edit that would go deeper is refused; don't try to work round it.",
                    "A flow that isn't below yours can only be linked in by the person: ask them.",
                    "A flow has one run at a time. A Flow card that reaches a flow which is already running, from another Flow card or because the person started it, waits for that run to end and then runs it. A Flow card that would run a flow this run is already inside goes out fail.",
                ])
        }
    }

    /// The most hand-offs a run makes, in words.
    public static var runLimit: String {
        "A run hands agents at most \(Engine.maxDeliveries) messages. When the next hand-off would pass that, the run stops there and nothing more is sent. Keep a flow's loops short enough to finish inside it."
    }

    /// What happens when the judge takes too long, for a card whose check it answers.
    private static func judgeNote(_ counts: String) -> String {
        "A judge check that takes longer than \(Int(Engine.judgeTimeout.components.seconds)) seconds counts as \(counts)."
    }

    private static func minutes(_ duration: Duration) -> Int { Int(duration.components.seconds / 60) }

    /// 20000 as "20,000", the same in every language the Mac is set to.
    private static func grouped(_ number: Int) -> String {
        var digits = String(number), out = ""
        while digits.count > 3 {
            out = "," + digits.suffix(3) + out
            digits.removeLast(3)
        }
        return digits + out
    }

    private static let checkSettings = [
        SettingCapability("check", ["type": "string", "enum": .array(CheckKind.allCases.map { .string($0.rawValue) })],
                          "How value is tested. judge: Claude decides whether value, a plain-English statement, is true of the message. contains and not-contains: the message has or lacks the text in value, ignoring case. regex: the message matches the pattern in value."),
        SettingCapability("value", "The statement, text or pattern the check tests."),
    ]

    public static var cards: [CardCapability] { CardKind.allCases.map(card) }

    /// What every agent has, whatever its card's settings.
    public static let everyAgent = [
        "Every agent is a Claude Code session, with Claude Code's own tools: the shell, reading and editing files, and searching and fetching from the web.",
        "It also has whatever the person has set up for their own Claude Code, such as connectors to their mail or calendar. Queen Bee can't list those. If a flow depends on one, ask that agent with SendMessage whether it has it before you build on it.",
        "An agent can use SendMessage to ask a question of an agent its card is linked to, or of the orchestrator.",
    ]

    /// Which kinds each setting belongs to, in the order the kinds are declared.
    public static var settingKinds: [(key: String, kinds: [CardKind])] {
        var order: [String] = []
        var kinds: [String: [CardKind]] = [:]
        for card in cards {
            for setting in card.settings {
                if kinds[setting.key] == nil { order.append(setting.key) }
                kinds[setting.key, default: []].append(card.kind)
            }
        }
        return order.map { ($0, kinds[$0] ?? []) }
    }

    /// The settings as the orchestrator's tools take them: one entry per key, saying what it means on each
    /// kind of card that has it.
    public static var settingSchemas: [String: JSONValue] {
        var schemas: [String: JSONValue] = [:]
        for (key, kinds) in settingKinds {
            var fields = card(kinds[0]).settings.first { $0.key == key }?.schema.objectValue ?? [:]
            let about = kinds.compactMap { kind in card(kind).settings.first { $0.key == key }.map { "\(kind.rawValue): \($0.about)" } }
            fields["description"] = .string(about.joined(separator: " "))
            schemas[key] = .object(fields)
        }
        return schemas
    }

    /// Each kind with its outputs on one line, for the tools that need the names to hand.
    public static var outputsLine: String {
        cards.map { "\($0.kind.rawValue) (\($0.outputs))" }.joined(separator: "; ")
    }

    /// The whole reference, as Markdown. This is what the orchestrator is given when its session starts, and
    /// what `CAPABILITIES.md` holds.
    public static var reference: String {
        var lines: [String] = ["# What Queen Bee can do", ""]
        lines.append("This is what the app can do as it is now. Build with these and nothing else: a card, setting or tool that isn't here doesn't exist.")
        lines += ["", "## Cards", ""]
        for card in cards {
            let made = Card.make(kind: card.kind, name: card.kind.label, x: 0, y: 0)
            lines.append("### \(card.kind.label) (`\(card.kind.rawValue)`)")
            lines.append(card.does)
            lines.append("- Outputs: \(card.outputs)")
            lines.append("- Input: \(acceptsInput(made) ? "yes" : "none")")
            lines.append("- Size when added: \(Int(made.width)) by \(Int(made.height)) points")
            for setting in card.settings {
                lines.append("- Setting `\(setting.key)` (\(typeName(setting.schema))): \(setting.about)")
            }
            lines += card.notes.map { "- \($0)" }
            lines.append("")
        }
        lines += ["## Links", ""]
        lines.append("- A link joins one card's output to another card's input. A card can't link to itself.")
        lines.append("- Each link has max passes, from \(Link.maxPassesRange.lowerBound) to \(Link.maxPassesRange.upperBound) and \(Link.defaultMaxPasses) unless set: how many times it may fire in one run. That is what makes a loop between cards end.")
        lines += ["", "## Runs", ""]
        lines.append("- \(runLimit)")
        lines.append("- A run ends when nothing is left to do. The person sees how it ended: finished with an answer, ended without an answer, gave up (a Loop ran out of tries), stopped at the hand-off limit, failed, or stopped.")
        lines.append("- An agent the run isn't waiting on can be restarted, or stop, without stopping the run. If the run is waiting on it, the run stops.")
        lines += ["", "## Every agent", ""]
        lines += everyAgent.map { "- \($0)" }
        lines += ["", "## An agent with a browser", ""]
        lines.append("With `browser` on, an agent has exactly these browser tools and no others:")
        for tool in BrowserTools.definitions {
            let asks = BrowserTools.lookingTools.contains(tool.name) ? "never asks the person" : "asks the person first, unless the agent's permission mode lets it through"
            lines.append("- `\(tool.name)` (\(asks)): \(tool.description)")
        }
        lines.append("")
        lines.append("What the browser can't do:")
        lines += BrowserTools.limits.map { "- \($0)" }
        lines += ["", "## Your tools", ""]
        lines.append("The orchestrator builds and runs a flow with: \(Tools.definitions.map { "`\($0.name)`" }.joined(separator: ", ")). Each one's own description says how to call it.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Where the app keeps a copy of the reference in each project, for the orchestrator to read.
    public static let projectFile = ".queenbee/CAPABILITIES.md"

    /// The reference as it is saved in the repository, with a note on where it comes from.
    public static var file: String {
        "<!-- Written by ./scripts/build.sh from Core/Sources/QueenBeeCore/Capabilities.swift. Don't edit this file: change that one. -->\n\n" + reference
    }

    private static func typeName(_ schema: JSONValue) -> String {
        if let choices = schema["enum"]?.arrayValue { return choices.compactMap(\.stringValue).joined(separator: " | ") }
        switch schema["type"]?.stringValue {
        case "boolean": return "true or false"
        case "integer":
            if let low = schema["minimum"]?.intValue, let high = schema["maximum"]?.intValue { return "whole number, \(low) to \(high)" }
            return "whole number"
        case "array": return "list of text"
        default: return "text"
        }
    }
}
