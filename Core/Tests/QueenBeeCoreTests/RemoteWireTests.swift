import CryptoKit
import Foundation
import Testing
@testable import QueenBeeCore

/// One of every message the two apps send, with every field filled in, so that the shape of what goes over the
/// wire can be checked as a whole.
enum WireSamples {
    static let at = Date(timeIntervalSince1970: 1_000)

    static var card: Card {
        var card = Card.make(kind: .agent, id: "c1", name: "Writer", x: 1, y: 2)
        card.instructions = "i"; card.model = "m"; card.effort = "high"; card.permissionMode = "plan"; card.cwd = "/p"
        card.sessionID = "s"; card.role = "r"; card.browser = true; card.command = "c"; card.flowRef = "f"; card.check = .regex
        card.value = "v"; card.maxTries = 2; card.branches = ["A"]; card.template = "t"; card.saveTo = "o"; card.text = "n"
        card.trigger = Trigger(kind: .weekly, minutes: 5, hour: 1, minute: 2, weekdays: [2], path: "p")
        card.unknownKind = "later"
        return card
    }

    static var flow: Flow {
        var flow = Flow(id: "f1", name: "Demo", cards: [card], links: [Link(id: "l1", from: "c1", port: "out", to: "c1", maxPasses: 2)])
        flow.orchestratorSessionID = "o"; flow.subflowLimit = 2; flow.isSubflow = true
        flow.groups = [CardGroup(id: "g1", name: "G", cardIDs: ["c1"], isFolded: true)]
        return flow
    }

    static var usage: Usage { Usage(cost: 1, input: 2, output: 3, cacheRead: 4, cacheWrite: 5) }

    static var mark: RunMark {
        var mark = RunMark()
        mark.arrivals = 1; mark.passes = 1; mark.ports = ["out": 1]; mark.lastPort = "out"; mark.holding = 1; mark.failed = true
        return mark
    }

    static var line: LogLine { LogLine(date: at, text: "line", isKept: true) }
    static var message: LinkMessage { LinkMessage(date: at, from: "A", text: "hi") }

    static var run: RemoteRunState {
        RemoteRunState(isRunning: true, marks: ["c1": mark], linkPasses: ["l1": 1], liveLinkIDs: ["l1"], handOffs: 1,
                       holds: [PendingHold(id: "h1", cardID: "c1", kind: .script, text: "t", from: "A", command: "ls", needsAllow: true, allowOnMac: true)],
                       results: ["c1": "r"], usage: ["c1": usage], sessions: ["c1": .working], awaitingAnswer: ["c1"], banner: "b",
                       awaitingRestart: ["c1": ["model"]], orchestratorNeedsRestart: true, runUsage: ["c1": usage])
    }

    static var record: RunRecord {
        RunRecord(id: "r1", started: at, ended: at, outcome: .failed, command: "go", log: [line], results: ["c1": "r"], marks: ["c1": mark],
                  linkPasses: ["l1": 1], messages: ["l1": [message]], handOffs: 1, usage: ["c1": usage])
    }

    static var snapshot: RemoteFlowSnapshot {
        RemoteFlowSnapshot(flow: flow, run: run, edit: RemoteEditState(undo: "Undo", redo: "Redo", armed: ["c1"], nextFires: ["c1": at]),
                           log: [line], messages: ["l1": [message]], runs: [record])
    }

    static var library: RemoteLibrary {
        let summary = RemoteFlowSummary(id: "f1", name: "Demo", isSubflow: true, activity: .needsYou, parentID: "f0", pinned: true,
                                        cardNames: ["Writer"], usage: usage, usageWithSubflows: usage, sharedID: true)
        let browser = RemoteBrowserState(status: .downloading, progress: 0.5, problem: "p", browser: "Chrome", hasData: true)
        let role = RemoteRole(id: "r", name: "R", instructions: "i", model: "m", effort: "e", permissionMode: "plan", instructionsHash: "h",
                              changedFrom: "iPad", changedAt: at)
        return RemoteLibrary(projects: [RemoteProject(id: "/p", name: "P", flows: [summary], browser: browser)], roles: [role])
    }

    static var page: RemoteBrowserPage {
        var page = RemoteBrowserPage()
        page.status = .running; page.progress = 1; page.problem = "p"; page.isAttached = true; page.hasPicture = true; page.url = "u"
        page.title = "t"; page.isLoading = true; page.canGoBack = true; page.canGoForward = true; page.addressProblem = "a"; page.isWatchOnly = true
        return page
    }

    static var hostMessages: [HostMessage] {
        [
            .welcome(RemoteWelcome(version: Remote.version, macName: "Mac", canControl: true, features: [RemoteFeature.commandMemory])),
            .refused("no"), .library(library), .opened(snapshot), .flow(id: "f1", revision: 1, flow: flow), .run(id: "f1", state: run),
            .edit(id: "f1", state: snapshot.edit), .log(id: "f1", lines: [line], reset: true), .messages(id: "f1", link: "l1", all: [message]),
            .history(id: "f1", runs: [record]), .historyChanged(id: "f1", runs: [record], order: ["r1"]),
            .terminal(id: "f1", key: "c1", chunk: TerminalChunk(reset: true, cols: 80, rows: 24, data: Data([1]))),
            .answer(id: 1, refusal: "no"), .control(canControl: true), .browserPage(id: "f1", card: "c1", page: page),
            .browserFrame(id: "f1", card: "c1", frame: RemoteBrowserFrame(jpeg: Data([1]), width: 1, height: 1, pageWidth: 1, pageHeight: 1)),
            .browserCopied(id: "f1", card: "c1", text: "t"),
        ]
    }

    static var commands: [RemoteCommand] {
        var patch = RemoteCardPatch()
        patch.name = "n"; patch.instructions = "i"; patch.model = "m"; patch.effort = "high"; patch.permissionMode = "plan"; patch.role = "r"
        patch.browser = true; patch.command = "c"; patch.trigger = Trigger(kind: .daily); patch.removesTrigger = true; patch.check = .contains
        patch.value = "v"; patch.maxTries = 1; patch.branches = ["A"]; patch.template = "t"; patch.saveTo = "s"; patch.text = "x"; patch.flowRef = "f"
        let point = RemotePoint(x: 1, y: 2)
        let fragment = FlowFragment(cards: [card], links: [Link(id: "l1", from: "c1", to: "c1")], groups: [CardGroup(id: "g", name: "G", cardIDs: ["c1"])])
        let actions: [RemoteBrowserAction] = [.mouse(RemoteMouse(.pressed, x: 1, y: 2, isDown: true, clicks: 1, modifiers: 8)),
                                              .wheel(x: 1, y: 2, dx: 3, dy: 4), .key(name: "Enter", modifiers: 1), .text("t"), .navigate("u"),
                                              .back, .forward, .reload, .copy(cut: true), .shortcut(.undo)]
        return [
            .openOnMac(flowID: "f"), .run(flowID: "f", command: "c"), .runFrom(flowID: "f", cardID: "c", text: "t"), .stop(flowID: "f"),
            .approve(flowID: "f", holdID: "h", text: "t"), .reject(flowID: "f", holdID: "h", note: "n"), .allowScript(flowID: "f", holdID: "h"),
            .refuseScript(flowID: "f", holdID: "h"), .startSession(flowID: "f", cardID: "c"), .prompt(flowID: "f", key: "k", text: "t"),
            .keys(flowID: "f", key: "k", data: Data([1])), .addCard(flowID: "f", kind: .note, x: 1, y: 2),
            .moveCards(flowID: "f", moves: ["c": point], final: true),
            .resizeCard(flowID: "f", cardID: "c", frame: RemoteFrame(x: 1, y: 2, width: 3, height: 4), final: false),
            .deleteItems(flowID: "f", cardIDs: ["c"], linkIDs: ["l"]), .addLink(flowID: "f", from: "a", port: "out", to: "b"),
            .setLinkLimit(flowID: "f", linkID: "l", maxPasses: 2), .duplicate(flowID: "f", cardIDs: ["c"]), .tidy(flowID: "f"),
            .group(flowID: "f", cardIDs: ["c"], name: "g"), .ungroup(flowID: "f", groupID: "g"), .renameGroup(flowID: "f", groupID: "g", name: "n"),
            .foldGroup(flowID: "f", groupID: "g", folded: true), .patchCard(flowID: "f", cardID: "c", patch: patch),
            .setFlowOption(flowID: "f", option: .subflowLimit(levels: 2)), .setFlowOption(flowID: "f", option: .notifyOrchestrator(on: true)),
            .newFlow(projectID: "p", name: "n"), .renameFlow(flowID: "f", name: "n"), .deleteFlow(flowID: "f"), .undo(flowID: "f"), .redo(flowID: "f"),
            .runFromStart(flowID: "f", startCardID: "s"), .retry(flowID: "f", cardID: "c"), .clearLog(flowID: "f"), .dismissBanner(flowID: "f"),
            .stopAgents(flowID: "f"), .revertSettings(flowID: "f", cardID: "c"), .armSchedule(flowID: "f", cardID: "c", on: true),
            .paste(flowID: "f", fragment: fragment, at: point), .addRoleCard(flowID: "f", roleID: "r", x: 1, y: 2),
            .newSubflow(flowID: "f", cardID: "c", name: "n"), .pin(flowID: "f", on: true), .saveRole(flowID: "f", cardID: "c", name: "n"),
            .updateRole(roleID: "r", flowID: "f", cardID: "c"), .deleteRole(roleID: "r"), .clearBrowserData(projectID: "p"),
            .installBrowser(projectID: "p"), .restartBrowser(projectID: "p"),
        ] + actions.map { .browser(flowID: "f", cardID: "c", action: $0) }
    }

    static var deviceMessages: [DeviceMessage] {
        [.hello(RemoteHello(version: Remote.version, deviceID: "d", deviceName: "iPad", epoch: "e", features: [RemoteFeature.historyChanges],
                            proof: Data([1]))),
         .open(flowID: "f"), .watchBrowsers(flowID: "f", cardIDs: ["c"])]
            + commands.map { DeviceMessage.command(id: 1, command: $0) }
    }

    static var pairing: [Data] {
        [try! Remote.encode(PairRequest(version: Remote.version, deviceID: "d", deviceName: "iPad")),
         try! Remote.encode(PairReply.granted(PairGrant(key: Data([1]), deviceID: "d", macID: "m", macName: "Mac"))),
         try! Remote.encode(PairReply.refused("no"))]
    }

    /// Every path in a JSON value with the kind of value found there, one to a line, sorted.
    static func shape(_ json: Any, at path: String = "") -> Set<String> {
        switch json {
        case let object as [String: Any]:
            return object.reduce(into: ["\(path): object"]) { $0.formUnion(shape($1.value, at: "\(path).\($1.key)")) }
        case let array as [Any]:
            return array.reduce(into: ["\(path): array"]) { $0.formUnion(shape($1, at: "\(path)[]")) }
        case let number as NSNumber:
            return ["\(path): \(CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number")"]
        case is String: return ["\(path): string"]
        default: return ["\(path): null"]
        }
    }

    static func fingerprint() throws -> String {
        let frames = try hostMessages.map(Remote.encode) + deviceMessages.map(Remote.encode) + pairing
        var lines = Set<String>()
        for (index, frame) in frames.enumerated() {
            lines.formUnion(shape(try JSONSerialization.jsonObject(with: frame), at: "\(index)"))
        }
        let text = lines.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

@Suite struct RemoteWireTests {
    /// The shape of every message for each `Remote.version`. Apps on the same version connect without question,
    /// so a change to what they send each other has to be one an app built before it can still read.
    static let fingerprints: [Int: String] = [5: "53ea78f1f4e3b85b01629d32"]

    @Test func theWireFormatMatchesItsVersion() throws {
        let now = try WireSamples.fingerprint()
        #expect(Self.fingerprints[Remote.version] == now, """
            What the Mac and a device send each other has changed. If an app built before this change can't read it \
            (a field taken away, renamed or made required, or a new kind of message sent to an app that hasn't said it \
            takes it), raise `Remote.version`. Either way, put this in `RemoteWireTests.fingerprints` for version \
            \(Remote.version): "\(now)"
            """)
    }

    /// The device tells a message it doesn't know from one it can't read by these names.
    @Test func everyKindOfMessageIsNamed() throws {
        var seen = Set<String>()
        for message in WireSamples.hostMessages {
            let object = try #require(try JSONSerialization.jsonObject(with: Remote.encode(message)) as? [String: Any])
            #expect(object.count == 1)
            seen.formUnion(object.keys)
        }
        #expect(seen == HostMessage.caseNames)
    }

    @Test func everyMessageSurvivesTheTrip() throws {
        for message in WireSamples.hostMessages {
            #expect(try Remote.read(fromMac: Remote.encode(message)) == .message(message))
        }
        for message in WireSamples.deviceMessages {
            #expect(try Remote.decode(DeviceMessage.self, from: Remote.encode(message)) == message)
        }
    }

    // MARK: Older and newer apps

    /// What an app from before the features sends, and what it reads.
    private struct OldHello: Codable, Equatable { var version: Int; var deviceID: String; var deviceName: String }
    private struct OldWelcome: Codable, Equatable { var version: Int; var macName: String; var canControl: Bool }

    @Test func helloAndWelcomeStillReadBothWays() throws {
        let old = try Remote.encode(OldHello(version: 5, deviceID: "d", deviceName: "iPad"))
        #expect(try Remote.decode(RemoteHello.self, from: old) == RemoteHello(version: 5, deviceID: "d", deviceName: "iPad"))
        let new = try Remote.encode(RemoteHello(version: 5, deviceID: "d", deviceName: "iPad", epoch: "e", features: ["x"], proof: Data([1])))
        #expect(try Remote.decode(OldHello.self, from: new) == OldHello(version: 5, deviceID: "d", deviceName: "iPad"))
        let welcome = try Remote.encode(RemoteWelcome(version: 5, macName: "Mac", canControl: true, features: [RemoteFeature.commandMemory]))
        #expect(try Remote.decode(OldWelcome.self, from: welcome) == OldWelcome(version: 5, macName: "Mac", canControl: true))
        let oldWelcome = try Remote.encode(OldWelcome(version: 5, macName: "Mac", canControl: false))
        let read = try Remote.decode(RemoteWelcome.self, from: oldWelcome)
        #expect(!read.has(RemoteFeature.commandMemory))
        #expect(read.memoryID == nil)
        let withMemory = try Remote.encode(RemoteWelcome(version: 5, macName: "Mac", canControl: true, memoryID: "m1"))
        #expect(try Remote.decode(OldWelcome.self, from: withMemory) == OldWelcome(version: 5, macName: "Mac", canControl: true))
        #expect(try Remote.decode(RemoteWelcome.self, from: withMemory).memoryID == "m1")
    }

    /// Commands that weren't answered are sent again only to the same run of the Mac app that they went to: one that
    /// has started again since forgot them, and would do them twice.
    @Test func commandsAreSentAgainOnlyToTheSameRunOfTheMac() {
        let memory = [RemoteFeature.commandMemory]
        #expect(RemoteWelcome(version: 5, macName: "Mac", canControl: true, features: memory, memoryID: "a").resends(sentUnder: "a"))
        // The Mac app started again.
        #expect(!RemoteWelcome(version: 5, macName: "Mac", canControl: true, features: memory, memoryID: "b").resends(sentUnder: "a"))
        // A Mac that doesn't say which run it is, now or then, can't be trusted to remember.
        #expect(!RemoteWelcome(version: 5, macName: "Mac", canControl: true, features: memory).resends(sentUnder: "a"))
        #expect(!RemoteWelcome(version: 5, macName: "Mac", canControl: true, features: memory, memoryID: "a").resends(sentUnder: nil))
        // Nor one that doesn't remember commands at all.
        #expect(!RemoteWelcome(version: 5, macName: "Mac", canControl: true, memoryID: "a").resends(sentUnder: "a"))
    }

    /// A card of a kind this app doesn't know is a note saying to update, and the rest of the flow is all there.
    @Test func aCardOfAnUnknownKindBecomesANoteSayingSo() throws {
        var flow = Flow(id: "f1", name: "Demo")
        flow.cards = [Card.make(kind: .agent, id: "a", name: "Writer", x: 0, y: 0), Card.make(kind: .note, id: "b", name: "Robot", x: 0, y: 0)]
        let json = try Remote.encode(HostMessage.flow(id: "f1", revision: 2, flow: flow))
        let newer = try #require(String(data: json, encoding: .utf8)).replacingOccurrences(of: "\"kind\":\"note\"", with: "\"kind\":\"robot\"")
        #expect(throws: (any Error).self) { try Remote.decode(HostMessage.self, from: Data(newer.utf8)) }
        guard case .message(.flow(_, 2, let read)) = try Remote.read(fromMac: Data(newer.utf8)) else {
            Issue.record("The flow wasn't read")
            return
        }
        #expect(read.cards[0] == flow.cards[0])
        #expect(read.cards[1].kind == .note)
        #expect(read.cards[1].unknownKind == "robot")
        #expect(read.cards[1].text == Remote.unknownCardText)
        #expect(read.cards[1].name == "Robot")
        // It can't be copied back to the Mac as what it is not.
        #expect(FlowFragment(cards: [read.cards[1]], links: []).deviceProblem == Remote.unknownCardText)
    }

    @Test func aWordThisAppDoesNotKnowBecomesThePlainestOne() throws {
        let json = try Remote.encode(HostMessage.run(id: "f1", state: WireSamples.run))
        let newer = try #require(String(data: json, encoding: .utf8)).replacingOccurrences(of: "\"working\"", with: "\"dreaming\"")
        guard case .message(.run(_, let state)) = try Remote.read(fromMac: Data(newer.utf8)) else {
            Issue.record("The run wasn't read")
            return
        }
        #expect(state.sessions["c1"] == .idle)
        // A flow's file is still read strictly: a word nobody knows there is an error, not a guess.
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SessionState.self, from: Data("\"dreaming\"".utf8)) }
    }

    @Test func aMessageOfAnUnknownKindIsPassedOver() throws {
        #expect(try Remote.read(fromMac: Data(#"{"hologram":{"id":"f1"}}"#.utf8)) == .unknown)
    }

    /// A kind of message this app knows, that it still can't read: the two apps don't agree, and the device says to update.
    @Test func aKnownMessageThatCantBeReadIsAnError() {
        #expect(throws: (any Error).self) { try Remote.read(fromMac: Data(#"{"answer":{"id":"one"}}"#.utf8)) }
        #expect(throws: (any Error).self) { try Remote.read(fromMac: Data("not json".utf8)) }
    }

    // MARK: Earlier runs

    private func record(_ id: String, outcome: RunRecord.Outcome = .finished) -> RunRecord {
        RunRecord(id: id, started: WireSamples.at, ended: WireSamples.at, outcome: outcome, command: "", log: [], results: [:], marks: [:],
                  linkPasses: [:], messages: [:], handOffs: 0)
    }

    @Test func aRunEndingSendsOnlyThatRun() throws {
        var old = WireSamples.snapshot
        old.runs = (1...20).map { record("r\($0)") }
        var new = old
        new.runs = Array(old.runs.dropFirst()) + [record("r21")]
        let updates = RemoteSnapshot.updates(from: old, to: new, revision: 1, historyChanges: true)
        #expect(updates == [.historyChanged(id: "f1", runs: [record("r21")], order: (2...21).map { "r\($0)" })])
        // A device that doesn't take it is still sent the whole list.
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.history(id: "f1", runs: new.runs)])
        // And what the device ends up with is the Mac's list.
        var mirror = RemoteMirror()
        mirror.willOpen("f1")
        _ = mirror.apply(.opened(old))
        updates.forEach { _ = mirror.apply($0) }
        #expect(mirror.snapshot?.runs == new.runs)
    }

    @Test func aRunChangedInPlaceIsSentAgain() {
        let change = RemoteSnapshot.historyChange(from: [record("a"), record("b")], to: [record("a"), record("b", outcome: .failed)])
        #expect(change.runs == [record("b", outcome: .failed)])
        #expect(change.order == ["a", "b"])
        // A clear empties it.
        #expect(RemoteSnapshot.applying([], order: [], to: [record("a")]) == [])
        // A run the device never had can't be made up, and is left out.
        #expect(RemoteSnapshot.applying([], order: ["a", "z"], to: [record("a")]) == [record("a")])
    }
}

@Suite struct CommandMemoryTests {
    @Test func aCommandSentAgainIsAnsweredAsBeforeAndNotDoneTwice() {
        var memory = CommandMemory<String>()
        #expect(memory.arrive(device: "d", epoch: "e", id: 1, waiter: "first") == .new)
        // Sent again on a new connection while the first is still being done.
        #expect(memory.arrive(device: "d", epoch: "e", id: 1, waiter: "second") == .running)
        #expect(memory.finish(device: "d", epoch: "e", id: 1, refusal: nil) == ["second"])
        #expect(memory.arrive(device: "d", epoch: "e", id: 1, waiter: "third") == .done(nil))
        // A refusal is remembered as one.
        #expect(memory.arrive(device: "d", epoch: "e", id: 2, waiter: "x") == .new)
        #expect(memory.finish(device: "d", epoch: "e", id: 2, refusal: "No") == [])
        #expect(memory.arrive(device: "d", epoch: "e", id: 2, waiter: "x") == .done("No"))
    }

    /// The same id from another device, or from the same device started afresh, is another command.
    @Test func idsBelongToTheirDeviceAndEpoch() {
        var memory = CommandMemory<Int>()
        _ = memory.arrive(device: "d", epoch: "e", id: 1, waiter: 0)
        _ = memory.finish(device: "d", epoch: "e", id: 1, refusal: nil)
        #expect(memory.arrive(device: "other", epoch: "e", id: 1, waiter: 0) == .new)
        #expect(memory.arrive(device: "d", epoch: "later", id: 1, waiter: 0) == .new)
        // A new epoch forgets the old one's.
        #expect(memory.count(of: "d") == 1)
        #expect(memory.finish(device: "d", epoch: "e", id: 1, refusal: nil) == [])
        memory.forget(device: "d")
        #expect(memory.count(of: "d") == 0)
    }

    @Test func onlyTheNewestAreKept() {
        var memory = CommandMemory<Int>(kept: 3)
        for id in 1...5 {
            _ = memory.arrive(device: "d", epoch: "e", id: id, waiter: 0)
            _ = memory.finish(device: "d", epoch: "e", id: id, refusal: nil)
        }
        #expect(memory.count(of: "d") == 3)
        #expect(memory.arrive(device: "d", epoch: "e", id: 5, waiter: 0) == .done(nil))
        #expect(memory.arrive(device: "d", epoch: "e", id: 1, waiter: 0) == .new)
    }

    /// One still being done outlasts older ones that are done.
    @Test func oneStillBeingDoneIsKeptLongest() {
        var memory = CommandMemory<Int>(kept: 2)
        _ = memory.arrive(device: "d", epoch: "e", id: 1, waiter: 0)
        _ = memory.arrive(device: "d", epoch: "e", id: 2, waiter: 0)
        _ = memory.finish(device: "d", epoch: "e", id: 2, refusal: nil)
        _ = memory.arrive(device: "d", epoch: "e", id: 3, waiter: 0)
        #expect(memory.arrive(device: "d", epoch: "e", id: 1, waiter: 9) == .running)
        #expect(memory.finish(device: "d", epoch: "e", id: 1, refusal: nil) == [9])
    }
}
