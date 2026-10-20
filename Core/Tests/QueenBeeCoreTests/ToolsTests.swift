import Foundation
import Testing
@testable import QueenBeeCore

/// Stands in for the app: holds a flow and records what the tools asked of it.
actor FakeHost: ToolHost {
    struct Refused: Error, CustomStringConvertible { let description: String }

    var flow: Flow
    var agents: [String: AgentStatus] = [:]
    var running = false
    var log: [String] = []
    var runError: String?
    private(set) var commands: [String?] = []
    private(set) var stops = 0

    init(flow: Flow = Flow(name: "Review")) { self.flow = flow }

    func subflowHost(named name: String) async throws -> any ToolHost { throw FlowError.notFound("No sub-flow called \"\(name)\"") }
    func createSubflow(name: String?, card: String?) async throws -> String { throw FlowError.invalid("Not here") }

    func set(agent id: String, _ status: AgentStatus) { agents[id] = status }
    func set(running: Bool) { self.running = running }
    func set(log: [String]) { self.log = log }
    func set(runError: String?) { self.runError = runError }

    func snapshot() async -> FlowSnapshot { FlowSnapshot(flow: flow, agents: agents, isRunning: running) }

    func mutate<T: Sendable>(_ body: @Sendable (inout Flow) throws -> T) async throws -> T {
        var edited = flow
        let result = try body(&edited)
        flow = edited
        return result
    }

    func runFlow(command: String?) async throws -> String {
        if let runError { throw Refused(description: runError) }
        commands.append(command)
        running = true
        return "Run started"
    }

    func stopFlow() async { stops += 1; running = false }
    func runLog() async -> [String] { log }
}

@Suite struct ToolsTests {
    /// Start → Writer → Approved? with Yes → Done and No → Writer.
    private func sample() throws -> Flow {
        var flow = Flow(name: "Review")
        var patch = CardPatch()
        patch.command = "Write a haiku"
        try flow.addCard(kind: .start, name: "Start", patch: patch)
        patch = CardPatch()
        patch.instructions = "You write haiku"; patch.model = "opus"
        try flow.addCard(kind: .agent, name: "Writer", patch: patch)
        patch = CardPatch()
        patch.check = .contains; patch.value = "APPROVED"
        try flow.addCard(kind: .ifElse, name: "Approved?", patch: patch)
        try flow.addCard(kind: .end, name: "Done")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "Approved?")
        try flow.addLink(from: "Approved?", port: "yes", to: "Done")
        try flow.addLink(from: "Approved?", port: "no", to: "Writer", maxPasses: 5)
        return flow
    }

    @Test func everyToolIsDefinedWithAnObjectSchema() {
        #expect(Tools.definitions.map(\.name) == [
            "get_flow", "add_card", "update_card", "remove_card", "add_link", "remove_link",
            "update_flow", "run_flow", "stop_flow", "read_agent", "create_subflow", "get_run_log",
        ])
        for tool in Tools.definitions {
            #expect(!tool.description.isEmpty)
            #expect(tool.inputSchema["type"] == "object")
            #expect(tool.inputSchema["properties"]?.objectValue != nil)
            #expect(tool.inputSchema["required"]?.arrayValue != nil)
            #expect(!tool.description.contains("—"))
        }
        func required(_ name: String) -> JSONValue? { Tools.definitions.first { $0.name == name }?.inputSchema["required"] }
        #expect(required("add_card") == ["kind"])
        #expect(required("update_card") == ["card"])
        #expect(required("add_link") == ["from", "to"])
        #expect(required("run_flow") == [])
        let kinds = Tools.definitions[1].inputSchema["properties"]?["kind"]?["enum"]
        #expect(kinds == .array(CardKind.allCases.map { .string($0.rawValue) }))
    }

    @Test func getFlowDescribesCardsLinksAndAgents() async throws {
        var flow = try sample()
        let writer = try #require(flow.resolveCard("Writer"))
        let index = try #require(flow.cards.firstIndex { $0.id == writer.id })
        flow.cards[index].sessionID = "SECRET-SESSION"
        flow.orchestratorSessionID = "SECRET-ORCHESTRATOR"
        let host = FakeHost(flow: flow)
        await host.set(agent: writer.id, AgentStatus(state: "working", lastReply: "Old pond"))
        await host.set(running: true)

        let result = await Tools.call(name: "get_flow", arguments: [:], host: host)
        #expect(!result.isError)
        #expect(!result.text.contains("SECRET"))
        let json = try JSONValue.parse(Data(result.text.utf8))
        #expect(json["name"] == "Review")
        #expect(json["is_running"] == true)

        let cards = try #require(json["cards"]?.arrayValue)
        #expect(cards.map { $0["name"] } == ["Start", "Writer", "Approved?", "Done"])
        #expect(cards.map { $0["kind"] } == ["start", "agent", "if", "end"])
        #expect(cards[0]["command"] == "Write a haiku")
        #expect(cards[0]["outputs"] == ["out"])
        #expect(cards[1]["id"] == .string(writer.id))
        #expect(cards[1]["instructions"] == "You write haiku")
        #expect(cards[1]["model"] == "opus")
        #expect(cards[1]["state"] == "working")
        #expect(cards[1]["has_last_reply"] == true)
        #expect(cards[1]["width"] == .number(writer.width))
        #expect(cards[2]["check"] == "contains")
        #expect(cards[2]["value"] == "APPROVED")
        #expect(cards[2]["outputs"] == ["yes", "no"])
        #expect(cards[3]["outputs"] == [])
        #expect(cards.allSatisfy { $0["warning"] == nil })

        let links = try #require(json["links"]?.arrayValue)
        #expect(links.count == 4)
        #expect(links[3]["from"] == "Approved?")
        #expect(links[3]["port"] == "no")
        #expect(links[3]["to"] == "Writer")
        #expect(links[3]["max_passes"] == 5)
        #expect(links[3]["id"] == .string(flow.links[3].id))
    }

    @Test func getFlowShowsWarnings() async throws {
        var flow = Flow(name: "Half built")
        try flow.addCard(kind: .start, name: "Start")
        let host = FakeHost(flow: flow)
        let json = try JSONValue.parse(Data(await Tools.call(name: "get_flow", arguments: [:], host: host).text.utf8))
        #expect(json["cards"]?.arrayValue?.first?["warning"] == "Link it to an agent")
        #expect(json["is_running"] == false)
    }

    @Test func addCardTakesAKindAndItsSettings() async throws {
        let host = FakeHost()
        let agent = await Tools.call(name: "add_card", arguments: [
            "kind": "agent", "name": "Writer", "x": 100, "y": 200,
            "instructions": "You write haiku", "model": "opus", "effort": "high", "permission_mode": "plan", "cwd": "/tmp/work",
        ], host: host)
        #expect(!agent.isError)
        var card = try #require(await host.flow.resolveCard("Writer"))
        #expect(agent.text.contains(card.id) && agent.text.contains("Writer"))
        #expect(card.kind == .agent && card.x == 100 && card.y == 200)
        #expect(card.instructions == "You write haiku" && card.model == "opus" && card.effort == "high")
        #expect(card.permissionMode == "plan" && card.cwd == "/tmp/work")

        // The browser switch is an agent setting, and get_flow reports it.
        #expect(card.browser == nil)
        let switched = await Tools.call(name: "update_card", arguments: ["card": "Writer", "browser": true], host: host)
        #expect(!switched.isError)
        #expect(await host.flow.resolveCard("Writer")?.browser == true)
        let seen = try JSONValue.parse(Data(await Tools.call(name: "get_flow", arguments: [:], host: host).text.utf8))
        #expect(seen["cards"]?.arrayValue?.first?["browser"] == true)
        let wrongKind = await Tools.call(name: "add_card", arguments: ["kind": "note", "browser": true], host: host)
        #expect(wrongKind.isError && wrongKind.text.contains("browser"))
        let notAFlag = await Tools.call(name: "update_card", arguments: ["card": "Writer", "browser": "maybe"], host: host)
        #expect(notAFlag.isError)

        _ = await Tools.call(name: "add_card", arguments: ["kind": "loop", "name": "Polish", "check": "not-contains", "value": "TODO", "max_tries": 5], host: host)
        card = try #require(await host.flow.resolveCard("Polish"))
        #expect(card.check == .notContains && card.value == "TODO" && card.maxTries == 5)

        _ = await Tools.call(name: "add_card", arguments: ["kind": "switch", "branches": ["bug", "feature"]], host: host)
        card = try #require(await host.flow.resolveCard("Switch"))
        #expect(card.branches == ["bug", "feature"])

        _ = await Tools.call(name: "add_card", arguments: ["kind": "prompt", "name": "Brief", "template": "Review: {{message}}"], host: host)
        #expect(await host.flow.resolveCard("Brief")?.template == "Review: {{message}}")
        _ = await Tools.call(name: "add_card", arguments: ["kind": "end", "name": "Done", "save_to": "out.md"], host: host)
        #expect(await host.flow.resolveCard("Done")?.saveTo == "out.md")
        _ = await Tools.call(name: "add_card", arguments: ["kind": "note", "name": "Memo", "text": "Hello"], host: host)
        #expect(await host.flow.resolveCard("Memo")?.text == "Hello")
        _ = await Tools.call(name: "add_card", arguments: ["kind": "start", "command": "Go"], host: host)
        #expect(await host.flow.resolveCard("Start")?.command == "Go")
        #expect(await host.flow.cards.count == 7)
    }

    @Test func addCardRefusesBadInput() async throws {
        let host = FakeHost()
        let noKind = await Tools.call(name: "add_card", arguments: ["name": "Writer"], host: host)
        #expect(noKind.isError)
        let badKind = await Tools.call(name: "add_card", arguments: ["kind": "robot"], host: host)
        #expect(badKind.isError && badKind.text.contains("robot") && badKind.text.contains("agent"))
        let wrongSetting = await Tools.call(name: "add_card", arguments: ["kind": "and", "command": "Go"], host: host)
        #expect(wrongSetting.isError && wrongSetting.text.contains("command"))
        let wrongType = await Tools.call(name: "add_card", arguments: ["kind": "agent", "x": "left"], host: host)
        #expect(wrongType.isError && wrongType.text.contains("x"))
        let badCheck = await Tools.call(name: "add_card", arguments: ["kind": "if", "check": "vibes"], host: host)
        #expect(badCheck.isError && badCheck.text.contains("vibes"))
        #expect(await host.flow.cards.isEmpty)

        _ = await Tools.call(name: "add_card", arguments: ["kind": "agent", "name": "Writer"], host: host)
        let duplicate = await Tools.call(name: "add_card", arguments: ["kind": "agent", "name": "writer"], host: host)
        #expect(duplicate == ToolResult(text: "Another card is already called \"writer\"", isError: true))
    }

    @Test func updateCardChangesSettingsByNameOrID() async throws {
        let host = FakeHost(flow: try sample())
        let renamed = await Tools.call(name: "update_card", arguments: ["card": "writer", "name": "Poet", "model": "", "width": 700], host: host)
        #expect(!renamed.isError)
        let poet = try #require(await host.flow.resolveCard("Poet"))
        #expect(poet.model == nil && poet.width == 700)

        let byID = await Tools.call(name: "update_card", arguments: ["card": .string(poet.id), "instructions": "Write limericks"], host: host)
        #expect(!byID.isError)
        #expect(await host.flow.resolveCard("Poet")?.instructions == "Write limericks")

        let missing = await Tools.call(name: "update_card", arguments: ["card": "Ghost", "name": "Casper"], host: host)
        #expect(missing == ToolResult(text: "No card called \"Ghost\"", isError: true))
        let wrongKind = await Tools.call(name: "update_card", arguments: ["card": "Poet", "command": "Go"], host: host)
        #expect(wrongKind.isError && wrongKind.text.contains("command"))
        let nothing = await Tools.call(name: "update_card", arguments: ["card": "Poet"], host: host)
        #expect(nothing.isError)
        let noCard = await Tools.call(name: "update_card", arguments: ["name": "Poet"], host: host)
        #expect(noCard.isError)
    }

    @Test func removeCardTakesItsLinksWithIt() async throws {
        let host = FakeHost(flow: try sample())
        let removed = await Tools.call(name: "remove_card", arguments: ["card": "Writer"], host: host)
        #expect(!removed.isError)
        #expect(await host.flow.resolveCard("Writer") == nil)
        #expect(await host.flow.links.count == 1)
        let again = await Tools.call(name: "remove_card", arguments: ["card": "Writer"], host: host)
        #expect(again == ToolResult(text: "No card called \"Writer\"", isError: true))
    }

    @Test func addLinkAndRemoveLink() async throws {
        var flow = try sample()
        try flow.addCard(kind: .agent, name: "Reviewer")
        let host = FakeHost(flow: flow)

        let added = await Tools.call(name: "add_link", arguments: ["from": "Writer", "to": "Reviewer", "max_passes": 7], host: host)
        #expect(!added.isError)
        let link = try #require(await host.flow.links.last)
        #expect(link.port == "out" && link.maxPasses == 7)
        #expect(added.text.contains(link.id))

        let ported = await Tools.call(name: "add_link", arguments: ["from": "Approved?", "port": "Yes", "to": "Reviewer"], host: host)
        #expect(!ported.isError)
        #expect(await host.flow.links.last?.port == "yes")

        let duplicate = await Tools.call(name: "add_link", arguments: ["from": "Writer", "to": "Reviewer"], host: host)
        #expect(duplicate.isError && duplicate.text.contains("already linked"))
        let toStart = await Tools.call(name: "add_link", arguments: ["from": "Writer", "to": "Start"], host: host)
        #expect(toStart == ToolResult(text: "A Start card takes no input", isError: true))
        let ghost = await Tools.call(name: "add_link", arguments: ["from": "Writer", "to": "Ghost"], host: host)
        #expect(ghost == ToolResult(text: "No card called \"Ghost\"", isError: true))
        let noTarget = await Tools.call(name: "add_link", arguments: ["from": "Writer"], host: host)
        #expect(noTarget.isError)

        let count = await host.flow.links.count
        let removed = await Tools.call(name: "remove_link", arguments: ["link": .string(link.id)], host: host)
        #expect(!removed.isError)
        #expect(await host.flow.links.count == count - 1)
        let again = await Tools.call(name: "remove_link", arguments: ["link": .string(link.id)], host: host)
        #expect(again.isError && again.text.contains(link.id))
    }

    @Test func runAndStop() async throws {
        let host = FakeHost(flow: try sample())
        let idle = await Tools.call(name: "stop_flow", arguments: [:], host: host)
        #expect(!idle.isError)
        #expect(await host.stops == 0)

        let plain = await Tools.call(name: "run_flow", arguments: [:], host: host)
        #expect(plain == ToolResult(text: "Run started", isError: false))
        await host.set(running: false)
        _ = await Tools.call(name: "run_flow", arguments: ["command": "Write a limerick"], host: host)
        #expect(await host.commands == [nil, "Write a limerick"])

        let stopped = await Tools.call(name: "stop_flow", arguments: [:], host: host)
        #expect(!stopped.isError)
        #expect(await host.stops == 1)

        await host.set(runError: "This flow has no Start card")
        let refused = await Tools.call(name: "run_flow", arguments: [:], host: host)
        #expect(refused == ToolResult(text: "This flow has no Start card", isError: true))
    }

    @Test func readAgentReturnsItsStateAndLastReply() async throws {
        let flow = try sample()
        let writer = try #require(flow.resolveCard("Writer"))
        let host = FakeHost(flow: flow)

        let fresh = await Tools.call(name: "read_agent", arguments: ["card": "Writer"], host: host)
        #expect(!fresh.isError && fresh.text.contains("Writer"))

        await host.set(agent: writer.id, AgentStatus(state: "idle", lastReply: "Old pond\nA frog jumps in"))
        let read = await Tools.call(name: "read_agent", arguments: ["card": .string(writer.id)], host: host)
        #expect(!read.isError)
        #expect(read.text.contains("idle") && read.text.contains("Old pond\nA frog jumps in"))

        let notAgent = await Tools.call(name: "read_agent", arguments: ["card": "Start"], host: host)
        #expect(notAgent.isError)
        let ghost = await Tools.call(name: "read_agent", arguments: ["card": "Ghost"], host: host)
        #expect(ghost == ToolResult(text: "No card called \"Ghost\"", isError: true))
    }

    @Test func getRunLogReturnsTheLines() async throws {
        let host = FakeHost()
        let empty = await Tools.call(name: "get_run_log", arguments: [:], host: host)
        #expect(!empty.isError && !empty.text.isEmpty)
        await host.set(log: ["Start → Writer", "Writer → Reviewer"])
        let log = await Tools.call(name: "get_run_log", arguments: [:], host: host)
        #expect(log == ToolResult(text: "Start → Writer\nWriter → Reviewer", isError: false))
    }

    @Test func anUnknownToolIsAnError() async {
        let result = await Tools.call(name: "launch_rocket", arguments: [:], host: FakeHost())
        #expect(result == ToolResult(text: "Unknown tool \"launch_rocket\"", isError: true))
    }

    @Test func argumentsThatAreNotAnObjectCountAsEmpty() async {
        let result = await Tools.call(name: "get_run_log", arguments: .null, host: FakeHost())
        #expect(!result.isError)
    }

    @Test func updateFlowSetsAndClearsTheSpendingLimit() async throws {
        let host = FakeHost(flow: try sample())
        let set = await Tools.call(name: "update_flow", arguments: ["spending_limit": .number(2.5)], host: host)
        #expect(!set.isError && set.text.contains("$2.50"))
        #expect(await host.flow.spendingLimit == 2.5)
        let shown = await Tools.call(name: "get_flow", arguments: [:], host: host)
        #expect(try JSONValue.parse(Data(shown.text.utf8))["spending_limit"]?.doubleValue == 2.5)
        let cleared = await Tools.call(name: "update_flow", arguments: ["spending_limit": 0], host: host)
        #expect(!cleared.isError && cleared.text.contains("no spending limit"))
        #expect(await host.flow.spendingLimit == nil)
        let nothing = await Tools.call(name: "update_flow", arguments: [:], host: host)
        #expect(nothing.isError)
    }

    @Test func anApprovalsTimeLimitAndAnswerCanBeSet() async throws {
        let host = FakeHost()
        _ = await Tools.call(name: "add_card", arguments: ["kind": "approval", "name": "Sign off", "wait_minutes": 480, "when_no_answer": "Approved"], host: host)
        let card = try #require(await host.flow.resolveCard("Sign off"))
        #expect(card.waitMinutes == 480 && card.whenNoAnswer == "approved")
        let bad = await Tools.call(name: "update_card", arguments: ["card": "Sign off", "when_no_answer": "maybe"], host: host)
        #expect(bad.isError && bad.text.contains("approved or rejected"))
        let script = await Tools.call(name: "add_card", arguments: ["kind": "script", "when_no_answer": "approved"], host: host)
        #expect(script.isError)
        let shown = try JSONValue.parse(Data(await Tools.call(name: "get_flow", arguments: [:], host: host).text.utf8))
        #expect(shown["cards"]?.arrayValue?.first?["wait_minutes"] == 480)
    }

    @Test func aForEachsSettingsCanBeSet() async throws {
        let host = FakeHost()
        let added = await Tools.call(name: "add_card", arguments: ["kind": "for-each", "name": "Each", "split": "lines", "max_items": 10], host: host)
        #expect(!added.isError && added.text.contains("Outputs: each, done."))
        let card = try #require(await host.flow.resolveCard("Each"))
        #expect(card.split == .lines && card.maxItems == 10)
        let bad = await Tools.call(name: "update_card", arguments: ["card": "Each", "split": "words"], host: host)
        #expect(bad.isError)
    }

    @Test func saveToInsideAProtectedFolderIsRefused() async throws {
        let host = FakeHost()
        let refused = await Tools.call(name: "add_card", arguments: ["kind": "end", "name": "Out", "save_to": ".git/config"], host: host)
        #expect(refused.isError && refused.text.contains(".git"))
        #expect(await host.flow.resolveCard("Out") == nil)
    }
}
