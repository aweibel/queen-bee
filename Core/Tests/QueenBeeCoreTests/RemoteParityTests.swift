import Foundation
import Testing
@testable import QueenBeeCore

/// What stage 4 adds: the rest of what the Mac's buttons do, and what a device needs to draw them.
@Suite struct RemoteParityTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try Remote.decode(T.self, from: Remote.encode(value))
    }

    private static func card(_ kind: CardKind, _ name: String, x: Double = 10, y: Double = 20) -> Card {
        Card.make(kind: kind, id: name.lowercased(), name: name, x: x, y: y)
    }

    private static var fragment: FlowFragment {
        var script = card(.script, "Shout")
        script.command = "tr a-z A-Z"
        var agent = card(.agent, "Writer", x: 400)
        agent.instructions = "Write."
        agent.cwd = "/tmp"
        agent.sessionID = "0b0b0b0b-0000-0000-0000-000000000000"
        var start = card(.start, "Go", x: 800)
        start.trigger = Trigger(kind: .interval, minutes: 1)
        return FlowFragment(cards: [script, agent, start], links: [Link(id: "l", from: "shout", port: "pass", to: "writer")],
                            groups: [CardGroup(id: "g", name: "Both", cardIDs: ["shout", "writer"])])
    }

    private let flowCommands: [RemoteCommand] = [
        .runFromStart(flowID: "f", startCardID: "s"),
        .retry(flowID: "f", cardID: "a"),
        .clearLog(flowID: "f"),
        .dismissBanner(flowID: "f"),
        .stopAgents(flowID: "f"),
        .revertSettings(flowID: "f", cardID: "a"),
        .armSchedule(flowID: "f", cardID: "s", on: true),
        .armSchedule(flowID: "f", cardID: "s", on: false),
        .paste(flowID: "f", fragment: RemoteParityTests.fragment, at: RemotePoint(x: 100, y: 200)),
        .paste(flowID: "f", fragment: RemoteParityTests.fragment, at: nil),
        .addRoleCard(flowID: "f", roleID: "r", x: 300, y: 400),
        .newSubflow(flowID: "f", cardID: "c", name: ""),
        .pin(flowID: "f", on: true),
        .saveRole(flowID: "f", cardID: "a", name: "Writer"),
        .updateRole(roleID: "r", flowID: "f", cardID: "a"),
    ]

    private let apart: [RemoteCommand] = [
        .deleteRole(roleID: "r"),
        .clearBrowserData(projectID: "/p"),
        .installBrowser(projectID: "/p"),
        .restartBrowser(projectID: "/p"),
    ]

    @Test func theVersionIsTheOneWithEverythingTheMacCanDo() {
        #expect(Remote.version == 4)
    }

    @Test func everyNewCommandSurvivesEncodingAndIsFineAsItIs() throws {
        for (id, command) in (flowCommands + apart).enumerated() {
            let message = DeviceMessage.command(id: id, command: command)
            #expect(try Remote.decode(DeviceMessage.self, from: Remote.encode(message)) == message)
            #expect(command.problem == nil)
            #expect(command.isAnswered)
        }
    }

    @Test func eachNamesItsFlowOrNone() {
        for command in flowCommands { #expect(command.flowID == "f") }
        // A role and a project's browser belong to no flow.
        for command in apart { #expect(command.flowID == nil) }
    }

    @Test func theEncodingNamesTheParts() throws {
        let data = try Remote.encode(RemoteCommand.armSchedule(flowID: "f", cardID: "s", on: true))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let arm = try #require(json["armSchedule"])
        #expect(arm["flowID"] as? String == "f")
        #expect(arm["cardID"] as? String == "s")
        #expect(arm["on"] as? Bool == true)
        let role = try #require(JSONSerialization.jsonObject(with: Remote.encode(RemoteCommand.updateRole(roleID: "r", flowID: "f", cardID: "a"))) as? [String: [String: String]])
        #expect(role["updateRole"] == ["roleID": "r", "flowID": "f", "cardID": "a"])
    }

    @Test func onlyWhatChangesAFlowIsAnEdit() {
        let edits: [RemoteCommand] = [
            .revertSettings(flowID: "f", cardID: "a"), .paste(flowID: "f", fragment: Self.fragment, at: nil),
            .addRoleCard(flowID: "f", roleID: "r", x: 0, y: 0), .newSubflow(flowID: "f", cardID: "c", name: ""),
            .saveRole(flowID: "f", cardID: "a", name: ""),
        ]
        for command in edits { #expect(command.isEdit) }
        // Turning a schedule on is not an edit: an edit from a device turns schedules off.
        let others: [RemoteCommand] = [
            .runFromStart(flowID: "f", startCardID: "s"), .retry(flowID: "f", cardID: "a"), .clearLog(flowID: "f"),
            .dismissBanner(flowID: "f"), .stopAgents(flowID: "f"), .armSchedule(flowID: "f", cardID: "s", on: true),
            .pin(flowID: "f", on: true), .updateRole(roleID: "r", flowID: "f", cardID: "a"),
        ] + apart
        for command in others { #expect(!command.isEdit) }
    }

    @Test func runningFromAStartAndRetryingCanTakeTime() {
        #expect(RemoteCommand.runFromStart(flowID: "f", startCardID: "s").canTakeTime)
        #expect(RemoteCommand.retry(flowID: "f", cardID: "a").canTakeTime)
        #expect(!RemoteCommand.stopAgents(flowID: "f").canTakeTime)
        #expect(!RemoteCommand.armSchedule(flowID: "f", cardID: "s", on: true).canTakeTime)
        #expect(!RemoteCommand.clearBrowserData(projectID: "/p").canTakeTime)
    }

    // MARK: Pasting

    @Test func aPastedFragmentBringsNoFolderSessionOrSchedule() {
        let cleaned = RemoteCommand.paste(flowID: "f", fragment: Self.fragment, at: nil).cleaned
        guard case .paste(_, let fragment, _) = cleaned else { Issue.record("not a paste"); return }
        #expect(fragment.cards.allSatisfy { $0.cwd == nil && $0.sessionID == nil && $0.trigger == nil })
        // Everything else comes as it was.
        #expect(fragment.cards.map(\.name) == ["Shout", "Writer", "Go"])
        #expect(fragment.cards[0].command == "tr a-z A-Z")
        #expect(fragment.links == Self.fragment.links)
        #expect(fragment.groups == Self.fragment.groups)
    }

    @Test func aPastedFragmentIsCleanedOfWhatATerminalWouldActOn() {
        var bad = Self.fragment
        bad.cards[0].name = "Sh\u{1b}[2Jout\nnow"
        bad.cards[0].command = "tr a-z A-Z\u{1b}[201~\r"
        bad.cards[1].instructions = "Write\u{7}."
        bad.links[0].port = "pa\u{1b}ss"
        bad.groups?[0].name = "Bo\nth"
        let cleaned = bad.cleanedFromDevice
        #expect(cleaned.cards[0].name == "Sh [2Jout now")
        #expect(cleaned.cards[0].command == "tr a-z A-Z[201~\n")
        #expect(cleaned.cards[1].instructions == "Write.")
        #expect(cleaned.links[0].port == "pa ss")
        #expect(cleaned.groups?[0].name == "Bo th")
    }

    @Test func aFragmentIsHeldToTheCapsOfAnyOtherEdit() {
        func problem(_ change: (inout FlowFragment) -> Void) -> String? {
            var fragment = Self.fragment
            change(&fragment)
            return RemoteCommand.paste(flowID: "f", fragment: fragment, at: nil).problem
        }
        #expect(problem { $0.cards = [] }?.contains("nothing to paste") == true)
        #expect(problem { f in f.cards = (0...Remote.cardLimit).map { Self.card(.note, "N\($0)") } }?.contains("too many") == true)
        #expect(problem { f in f.cards = (0..<Remote.cardLimit).map { Self.card(.note, "N\($0)") } } == nil)
        #expect(problem { f in f.links = (0...Remote.linkLimit).map { Link(id: "l\($0)", from: "shout", to: "writer") } }?.contains("too many") == true)
        #expect(problem { $0.cards[0].name = String(repeating: "n", count: Remote.nameLimit + 1) }?.contains("too long") == true)
        #expect(problem { $0.cards[0].name = "e" + String(repeating: "\u{0301}", count: 500) }?.contains("too long") == true)
        #expect(problem { $0.cards[0].command = String(repeating: "c", count: Remote.textLimit + 1) }?.contains("too long") == true)
        #expect(problem { $0.cards[1].instructions = String(repeating: "i", count: Remote.textLimit) } == nil)
        #expect(problem { $0.cards[0].saveTo = String(repeating: "p", count: Remote.pathLimit + 1) }?.contains("too long") == true)
        #expect(problem { $0.cards[0].branches = (0...Remote.branchLimit).map { "b\($0)" } }?.contains("too many branches") == true)
        #expect(problem { $0.links[0].port = String(repeating: "p", count: Remote.nameLimit + 1) }?.contains("too long") == true)
        #expect(problem { $0.groups?[0].name = String(repeating: "g", count: Remote.nameLimit + 1) }?.contains("too long") == true)
        #expect(problem { $0.cards[0].x = .infinity }?.contains("off the edge") == true)
        #expect(problem { $0.cards[0].y = -Remote.farthestPoint * 2 }?.contains("off the edge") == true)
        #expect(problem { $0.cards[0].width = Remote.largestSide + 1 }?.contains("that size") == true)
        #expect(problem { $0.cards[0].height = 0 }?.contains("that size") == true)
        #expect(RemoteCommand.paste(flowID: "f", fragment: Self.fragment, at: RemotePoint(x: .nan, y: 0)).problem?.contains("off the edge") == true)
    }

    @Test func aPasteOfAsMuchAsAMessageHoldsStaysInsideTheFlowsOwnCaps() throws {
        // What the Mac takes from a device in one message is the real limit on a paste.
        var fragment = FlowFragment(cards: (0..<120).map { Self.card(.note, "Note \($0)") }, links: [])
        for index in fragment.cards.indices { fragment.cards[index].text = "x" }
        let sent = try Remote.encode(DeviceMessage.command(id: 1, command: .paste(flowID: UUID().uuidString, fragment: fragment, at: nil)))
        #expect(sent.count < 64 * 1024)
        #expect(RemoteCommand.paste(flowID: "f", fragment: fragment, at: nil).problem == nil)
    }

    // MARK: Names

    @Test func aRoleOrASubflowsNameIsCappedAndCleaned() {
        let tall = "e" + String(repeating: "\u{0301}", count: 500)
        #expect(RemoteCommand.saveRole(flowID: "f", cardID: "a", name: tall).problem?.contains("too long") == true)
        #expect(RemoteCommand.newSubflow(flowID: "f", cardID: "c", name: String(repeating: "n", count: Remote.nameLimit + 1)).problem?.contains("too long") == true)
        #expect(RemoteCommand.saveRole(flowID: "f", cardID: "a", name: "Wri\u{1b}ter\n").cleaned == .saveRole(flowID: "f", cardID: "a", name: "Wri ter"))
        #expect(RemoteCommand.newSubflow(flowID: "f", cardID: "c", name: " Be\tlow ").cleaned == .newSubflow(flowID: "f", cardID: "c", name: "Be low"))
    }

    @Test func aRoleCardIsPutSomewhereOnTheCanvas() {
        #expect(RemoteCommand.addRoleCard(flowID: "f", roleID: "r", x: Remote.farthestPoint + 1, y: 0).problem?.contains("off the edge") == true)
        #expect(RemoteCommand.addRoleCard(flowID: "f", roleID: "r", x: -40, y: 7).problem == nil)
    }

    // MARK: The Browser switch

    @Test func theBrowserSwitchIsPartOfAPatch() throws {
        var patch = RemoteCardPatch()
        #expect(patch.isEmpty)
        patch.browser = true
        #expect(!patch.isEmpty)
        #expect(patch.problem == nil)
        #expect(patch.cardPatch.browser == true)
        // Never a folder, whatever else the patch holds.
        #expect(patch.cardPatch.cwd == nil)
        #expect(try roundTrip(patch) == patch)
        var flow = Flow(name: "Demo")
        let agent = try flow.addCard(kind: .agent, x: 0, y: 0)
        try flow.updateCard(agent.id, patch: patch.cardPatch)
        #expect(flow.card(agent.id)?.browser == true)
        #expect(flow.changesWhatItDoes(from: { var old = flow; old.cards[0].browser = nil; return old }()))
    }

    // MARK: What a device is told

    @Test func whatTheLibraryAndTheRunNowCarrySurvivesEncoding() throws {
        var card = Self.card(.agent, "Writer")
        card.instructions = "Write."
        let library = RemoteLibrary(projects: [
            RemoteProject(id: "/p", name: "proj", flows: [
                RemoteFlowSummary(id: "f", name: "Top", isSubflow: false, activity: .quiet, pinned: true, cardNames: ["Start", "Writer"],
                                  usage: Usage(cost: 1), usageWithSubflows: Usage(cost: 3)),
                RemoteFlowSummary(id: "g", name: "Below", isSubflow: true, activity: .running, parentID: "f"),
            ], browser: RemoteBrowserState(status: .downloading, progress: 0.35, browser: nil, hasData: true)),
            RemoteProject(id: "/q", name: "other", flows: [], browser: RemoteBrowserState(status: .failed, problem: "It crashed", browser: "Google Chrome")),
        ], roles: [RemoteRole(id: "r", name: "Writer", instructions: "Write.", model: "haiku", effort: "high", permissionMode: "plan")])
        #expect(try roundTrip(HostMessage.library(library)) == .library(library))
        let run = RemoteRunState(isRunning: true, marks: [:], linkPasses: [:], liveLinkIDs: [], handOffs: 0, holds: [], results: [:],
                                 usage: ["a": Usage(cost: 2)], sessions: ["a": .idle], awaitingAnswer: [], banner: nil,
                                 awaitingRestart: ["a": ["instructions", "browser"]], orchestratorNeedsRestart: true,
                                 runUsage: ["a": Usage(cost: 0.5)])
        #expect(try roundTrip(HostMessage.run(id: "f", state: run)) == .run(id: "f", state: run))
    }

    @Test func aDownloadsProgressIsSentInTwentieths() {
        #expect(RemoteBrowserState.step(0) == 0)
        #expect(RemoteBrowserState.step(0.049) == 0)
        #expect(RemoteBrowserState.step(0.05) == 0.05)
        #expect(RemoteBrowserState.step(0.37) == 0.35)
        #expect(RemoteBrowserState.step(1) == 1)
        #expect(RemoteBrowserState.step(7) == 1)
        #expect(RemoteBrowserState.step(-1) == 0)
        #expect(RemoteBrowserState.step(.nan) == 0)
        // However fine the Mac's own steps, a download is at most 21 different states.
        #expect(Set((0...1000).map { RemoteBrowserState.step(Double($0) / 1000) }).count == 21)
    }

    @Test func aRoleSaysWhenACardHasDriftedFromIt() {
        var card = Self.card(.agent, "Writer")
        card.instructions = "Write."
        card.model = "haiku"
        let role = RemoteRole(id: "r", name: "Writer", instructions: "Write.", model: "haiku")
        #expect(role.matches(card))
        card.effort = "high"
        #expect(!role.matches(card))
        // The name and the folder are the card's own.
        card.effort = nil
        card.name = "Another"
        card.cwd = "/elsewhere"
        #expect(role.matches(card))
    }

    @Test func theFlowListCarriesSomeOfEachCardsName() throws {
        var flow = Flow(name: "Big")
        for n in 0..<(Remote.cardNamesLimit + 5) { _ = try flow.addCard(kind: .note, name: "Note \(n) " + String(repeating: "x", count: 80), x: 0, y: 0) }
        let names = Remote.listedNames(of: flow)
        #expect(names.count == Remote.cardNamesLimit)
        #expect(names.allSatisfy { $0.count <= Remote.cardNameLength })
        #expect(names[0].hasPrefix("Note 0 x"))
    }

    @Test func tyingACardToARoleChangesNothingAFlowDoes() throws {
        var flow = Flow(name: "Demo")
        let agent = try flow.addCard(kind: .agent, x: 0, y: 0)
        var tied = flow
        tied.cards[0].role = "r"
        #expect(!tied.changesWhatItDoes(from: flow))
        // Giving it the role's settings does.
        tied.cards[0].instructions = "From the role."
        #expect(tied.changesWhatItDoes(from: flow))
        _ = agent
    }

    @Test func aChangeToWhatAwaitsARestartIsSentWithTheRun() {
        var flow = Flow(name: "Demo")
        _ = try? flow.addCard(kind: .agent, x: 0, y: 0)
        let run = RemoteRunState(isRunning: false, marks: [:], linkPasses: [:], liveLinkIDs: [], handOffs: 0, holds: [], results: [:],
                                 usage: [:], sessions: [:], awaitingAnswer: [], banner: nil)
        let old = RemoteFlowSnapshot(flow: flow, run: run, log: [], messages: [:], runs: [])
        var new = old
        new.run.awaitingRestart = [flow.cards[0].id: ["model"]]
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.run(id: flow.id, state: new.run)])
        var later = new
        later.run.orchestratorNeedsRestart = true
        #expect(RemoteSnapshot.updates(from: new, to: later, revision: 1) == [.run(id: flow.id, state: later.run)])
        var mirror = RemoteMirror()
        mirror.willOpen(flow.id)
        _ = mirror.apply(.opened(old))
        for message in RemoteSnapshot.updates(from: old, to: later, revision: 1) { _ = mirror.apply(message) }
        #expect(mirror.snapshot?.run.awaitingRestart == [flow.cards[0].id: ["model"]])
        #expect(mirror.snapshot?.run.orchestratorNeedsRestart == true)
    }

    @Test func retryIsOfferedWhereTheMacOffersIt() throws {
        var flow = Flow(name: "Demo")
        let start = try flow.addCard(kind: .start, x: 0, y: 0)
        let agent = try flow.addCard(kind: .agent, x: 300, y: 0)
        let link = try flow.addLink(from: start.id, to: agent.id)
        var failed = RunMark()
        failed.failed = true
        let run = RemoteRunState(isRunning: false, marks: [agent.id: failed], linkPasses: [:], liveLinkIDs: [], handOffs: 0, holds: [],
                                 results: [:], usage: [:], sessions: [:], awaitingAnswer: [], banner: nil)
        var snapshot = RemoteFlowSnapshot(flow: flow, run: run, log: [],
                                          messages: [link.id: [LinkMessage(date: Date(timeIntervalSince1970: 1), from: "Start", text: "go")]], runs: [])
        #expect(snapshot.canRetry(agent.id))
        #expect(!snapshot.canRetry(start.id))
        snapshot.run.isRunning = true
        #expect(!snapshot.canRetry(agent.id))
        snapshot.run.isRunning = false
        snapshot.messages = [:]
        #expect(!snapshot.canRetry(agent.id))
    }

    @Test func theMirrorKeepsWhatTheLibraryNowCarries() {
        var mirror = RemoteMirror()
        let library = RemoteLibrary(projects: [RemoteProject(id: "/p", name: "proj", flows: [
            RemoteFlowSummary(id: "f", name: "Top", isSubflow: false, activity: .quiet, pinned: true, cardNames: ["Start"]),
        ], browser: RemoteBrowserState(status: .missing))], roles: [RemoteRole(id: "r", name: "Writer", instructions: "Write.")])
        _ = mirror.apply(.library(library))
        #expect(mirror.library?.projects[0].flows[0].pinned == true)
        #expect(mirror.library?.projects[0].browser.status == .missing)
        #expect(mirror.library?.roles[0].instructions == "Write.")
    }
}
