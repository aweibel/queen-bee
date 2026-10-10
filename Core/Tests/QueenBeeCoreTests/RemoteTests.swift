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
            .welcome(RemoteWelcome(version: 1, macName: "Mac", canControl: false)),
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
        ]
        for message in messages { #expect(try roundTrip(message) == message) }
    }

    @Test func deviceAndPairingMessagesSurviveEncoding() throws {
        let hello = DeviceMessage.hello(RemoteHello(version: Remote.version, deviceID: "d", deviceName: "iPad"))
        #expect(try roundTrip(hello) == hello)
        #expect(try roundTrip(DeviceMessage.open(flowID: nil)) == .open(flowID: nil))
        let request = PairRequest(version: 1, deviceID: "d", deviceName: "iPad")
        #expect(try roundTrip(request) == request)
        let reply = PairReply.granted(PairGrant(key: Data([1, 2, 3]), deviceID: "d", macID: "m", macName: "Mac"))
        #expect(try roundTrip(reply) == reply)
        #expect(try roundTrip(PairReply.refused("old")) == .refused("old"))
    }

    @Test func junkDoesNotDecode() {
        #expect(throws: (any Error).self) { try Remote.decode(HostMessage.self, from: Data("{}".utf8)) }
    }
}
