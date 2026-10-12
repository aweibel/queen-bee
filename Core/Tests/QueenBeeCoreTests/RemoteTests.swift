import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RemoteTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try Remote.decode(T.self, from: Remote.encode(value))
    }

    @Test func hostMessagesSurviveEncoding() throws {
        var flow = Flow(name: "Demo")
        _ = try flow.addCard(kind: .start, x: 10, y: 20)
        let run = RemoteRunState(isRunning: true, marks: ["a": RunMark()], linkPasses: ["l": 2], liveLinkIDs: ["l"], handOffs: 3,
                                 holds: [PendingHold(id: "h", cardID: "a", kind: .approval, text: "ok?", from: "Alice")],
                                 results: ["e": "done"], usage: ["a": Usage(cost: 1)], sessions: ["a": .working],
                                 awaitingAnswer: ["a"], banner: "careful")
        let snapshot = RemoteFlowSnapshot(flow: flow, run: run, log: [LogLine(date: Date(timeIntervalSince1970: 1), text: "x")],
                                          messages: [:], runs: [])
        let messages: [HostMessage] = [
            .welcome(RemoteWelcome(version: Remote.version, macName: "Mac", canControl: false)),
            .refused("no"),
            .library(RemoteLibrary(projects: [RemoteProject(id: "p", name: "proj", flows: [
                RemoteFlowSummary(id: flow.id, name: "Demo", isSubflow: false, activity: .running)])],
                                   roles: [RemoteRole(id: "r", name: "Reviewer")])),
            .opened(snapshot),
            .flow(id: flow.id, revision: 4, flow: flow),
            .run(id: flow.id, state: run),
            .edit(id: flow.id, state: RemoteEditState(undo: "Undo Move", redo: nil, armed: ["a"], nextFires: ["a": Date(timeIntervalSince1970: 9)])),
            .log(id: flow.id, lines: snapshot.log, reset: false),
            .messages(id: flow.id, link: "l", all: [LinkMessage(date: Date(timeIntervalSince1970: 2), from: "Alice", text: "hi")]),
            .history(id: flow.id, runs: []),
            .terminal(id: flow.id, key: "a", chunk: TerminalChunk(reset: true, cols: 80, rows: 24, data: Data([27, 91, 72]))),
            .answer(id: 7, refusal: nil),
            .answer(id: 8, refusal: "No run is going."),
            .control(canControl: true),
        ]
        for message in messages { #expect(try roundTrip(message) == message) }
    }

    @Test func deviceAndPairingMessagesSurviveEncoding() throws {
        let hello = DeviceMessage.hello(RemoteHello(version: Remote.version, deviceID: "d", deviceName: "iPad"))
        #expect(try roundTrip(hello) == hello)
        #expect(try roundTrip(DeviceMessage.open(flowID: nil)) == .open(flowID: nil))
        let request = PairRequest(version: Remote.version, deviceID: "d", deviceName: "iPad")
        #expect(try roundTrip(request) == request)
        let reply = PairReply.granted(PairGrant(key: Data([1, 2, 3]), deviceID: "d", macID: "m", macName: "Mac"))
        #expect(try roundTrip(reply) == reply)
        #expect(try roundTrip(PairReply.refused("old")) == .refused("old"))
    }

    @Test func junkDoesNotDecode() {
        #expect(throws: (any Error).self) { try Remote.decode(HostMessage.self, from: Data("{}".utf8)) }
    }

    @Test func bothSidesAreOnTheVersionThatHasEditing() {
        #expect(Remote.version == 3)
    }
}

@Suite struct RemoteCommandTests {
    private let all: [RemoteCommand] = [
        .openOnMac(flowID: "f"),
        .run(flowID: "f", command: nil),
        .run(flowID: "f", command: "go"),
        .runFrom(flowID: "f", cardID: "c", text: "again"),
        .stop(flowID: "f"),
        .approve(flowID: "f", holdID: "h", text: "fine"),
        .reject(flowID: "f", holdID: "h", note: ""),
        .allowScript(flowID: "f", holdID: "h"),
        .refuseScript(flowID: "f", holdID: "h"),
        .startSession(flowID: "f", cardID: "c"),
        .prompt(flowID: "f", key: Remote.orchestratorKey, text: "hello\nthere"),
        .keys(flowID: "f", key: "c", data: Data([27, 3, 13])),
    ]

    @Test func everyCommandSurvivesEncoding() throws {
        for (id, command) in all.enumerated() {
            let message = DeviceMessage.command(id: id, command: command)
            #expect(try Remote.decode(DeviceMessage.self, from: Remote.encode(message)) == message)
        }
    }

    @Test func everyCommandNamesItsFlowAndIsFineAsItIs() {
        for command in all {
            #expect(command.flowID == "f")
            #expect(command.problem == nil)
        }
    }

    @Test func theEncodingNamesItsParts() throws {
        let data = try Remote.encode(DeviceMessage.command(id: 3, command: .prompt(flowID: "f", key: "c", text: "hi")))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let command = try #require(json["command"])
        #expect(command["id"] as? Int == 3)
        let prompt = try #require((command["command"] as? [String: [String: String]])?["prompt"])
        #expect(prompt == ["flowID": "f", "key": "c", "text": "hi"])
    }

    @Test func aCommandTheMacDoesNotKnowDoesNotDecode() {
        let unknown = #"{"command":{"id":1,"command":{"addProject":{"path":"/tmp"}}}}"#
        #expect(throws: (any Error).self) { try Remote.decode(DeviceMessage.self, from: Data(unknown.utf8)) }
        let partsMissing = #"{"command":{"id":1,"command":{"prompt":{"flowID":"f"}}}}"#
        #expect(throws: (any Error).self) { try Remote.decode(DeviceMessage.self, from: Data(partsMissing.utf8)) }
        let noID = #"{"command":{"command":{"stop":{"flowID":"f"}}}}"#
        #expect(throws: (any Error).self) { try Remote.decode(DeviceMessage.self, from: Data(noID.utf8)) }
    }

    @Test func aPromptHasToSaySomethingAndFit() {
        #expect(RemoteCommand.prompt(flowID: "f", key: "c", text: "").problem != nil)
        #expect(RemoteCommand.prompt(flowID: "f", key: "c", text: " \n ").problem != nil)
        let most = String(repeating: "a", count: Remote.promptLimit)
        #expect(RemoteCommand.prompt(flowID: "f", key: "c", text: most).problem == nil)
        #expect(RemoteCommand.prompt(flowID: "f", key: "c", text: most + "a").problem?.contains("too long") == true)
    }

    @Test func everyOtherTextHasTheSameLimit() {
        let long = String(repeating: "a", count: Remote.promptLimit + 1)
        #expect(RemoteCommand.run(flowID: "f", command: long).problem != nil)
        #expect(RemoteCommand.runFrom(flowID: "f", cardID: "c", text: long).problem != nil)
        #expect(RemoteCommand.approve(flowID: "f", holdID: "h", text: long).problem != nil)
        #expect(RemoteCommand.reject(flowID: "f", holdID: "h", note: long).problem != nil)
    }

    @Test func keysHaveToBeSomeAndFit() {
        #expect(RemoteCommand.keys(flowID: "f", key: "c", data: Data()).problem != nil)
        #expect(RemoteCommand.keys(flowID: "f", key: "c", data: Data(count: Remote.keysLimit)).problem == nil)
        #expect(RemoteCommand.keys(flowID: "f", key: "c", data: Data(count: Remote.keysLimit + 1)).problem != nil)
    }

    @Test func theBiggestCommandsFitInWhatTheMacTakesFromADevice() throws {
        // The Mac takes no more than 64 KB in one message from a device.
        let limit = 64 * 1024
        let keys = DeviceMessage.command(id: 1, command: .keys(flowID: UUID().uuidString, key: UUID().uuidString, data: Data(count: Remote.keysLimit)))
        #expect(try Remote.encode(keys).count < limit)
        let prompt = DeviceMessage.command(id: 1, command: .prompt(flowID: UUID().uuidString, key: UUID().uuidString,
                                                                   text: String(repeating: "a", count: Remote.promptLimit)))
        #expect(try Remote.encode(prompt).count < limit)
    }

    @Test func aDevicesNameGoesInTheLogOnOneLine() {
        #expect(Remote.oneLine("Sam's iPad") == "Sam's iPad")
        #expect(Remote.oneLine("iPad\nRun finished") == "iPad Run finished")
        #expect(Remote.oneLine("a\u{2028}b\u{1b}[2Jc\r\td") == "a b [2Jc d")
        #expect(Remote.oneLine("\n\n") == "a device")
    }

    @Test func textFromADeviceCanNotEndThePasteItIsEnteredIn() {
        #expect(Remote.plainText("Fix the login page") == "Fix the login page")
        #expect(Remote.plainText("one\n\ttwo") == "one\n\ttwo")
        // The end of a bracketed paste, and whatever would follow it as keys.
        #expect(Remote.plainText("hi\u{1b}[201~\u{3}rm -rf\r") == "hi[201~rm -rf\n")
        #expect(Remote.plainText("a\u{0}b\u{7}c\u{8}d\u{7f}e\u{9b}f") == "abcdef")
        #expect(Remote.plainText("one\r\ntwo\rthree") == "one\ntwo\nthree")
        #expect(Remote.plainText("caf\u{e9} \u{1F41D} \u{4f60}") == "caf\u{e9} \u{1F41D} \u{4f60}")
        #expect(Remote.plainText("\u{1b}\u{1b}") == "")
    }

    @Test func aCommandIsCleanedOfWhatATerminalWouldActOn() {
        let bad = "go\u{1b}[201~"
        #expect(RemoteCommand.prompt(flowID: "f", key: "c", text: bad).cleaned == .prompt(flowID: "f", key: "c", text: "go[201~"))
        #expect(RemoteCommand.run(flowID: "f", command: bad).cleaned == .run(flowID: "f", command: "go[201~"))
        #expect(RemoteCommand.run(flowID: "f", command: nil).cleaned == .run(flowID: "f", command: nil))
        #expect(RemoteCommand.runFrom(flowID: "f", cardID: "c", text: bad).cleaned == .runFrom(flowID: "f", cardID: "c", text: "go[201~"))
        #expect(RemoteCommand.approve(flowID: "f", holdID: "h", text: bad).cleaned == .approve(flowID: "f", holdID: "h", text: "go[201~"))
        #expect(RemoteCommand.reject(flowID: "f", holdID: "h", note: bad).cleaned == .reject(flowID: "f", holdID: "h", note: "go[201~"))
        // Keys are keys: Esc is one of them.
        let keys = RemoteCommand.keys(flowID: "f", key: "c", data: Data([27, 3]))
        #expect(keys.cleaned == keys)
        // Text that was nothing but control characters is nothing to send.
        #expect(RemoteCommand.prompt(flowID: "f", key: "c", text: "\u{1b}\u{7}").cleaned.problem != nil)
    }

    @Test func onlyStartingAndStoppingARunCanTakeTime() {
        #expect(RemoteCommand.run(flowID: "f", command: nil).canTakeTime)
        #expect(RemoteCommand.runFrom(flowID: "f", cardID: "c", text: "x").canTakeTime)
        #expect(RemoteCommand.stop(flowID: "f").canTakeTime)
        #expect(!RemoteCommand.prompt(flowID: "f", key: "c", text: "x").canTakeTime)
        #expect(!RemoteCommand.keys(flowID: "f", key: "c", data: Data([1])).canTakeTime)
        #expect(!RemoteCommand.approve(flowID: "f", holdID: "h", text: "x").canTakeTime)
        #expect(!RemoteCommand.openOnMac(flowID: "f").canTakeTime)
    }
}

/// The commands that change a flow. Stage 3.
@Suite struct RemoteEditCommandTests {
    private static var patch: RemoteCardPatch {
        var patch = RemoteCardPatch()
        patch.name = "Writer"
        patch.instructions = "Write it.\nThen stop."
        patch.trigger = Trigger(kind: .daily, hour: 7)
        patch.branches = ["bug", "feature"]
        patch.check = .notContains
        return patch
    }

    private let all: [RemoteCommand] = [
        .addCard(flowID: "f", kind: .ifElse, x: 10, y: -20),
        .moveCards(flowID: "f", moves: ["a": RemotePoint(x: 1, y: 2), "b": RemotePoint(x: 3, y: 4)], final: false),
        .moveCards(flowID: "f", moves: ["a": RemotePoint(x: 1, y: 2)], final: true),
        .resizeCard(flowID: "f", cardID: "a", frame: RemoteFrame(x: 1, y: 2, width: 300, height: 200), final: true),
        .deleteItems(flowID: "f", cardIDs: ["a"], linkIDs: ["l"]),
        .addLink(flowID: "f", from: "a", port: "out", to: "b"),
        .setLinkLimit(flowID: "f", linkID: "l", maxPasses: 5),
        .duplicate(flowID: "f", cardIDs: ["a", "b"]),
        .tidy(flowID: "f"),
        .group(flowID: "f", cardIDs: ["a", "b"], name: ""),
        .ungroup(flowID: "f", groupID: "g"),
        .renameGroup(flowID: "f", groupID: "g", name: "Review"),
        .foldGroup(flowID: "f", groupID: "g", folded: true),
        .patchCard(flowID: "f", cardID: "a", patch: patch),
        .setFlowOption(flowID: "f", option: .subflowLimit(levels: 2)),
        .setFlowOption(flowID: "f", option: .notifyOrchestrator(on: false)),
        .renameFlow(flowID: "f", name: "Morning"),
        .deleteFlow(flowID: "f"),
        .undo(flowID: "f"),
        .redo(flowID: "f"),
    ]

    @Test func everyEditSurvivesEncodingNamesItsFlowAndIsFineAsItIs() throws {
        for (id, command) in all.enumerated() {
            let message = DeviceMessage.command(id: id, command: command)
            #expect(try Remote.decode(DeviceMessage.self, from: Remote.encode(message)) == message)
            #expect(command.flowID == "f")
            #expect(command.problem == nil)
            #expect(command.isEdit)
            #expect(!command.canTakeTime)
        }
    }

    @Test func aNewFlowNamesItsProjectAndNoFlow() throws {
        let command = RemoteCommand.newFlow(projectID: "p", name: "")
        #expect(command.flowID == nil)
        #expect(command.isEdit)
        #expect(command.problem == nil)
        let message = DeviceMessage.command(id: 1, command: command)
        #expect(try Remote.decode(DeviceMessage.self, from: Remote.encode(message)) == message)
    }

    @Test func whatStage2CouldDoIsNotAnEdit() {
        #expect(!RemoteCommand.run(flowID: "f", command: nil).isEdit)
        #expect(!RemoteCommand.stop(flowID: "f").isEdit)
        #expect(!RemoteCommand.keys(flowID: "f", key: "c", data: Data([1])).isEdit)
        #expect(!RemoteCommand.allowScript(flowID: "f", holdID: "h").isEdit)
    }

    @Test func theEncodingNamesAnEditsParts() throws {
        let data = try Remote.encode(RemoteCommand.moveCards(flowID: "f", moves: ["a": RemotePoint(x: 1, y: 2)], final: true))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        let move = try #require(json["moveCards"])
        #expect(move["flowID"] as? String == "f")
        #expect(move["final"] as? Bool == true)
        #expect(move["moves"] as? [String: [String: Double]] == ["a": ["x": 1, "y": 2]])
    }

    // MARK: Drags

    @Test func onlyTheLastStepOfADragIsAnswered() {
        let step = RemoteCommand.moveCards(flowID: "f", moves: ["a": RemotePoint(x: 1, y: 2)], final: false)
        let last = RemoteCommand.moveCards(flowID: "f", moves: ["a": RemotePoint(x: 1, y: 2)], final: true)
        #expect(!step.isAnswered)
        #expect(last.isAnswered)
        #expect(step.dragStep?.drag == .move)
        #expect(step.dragStep?.isLast == false)
        #expect(last.dragStep?.isLast == true)
        let frame = RemoteFrame(x: 0, y: 0, width: 300, height: 200)
        let resize = RemoteCommand.resizeCard(flowID: "f", cardID: "a", frame: frame, final: false)
        #expect(!resize.isAnswered)
        #expect(resize.dragStep?.drag == .resize(cardID: "a"))
        #expect(RemoteCommand.resizeCard(flowID: "f", cardID: "a", frame: frame, final: true).isAnswered)
        for command in all where command.dragStep == nil { #expect(command.isAnswered) }
        #expect(RemoteCommand.stop(flowID: "f").isAnswered)
    }

    // MARK: Places and sizes

    @Test func aCardCanNotBePutNowhere() {
        func add(_ x: Double, _ y: Double) -> RemoteCommand { .addCard(flowID: "f", kind: .note, x: x, y: y) }
        #expect(add(0, 0).problem == nil)
        #expect(add(-2_900, Remote.farthestPoint).problem == nil)
        #expect(add(.nan, 0).problem != nil)
        #expect(add(0, .infinity).problem != nil)
        #expect(add(Remote.farthestPoint + 1, 0).problem != nil)
        #expect(add(0, -1e300).problem != nil)
        func move(_ x: Double) -> RemoteCommand { .moveCards(flowID: "f", moves: ["a": RemotePoint(x: 0, y: 0), "b": RemotePoint(x: x, y: 0)], final: true) }
        #expect(move(50).problem == nil)
        #expect(move(.nan).problem != nil)
        #expect(move(-.infinity).problem != nil)
        #expect(move(1e9).problem != nil)
        #expect(RemoteCommand.moveCards(flowID: "f", moves: [:], final: true).problem != nil)
    }

    @Test func aCardCanNotBeMadeAnAbsurdSize() {
        func resize(_ frame: RemoteFrame) -> RemoteCommand { .resizeCard(flowID: "f", cardID: "a", frame: frame, final: true) }
        #expect(resize(RemoteFrame(x: 0, y: 0, width: 1, height: 1)).problem == nil)
        #expect(resize(RemoteFrame(x: 0, y: 0, width: Remote.largestSide, height: 200)).problem == nil)
        #expect(resize(RemoteFrame(x: 0, y: 0, width: Remote.largestSide + 1, height: 200)).problem != nil)
        #expect(resize(RemoteFrame(x: 0, y: 0, width: 300, height: 0)).problem != nil)
        #expect(resize(RemoteFrame(x: 0, y: 0, width: -300, height: 200)).problem != nil)
        #expect(resize(RemoteFrame(x: 0, y: 0, width: .nan, height: 200)).problem != nil)
        #expect(resize(RemoteFrame(x: 0, y: 0, width: 300, height: .infinity)).problem != nil)
        #expect(resize(RemoteFrame(x: .nan, y: 0, width: 300, height: 200)).problem != nil)
        #expect(resize(RemoteFrame(x: 0, y: 1e9, width: 300, height: 200)).problem != nil)
    }

    // MARK: Sizes

    @Test func namesAndLongTextAreCapped() {
        let name = String(repeating: "n", count: Remote.nameLimit), text = String(repeating: "t", count: Remote.textLimit)
        func patch(_ change: (inout RemoteCardPatch) -> Void) -> RemoteCommand {
            var patch = RemoteCardPatch()
            change(&patch)
            return .patchCard(flowID: "f", cardID: "a", patch: patch)
        }
        #expect(Remote.nameLimit == 200)
        #expect(Remote.textLimit == 16_000)
        #expect(patch { $0.name = name }.problem == nil)
        #expect(patch { $0.name = name + "n" }.problem?.contains("too long") == true)
        #expect(patch { $0.model = name + "n" }.problem != nil)
        #expect(patch { $0.flowRef = name + "n" }.problem != nil)
        #expect(patch { $0.role = name + "n" }.problem != nil)
        #expect(patch { $0.branches = ["ok", name + "n"] }.problem != nil)
        #expect(patch { $0.branches = Array(repeating: "b", count: Remote.branchLimit + 1) }.problem != nil)
        for field in [\RemoteCardPatch.instructions, \.command, \.value, \.template, \.text] {
            #expect(patch { $0[keyPath: field] = text }.problem == nil)
            #expect(patch { $0[keyPath: field] = text + "t" }.problem?.contains("too long") == true)
        }
        #expect(patch { $0.saveTo = String(repeating: "p", count: Remote.pathLimit + 1) }.problem != nil)
        #expect(patch { $0.trigger = Trigger(kind: .file, path: String(repeating: "p", count: Remote.pathLimit + 1)) }.problem != nil)
        #expect(RemoteCommand.renameGroup(flowID: "f", groupID: "g", name: name + "n").problem != nil)
        #expect(RemoteCommand.group(flowID: "f", cardIDs: ["a", "b"], name: name + "n").problem != nil)
        #expect(RemoteCommand.newFlow(projectID: "p", name: name + "n").problem != nil)
        #expect(RemoteCommand.renameFlow(flowID: "f", name: name).problem == nil)
        #expect(RemoteCommand.renameFlow(flowID: "f", name: name + "n").problem != nil)
        #expect(RemoteCommand.renameFlow(flowID: "f", name: "").problem != nil)
        #expect(RemoteCommand.addLink(flowID: "f", from: "a", port: name + "n", to: "b").problem != nil)
    }

    @Test func noCommandNamesMoreThingsThanAFlowMayHold() {
        #expect(Remote.cardLimit == 200)
        #expect(Remote.linkLimit == 400)
        let cards = (0...Remote.cardLimit).map { "c\($0)" }, links = (0...Remote.linkLimit).map { "l\($0)" }
        #expect(RemoteCommand.deleteItems(flowID: "f", cardIDs: cards, linkIDs: []).problem != nil)
        #expect(RemoteCommand.deleteItems(flowID: "f", cardIDs: [], linkIDs: links).problem != nil)
        #expect(RemoteCommand.deleteItems(flowID: "f", cardIDs: [], linkIDs: []).problem != nil)
        #expect(RemoteCommand.duplicate(flowID: "f", cardIDs: cards).problem != nil)
        #expect(RemoteCommand.duplicate(flowID: "f", cardIDs: []).problem != nil)
        #expect(RemoteCommand.group(flowID: "f", cardIDs: cards, name: "").problem != nil)
        let moves = Dictionary(uniqueKeysWithValues: cards.map { ($0, RemotePoint(x: 0, y: 0)) })
        #expect(RemoteCommand.moveCards(flowID: "f", moves: moves, final: true).problem != nil)
    }

    @Test func theBiggestEditsFitInWhatTheMacTakesFromADevice() throws {
        let limit = 64 * 1024
        var patch = RemoteCardPatch()
        patch.instructions = String(repeating: "a", count: Remote.textLimit)
        patch.name = String(repeating: "n", count: Remote.nameLimit)
        let settings = DeviceMessage.command(id: 1, command: .patchCard(flowID: Flow.newID(), cardID: Flow.newID(), patch: patch))
        #expect(try Remote.encode(settings).count < limit)
        let moves = Dictionary(uniqueKeysWithValues: (0..<Remote.cardLimit).map { _ in (Flow.newID(), RemotePoint(x: -12345.678, y: 98765.432)) })
        let move = DeviceMessage.command(id: 1, command: .moveCards(flowID: Flow.newID(), moves: moves, final: false))
        #expect(try Remote.encode(move).count < limit)
        let delete = DeviceMessage.command(id: 1, command: .deleteItems(
            flowID: Flow.newID(), cardIDs: (0..<Remote.cardLimit).map { _ in Flow.newID() }, linkIDs: (0..<Remote.linkLimit).map { _ in Flow.newID() }))
        #expect(try Remote.encode(delete).count < limit)
    }

    // MARK: Cleaning

    @Test func aNameFromADeviceIsOneCleanLine() {
        #expect(Remote.plainLine("  Writer  ") == "Writer")
        #expect(Remote.plainLine("Writer\nRun finished") == "Writer Run finished")
        #expect(Remote.plainLine("a\u{1b}[2Jb\tc") == "a [2Jb c")
        #expect(Remote.plainLine("\n \u{7}") == "")
    }

    @Test func anEditIsCleanedOfWhatATerminalWouldActOn() {
        let bad = "go\u{1b}[201~\r\nnow"
        var patch = RemoteCardPatch()
        patch.name = bad
        patch.instructions = bad
        patch.command = bad
        patch.template = bad
        patch.text = bad
        patch.value = bad
        patch.saveTo = bad
        patch.model = bad
        patch.branches = [bad, "fine"]
        guard case .patchCard(_, _, let clean) = RemoteCommand.patchCard(flowID: "f", cardID: "a", patch: patch).cleaned else {
            Issue.record("a cleaned patch is still a patch")
            return
        }
        // One-line settings end up on one line. Long text keeps its lines.
        #expect(clean.name == "go [201~ now")
        #expect(clean.saveTo == "go [201~ now")
        #expect(clean.model == "go [201~ now")
        #expect(clean.branches == ["go [201~ now", "fine"])
        for long in [clean.instructions, clean.command, clean.template, clean.text, clean.value] { #expect(long == "go[201~\nnow") }
        #expect(RemoteCommand.renameFlow(flowID: "f", name: " A\u{7}B ").cleaned == .renameFlow(flowID: "f", name: "A B"))
        #expect(RemoteCommand.newFlow(projectID: "p", name: "A\nB").cleaned == .newFlow(projectID: "p", name: "A B"))
        #expect(RemoteCommand.renameGroup(flowID: "f", groupID: "g", name: "A\nB").cleaned == .renameGroup(flowID: "f", groupID: "g", name: "A B"))
        #expect(RemoteCommand.group(flowID: "f", cardIDs: ["a"], name: "\u{1b}").cleaned == .group(flowID: "f", cardIDs: ["a"], name: ""))
        #expect(RemoteCommand.addLink(flowID: "f", from: "a", port: "yes\n", to: "b").cleaned == .addLink(flowID: "f", from: "a", port: "yes", to: "b"))
        // A name that was nothing but control characters is no name.
        #expect(RemoteCommand.renameFlow(flowID: "f", name: "\u{1b}\u{7}").cleaned.problem != nil)
    }

    @Test func aScheduleFromADeviceIsBroughtWithinWhatTheMacOffers() {
        var patch = RemoteCardPatch()
        patch.trigger = Trigger(kind: .weekly, minutes: -5, hour: 99, minute: -1, weekdays: [9, 2, 2, 0, 7], path: "in\nbox")
        let clean = patch.cleaned.trigger
        #expect(clean == Trigger(kind: .weekly, minutes: 1, hour: 23, minute: 0, weekdays: [2, 7], path: "in box"))
        patch.removesTrigger = true
        #expect(patch.problem != nil)
    }

    // MARK: What a device may never change

    @Test func aPatchFromADeviceHasNoFolder() throws {
        // Whatever a device sends, the folder is not among what is read from it.
        let sent = #"{"instructions":"Go","cwd":"/somewhere/else","x":5,"width":9000,"sessionID":"s","armed":true}"#
        let patch = try Remote.decode(RemoteCardPatch.self, from: Data(sent.utf8))
        #expect(patch.instructions == "Go")
        #expect(patch.cardPatch.cwd == nil)
        #expect(patch.cardPatch.x == nil)
        #expect(patch.cardPatch.width == nil)
        let written = try #require(JSONSerialization.jsonObject(with: Remote.encode(patch)) as? [String: Any])
        #expect(Array(written.keys) == ["instructions"])
        // A patch that asked for nothing but the folder asks for nothing.
        let onlyFolder = try Remote.decode(RemoteCardPatch.self, from: Data(#"{"cwd":"/somewhere/else"}"#.utf8))
        #expect(onlyFolder.isEmpty)
        #expect(onlyFolder.problem != nil)
    }

    @Test func applyingAPatchFromADeviceLeavesTheFolderAlone() throws {
        var flow = Flow(name: "Demo")
        var card = try flow.addCard(kind: .agent, name: "Writer")
        var folder = CardPatch()
        folder.cwd = "/chosen/on/the/mac"
        card = try flow.updateCard(card.id, patch: folder)
        var patch = RemoteCardPatch()
        patch.instructions = "New brief"
        patch.model = "haiku"
        let after = try flow.updateCard(card.id, patch: patch.cleaned.cardPatch)
        #expect(after.instructions == "New brief")
        #expect(after.cwd == "/chosen/on/the/mac")
    }

    @Test func aModeThatSkipsPermissionChecksCanNotBeSet() throws {
        var patch = RemoteCardPatch()
        patch.permissionMode = "bypassPermissions"
        #expect(patch.problem?.contains("Unknown permission mode") == true)
        // And the Mac's own gate turns it down, whatever a device's app let through.
        var flow = Flow(name: "Demo")
        let card = try flow.addCard(kind: .agent, name: "Writer")
        #expect(throws: FlowError.self) { try flow.updateCard(card.id, patch: patch.cardPatch) }
        #expect(flow.card(card.id)?.permissionMode == nil)
        for mode in Card.permissionModes + [""] {
            patch.permissionMode = mode
            #expect(patch.problem == nil)
        }
        patch = RemoteCardPatch()
        patch.effort = "ludicrous"
        #expect(patch.problem != nil)
    }

    @Test func aPatchThatChangesNothingIsRefused() {
        #expect(RemoteCommand.patchCard(flowID: "f", cardID: "a", patch: RemoteCardPatch()).problem != nil)
    }
}

@Suite struct RemoteListenerRecordTests {
    private let record = ["mac": "aaaa-1111", "device": "bbbb-2222", "name": "Studio"]

    @Test func aDeviceFindsItsOwnListenerOnItsOwnMac() {
        #expect(Remote.isListener(record, forDevice: "bbbb-2222", ofMac: "aaaa-1111"))
    }

    @Test func capitalsDoNotMatter() {
        #expect(Remote.isListener(record, forDevice: "BBBB-2222", ofMac: "AAAA-1111"))
    }

    @Test func anotherDevicesListenerIsNotIts() {
        #expect(!Remote.isListener(record, forDevice: "cccc-3333", ofMac: "aaaa-1111"))
    }

    @Test func anotherMacIsNotIts() {
        #expect(!Remote.isListener(record, forDevice: "bbbb-2222", ofMac: "dddd-4444"))
    }

    @Test func aRecordWithPartsMissingMatchesNothing() {
        #expect(!Remote.isListener([:], forDevice: "", ofMac: ""))
        #expect(!Remote.isListener(["mac": "aaaa-1111"], forDevice: "bbbb-2222", ofMac: "aaaa-1111"))
    }
}
