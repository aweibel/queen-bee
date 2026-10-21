import Foundation

/// What the app knows about an agent's session.
public struct AgentStatus: Codable, Equatable, Sendable {
    /// starting, idle, working, needs you, failed or exited.
    public var state: String
    public var lastReply: String?

    public init(state: String, lastReply: String?) { self.state = state; self.lastReply = lastReply }
}

/// The flow as it is right now, with each agent's status keyed by card id.
public struct FlowSnapshot: Sendable {
    public var flow: Flow
    public var agents: [String: AgentStatus]
    public var isRunning: Bool
    /// The names of the project's other flows that a Flow card here may run.
    public var otherFlows: [String]
    /// How many more levels of sub-flow may sit below this flow, by the limit the person set on the flow at the top.
    public var subflowLevelsLeft: Int
    /// The sub-flows below this flow, outermost first, each with how many levels down it sits.
    public var subflows: [(name: String, depth: Int)]
    /// The name of the flow each Flow card runs, by card id. A card that runs nothing is absent.
    public var innerFlowNames: [String: String]
    /// Start cards whose schedule the person has turned on.
    public var armedStartIDs: Set<String>
    /// Warnings the app adds to the wiring warnings, by card id.
    public var extraWarnings: [String: String]

    public init(flow: Flow, agents: [String: AgentStatus], isRunning: Bool, otherFlows: [String] = [], subflowLevelsLeft: Int = 3,
                subflows: [(name: String, depth: Int)] = [], innerFlowNames: [String: String] = [:],
                armedStartIDs: Set<String> = [], extraWarnings: [String: String] = [:]) {
        self.flow = flow; self.agents = agents; self.isRunning = isRunning; self.otherFlows = otherFlows
        self.subflowLevelsLeft = subflowLevelsLeft; self.subflows = subflows; self.innerFlowNames = innerFlowNames
        self.armedStartIDs = armedStartIDs; self.extraWarnings = extraWarnings
    }
}

/// What the orchestrator's tools need from the app. Edits go through `mutate`, the same path the canvas uses,
/// so the canvas updates when the orchestrator changes the flow.
public protocol ToolHost: Sendable {
    func snapshot() async -> FlowSnapshot
    func mutate<T: Sendable>(_ body: @Sendable (inout Flow) throws -> T) async throws -> T
    /// Starts a run and returns a short status line.
    func runFlow(command: String?) async throws -> String
    func stopFlow() async
    func runLog() async -> [String]
    /// The same tools for one of the sub-flows below this flow, by its name. A flow above or beside this one is refused.
    func subflowHost(named name: String) async throws -> any ToolHost
    /// Makes a new sub-flow below this flow and a Flow card that runs it, or fills the Flow card named. Returns what was made.
    func createSubflow(name: String?, card: String?) async throws -> String
}



public struct ToolDefinition: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

public struct ToolResult: Equatable, Sendable {
    public let text: String
    public let isError: Bool
    /// A PNG picture that goes back with the text, in base64. Nil for most tools.
    public let image: String?

    public init(text: String, isError: Bool, image: String? = nil) { self.text = text; self.isError = isError; self.image = image }
}

/// The tools the orchestrator session builds and runs a flow with.
public enum Tools {
    public static func call(name: String, arguments: JSONValue, host: any ToolHost) async -> ToolResult {
        var values = arguments.objectValue ?? [:]
        do {
            // A call can be aimed at a sub-flow below this one. It then runs there, by that flow's rules.
            var host = host
            if let inner = values.removeValue(forKey: "in_flow")?.stringValue, !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                host = try await host.subflowHost(named: inner)
            }
            return ToolResult(text: try await run(name, Arguments(values: values), host), isError: false)
        } catch let error as FlowError {
            return ToolResult(text: error.description, isError: true)
        } catch {
            // The host's own errors, for example from run_flow.
            return ToolResult(text: (error as? LocalizedError)?.errorDescription ?? String(describing: error), isError: true)
        }
    }

    private static func run(_ name: String, _ arguments: Arguments, _ host: any ToolHost) async throws -> String {
        switch name {
        case "get_flow":
            return describe(await host.snapshot()).text()

        case "add_card":
            let raw = try arguments.required("kind")
            guard let kind = CardKind(rawValue: raw.lowercased()) else {
                throw FlowError.invalid("Unknown card kind \"\(raw)\". Use one of: \(CardKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let patch = try arguments.patch(for: kind)
            let name = try arguments.string("name")
            let card = try await host.mutate { try $0.addCard(kind: kind, name: name, patch: patch, clearOfOthers: true) }
            let outputs = ports(of: card)
            let tail = outputs.isEmpty ? "It has no outputs." : "Outputs: \(outputs.joined(separator: ", "))."
            return "Added \(card.kind.label) \"\(card.name)\" (id \(card.id)) at x \(Int(card.x)), y \(Int(card.y)), \(Int(card.width)) wide. \(tail)"

        case "update_card":
            let ref = try arguments.required("card")
            let card = try await host.mutate { flow in
                guard let current = flow.resolveCard(ref) else { throw FlowError.notFound("No card called \"\(ref)\"") }
                let patch = try arguments.patch(for: current.kind)
                if patch == CardPatch() { throw FlowError.invalid("Give at least one setting to change") }
                return try flow.updateCard(current.id, patch: patch)
            }
            return "Updated \(card.kind.label) \"\(card.name)\"."

        case "remove_card":
            let ref = try arguments.required("card")
            let (card, dropped) = try await host.mutate { flow in
                guard let card = flow.resolveCard(ref) else { throw FlowError.notFound("No card called \"\(ref)\"") }
                let before = flow.links.count
                try flow.removeCard(card.id)
                return (card, before - flow.links.count)
            }
            return "Removed \(card.kind.label) \"\(card.name)\" and \(dropped) \(dropped == 1 ? "link" : "links")."

        case "add_link":
            let from = try arguments.required("from")
            let to = try arguments.required("to")
            let port = try arguments.string("port")
            let passes = try arguments.int("max_passes")
            let (link, source, target) = try await host.mutate { flow in
                let link = try flow.addLink(from: from, port: port, to: to, maxPasses: passes)
                return (link, flow.card(link.from)?.name ?? from, flow.card(link.to)?.name ?? to)
            }
            return "Linked \"\(source)\" (\(link.port)) to \"\(target)\" (link id \(link.id), max passes \(link.maxPasses))."

        case "remove_link":
            let id = try arguments.required("link")
            try await host.mutate { try $0.removeLink(id) }
            return "Removed link \(id)."

        case "update_flow":
            guard let given = try arguments.number("spending_limit") else { throw FlowError.invalid("Give at least one setting to change") }
            let limit = SpendingLimit.clamped(given)
            try await host.mutate { $0.spendingLimit = limit }
            return limit.map { "Runs of this flow now stop once they have spent more than \(Usage(cost: $0).price)." } ?? "This flow's runs have no spending limit now."

        case "run_flow":
            return try await host.runFlow(command: try arguments.string("command"))

        case "stop_flow":
            guard await host.snapshot().isRunning else { return "No run is going." }
            await host.stopFlow()
            return "Stopped the run."

        case "read_agent":
            let ref = try arguments.required("card")
            let snapshot = await host.snapshot()
            guard let card = snapshot.flow.resolveCard(ref) else { throw FlowError.notFound("No card called \"\(ref)\"") }
            guard card.kind == .agent else {
                throw FlowError.invalid("\"\(card.name)\" is a \(card.kind.label) card, not an agent")
            }
            let status = snapshot.agents[card.id]
            let state = "\(card.name) is \(status?.state ?? "not started")."
            guard let reply = status?.lastReply, !reply.isEmpty else { return "\(state) It has not replied yet." }
            return "\(state) Its last reply:\n\n\(reply)"

        case "create_subflow":
            return try await host.createSubflow(name: try arguments.string("name"), card: try arguments.string("card"))

        case "get_run_log":
            let lines = await host.runLog()
            return lines.isEmpty ? "No run has been logged yet." : lines.joined(separator: "\n")

        default:
            throw FlowError.notFound("Unknown tool \"\(name)\"")
        }
    }

    // MARK: get_flow

    /// Built field by field rather than encoded from `Flow`, so session ids can never leak into it.
    private static func describe(_ snapshot: FlowSnapshot) -> JSONValue {
        let flow = snapshot.flow
        let found = warnings(for: flow).merging(snapshot.extraWarnings) { own, _ in own }
        func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

        let cards = flow.cards.map { card -> JSONValue in
            var fields: [String: JSONValue] = [
                "id": .string(card.id), "kind": .string(card.kind.rawValue), "name": .string(card.name),
                "x": .number(card.x), "y": .number(card.y), "width": .number(card.width), "height": .number(card.height),
                "outputs": .array(ports(of: card).map(JSONValue.string)),
            ]
            switch card.kind {
            case .agent:
                fields["instructions"] = text(card.instructions)
                fields["model"] = text(card.model)
                fields["effort"] = text(card.effort)
                fields["permission_mode"] = text(card.permissionMode)
                fields["cwd"] = text(card.cwd)
                fields["browser"] = .bool(card.browser == true)
                let status = snapshot.agents[card.id]
                fields["state"] = .string(status?.state ?? "not started")
                fields["has_last_reply"] = .bool(!(status?.lastReply ?? "").isEmpty)
            case .start, .script:
                fields["command"] = text(card.command)
                if card.kind == .script { fields["wait_minutes"] = .number(Double(card.waitMinutes ?? 0)) }
                if card.kind == .start, let trigger = card.trigger {
                    fields["schedule"] = .string(trigger.summary)
                    fields["schedule_on"] = .bool(snapshot.armedStartIDs.contains(card.id))
                }
            case .ifElse, .loop:
                fields["check"] = text(card.check?.rawValue)
                fields["value"] = text(card.value)
                if card.kind == .loop { fields["max_tries"] = card.maxTries.map { .number(Double($0)) } ?? .null }
            case .switchCard:
                fields["branches"] = .array((card.branches ?? []).map(JSONValue.string))
            case .prompt:
                fields["template"] = text(card.template)
            case .end:
                fields["save_to"] = text(card.saveTo)
            case .note, .approval:
                fields["text"] = text(card.text)
                if card.kind == .approval {
                    fields["wait_minutes"] = .number(Double(card.waitMinutes ?? 0))
                    fields["when_no_answer"] = .string(card.whenNoAnswer ?? "rejected")
                }
            case .forEach:
                fields["split"] = .string((card.split ?? .auto).rawValue)
                fields["max_items"] = .number(Double(card.maxItems ?? Engine.defaultItems))
            case .flow:
                fields["flow"] = text(snapshot.innerFlowNames[card.id])
            case .and, .or:
                break
            }
            if let warning = found[card.id] { fields["warning"] = .string(warning) }
            return .object(fields)
        }

        let links = flow.links.map { link -> JSONValue in
            [
                "id": .string(link.id),
                "from": .string(flow.card(link.from)?.name ?? link.from),
                "port": .string(link.port),
                "to": .string(flow.card(link.to)?.name ?? link.to),
                "max_passes": .number(Double(link.maxPasses)),
            ]
        }

        return ["name": .string(flow.name), "is_running": .bool(snapshot.isRunning), "cards": .array(cards), "links": .array(links),
                "spending_limit": flow.spendingLimit.map { .number($0) } ?? .null,
                "other_flows": .array(snapshot.otherFlows.map(JSONValue.string)),
                "sub_flow_levels_left": .number(Double(max(0, snapshot.subflowLevelsLeft))),
                "sub_flows": .array(snapshot.subflows.map { ["name": .string($0.name), "levels_down": .number(Double($0.depth + 1))] })]
    }

    // MARK: Definitions

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "get_flow",
            description: """
            Read the flow on the canvas: its cards, their settings and positions, each card's outputs, each agent's \
            state, the links between cards, and whether a run is going. A card with a "warning" is wired in a way \
            that would leave a run stuck. Call this before editing, because the person can change the canvas by hand.
            """,
            inputSchema: schema([:])),
        ToolDefinition(
            name: "add_card",
            description: """
            Add a card to the flow. What each kind does, its settings and its limits are in the capabilities \
            reference, \(Capabilities.projectFile) in the project folder. The kinds, with their outputs: \(Capabilities.outputsLine). \
            Only pass the settings that belong to the kind. Leave out x and y to place the card to the right of the \
            others, which is usually what you want. If you do give positions, leave 60 points between cards: the \
            reference gives each kind's size. A card that \
            would land on another is moved right until it is clear. Returns the new card's id, position and \
            outputs. Then connect it with add_link.
            """,
            inputSchema: schema(
                ["kind": ["type": "string", "enum": .array(CardKind.allCases.map { .string($0.rawValue) })],
                 "name": ["type": "string", "description": "Shown on the card and used to refer to it. Must be unique in the flow. Defaults to the kind's label."],
                 "x": ["type": "number", "description": "Left edge on the canvas, in points."],
                 "y": ["type": "number", "description": "Top edge on the canvas, in points."]],
                required: ["kind"], withSettings: true)),
        ToolDefinition(
            name: "update_card",
            description: """
            Change a card's name, position, size or settings. Pass only what should change. A setting that does not \
            belong to the card's kind is refused. Changing a switch's branches removes links from branches that no \
            longer exist. New agent settings (instructions, model, effort, permission_mode, cwd, browser) apply the next \
            time that agent's session starts.
            """,
            inputSchema: schema(
                ["card": cardProperty,
                 "name": ["type": "string", "description": "A new name. Must be unique in the flow."],
                 "x": ["type": "number"], "y": ["type": "number"],
                 "width": ["type": "number"], "height": ["type": "number"]],
                required: ["card"], withSettings: true)),
        ToolDefinition(
            name: "remove_card",
            description: "Remove a card and every link into and out of it.",
            inputSchema: schema(["card": cardProperty], required: ["card"])),
        ToolDefinition(
            name: "add_link",
            description: """
            Link one card's output to another card's input, so messages travel that way during a run. The kinds, \
            with their outputs: \(Capabilities.outputsLine). Leave port out to use the card's first output. Start and note cards take no \
            input, end and note cards have no outputs, and a card cannot link to itself. max_passes is how many \
            times the link may fire in one run, which is what makes a loop between cards end.
            """,
            inputSchema: schema(
                ["from": ["type": "string", "description": "The card the link leaves: its name or id."],
                 "to": ["type": "string", "description": "The card the link goes to: its name or id."],
                 "port": ["type": "string", "description": "Which output of the from card. Defaults to its first."],
                 "max_passes": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Defaults to 3."]],
                required: ["from", "to"])),
        ToolDefinition(
            name: "remove_link",
            description: "Remove a link by its id. Link ids are listed by get_flow and returned by add_link.",
            inputSchema: schema(["link": ["type": "string", "description": "The link's id."]], required: ["link"])),
        ToolDefinition(
            name: "update_flow",
            description: """
            Change the flow's own settings, not a card's. What each one does is under "Flow settings" in the \
            capabilities reference. Pass only what should change.
            """,
            inputSchema: schema(Capabilities.flowSettingSchemas)),
        ToolDefinition(
            name: "run_flow",
            description: """
            Start a run from the flow's Start card. The command goes to every card linked from Start, and each \
            agent's reply then travels its links. Pass command to use it in place of the Start card's own command \
            for this run. Only one run can go at a time. This returns once the run has started, not when it ends: \
            follow it with get_run_log and read_agent.
            """,
            inputSchema: schema(["command": ["type": "string", "description": "What to send in place of the Start card's command."]])),
        ToolDefinition(
            name: "stop_flow",
            description: "Stop the run that is going. Agents finish the turn they are on, but their replies are no longer passed along.",
            inputSchema: schema([:])),
        ToolDefinition(
            name: "read_agent",
            description: "Read an agent card's state (starting, idle, working, needs you, failed or exited) and the full text of its last reply.",
            inputSchema: schema(["card": cardProperty], required: ["card"])),
        ToolDefinition(
            name: "create_subflow",
            description: """
            Make a new sub-flow below this flow, with an Input card and an Output card ready, and a Flow card here \
            that runs it. Then build inside it by passing in_flow with its name to add_card, add_link and the other \
            tools. The message the Flow card receives arrives at the sub-flow's Input, and what reaches its Output \
            comes back out the Flow card's done output. Pass card to fill a Flow card that is already on the canvas \
            and has no flow yet. You can make sub-flows below this flow and below its sub-flows, never above or \
            beside it. If this is refused because the sub-flow limit is reached, do not try another way: tell the \
            person no more sub-flows can be added at this level and that the limit is in the top flow's settings.
            """,
            inputSchema: schema([
                "name": ["type": "string", "description": "What to call the sub-flow, and the Flow card that runs it."],
                "card": ["type": "string", "description": "A Flow card already here to fill, by name or id. Leave out to add one."],
            ])),
        ToolDefinition(
            name: "get_run_log",
            description: "Read the log of the latest run: each hand-off between cards, each If, Switch and Loop decision, and why the run stopped.",
            inputSchema: schema([:])),
    ]

    private static let cardProperty: JSONValue = ["type": "string", "description": "The card's name or id."]

    private static let settingProperties = Capabilities.settingSchemas

    private static func schema(_ properties: [String: JSONValue], required: [String] = [], withSettings: Bool = false) -> JSONValue {
        var all = withSettings ? properties.merging(settingProperties) { own, _ in own } : properties
        // Every tool can be aimed at a sub-flow below the orchestrator's own flow.
        all["in_flow"] = ["type": "string", "description": "Leave out to act on your own flow. To act on a sub-flow below it, give that sub-flow's name, one of sub_flows from get_flow."]
        return ["type": "object", "properties": .object(all), "required": .array(required.map(JSONValue.string))]
    }
}

/// A tool call's arguments, read with errors the orchestrator can act on.
private struct Arguments: Sendable {
    let values: [String: JSONValue]

    /// Which kinds each setting belongs to. A setting passed for another kind is refused rather than dropped,
    /// so the orchestrator finds out instead of believing the change was made.
    private static let settings = Capabilities.settingKinds

    private func value(_ key: String) -> JSONValue? {
        guard let value = values[key], !value.isNull else { return nil }
        return value
    }

    func string(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let text = value.stringValue else { throw FlowError.invalid("\"\(key)\" must be text") }
        return text
    }

    func required(_ key: String) throws -> String {
        guard let text = try string(key), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlowError.invalid("\"\(key)\" is required")
        }
        return text
    }

    func number(_ key: String) throws -> Double? {
        guard let value = value(key) else { return nil }
        // Models sometimes quote numbers.
        if let number = value.doubleValue ?? value.stringValue.flatMap(Double.init), number.isFinite { return number }
        throw FlowError.invalid("\"\(key)\" must be a number")
    }

    func int(_ key: String) throws -> Int? {
        guard let number = try number(key) else { return nil }
        guard abs(number) < 1e9 else { throw FlowError.invalid("\"\(key)\" is out of range") }
        return Int(number)
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        // Models sometimes quote these too.
        if let flag = value.boolValue ?? value.stringValue.flatMap({ Bool($0.lowercased()) }) { return flag }
        throw FlowError.invalid("\"\(key)\" must be true or false")
    }

    func strings(_ key: String) throws -> [String]? {
        guard let value = value(key) else { return nil }
        guard let items = value.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
            throw FlowError.invalid("\"\(key)\" must be a list of text")
        }
        return items.compactMap(\.stringValue)
    }

    /// The name, position, size and settings in the arguments, as a patch for a card of `kind`.
    func patch(for kind: CardKind) throws -> CardPatch {
        for setting in Self.settings where value(setting.key) != nil && !setting.kinds.contains(kind) {
            let article = "aeiou".contains(kind.label.lowercased().prefix(1)) ? "An" : "A"
            throw FlowError.invalid("\(article) \(kind.label) card has no \"\(setting.key)\" setting")
        }
        var patch = CardPatch()
        patch.name = try string("name")
        patch.x = try number("x")
        patch.y = try number("y")
        patch.width = try number("width")
        patch.height = try number("height")
        patch.instructions = try string("instructions")
        patch.model = try string("model")
        patch.effort = try string("effort")
        patch.permissionMode = try string("permission_mode")
        patch.cwd = try string("cwd")
        patch.browser = try bool("browser")
        patch.command = try string("command")
        patch.flowRef = try string("flow")
        if let raw = try string("check") {
            guard let check = CheckKind(rawValue: raw.lowercased()) else {
                throw FlowError.invalid("Unknown check \"\(raw)\". Use one of: \(CheckKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            patch.check = check
        }
        patch.value = try string("value")
        patch.maxTries = try int("max_tries")
        patch.waitMinutes = try int("wait_minutes")
        patch.whenNoAnswer = try string("when_no_answer")
        if let raw = try string("split") {
            guard let split = ItemSplit(rawValue: raw.lowercased()) else {
                throw FlowError.invalid("Unknown split \"\(raw)\". Use one of: \(ItemSplit.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            patch.split = split
        }
        patch.maxItems = try int("max_items")
        patch.branches = try strings("branches")
        patch.template = try string("template")
        patch.saveTo = try string("save_to")
        patch.text = try string("text")
        return patch
    }
}
