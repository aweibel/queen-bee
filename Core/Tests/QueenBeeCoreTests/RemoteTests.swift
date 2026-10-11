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
                RemoteFlowSummary(id: flow.id, name: "Demo", isSubflow: false, activity: .running)])])),
            .opened(snapshot),
            .flow(id: flow.id, revision: 4, flow: flow),
            .run(id: flow.id, state: run),
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

    @Test func bothSidesAreOnTheVersionThatHasCommands() {
        #expect(Remote.version == 2)
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
        #expect(Remote.oneLine("Keith's iPad") == "Keith's iPad")
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
