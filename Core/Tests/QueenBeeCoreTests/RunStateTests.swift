import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RunStateTests {
    @Test func aRunRecordSurvivesEncoding() throws {
        var mark = RunMark()
        mark.arrivals = 2
        mark.ports = ["yes": 1]
        mark.lastPort = "yes"
        let record = RunRecord(id: "r1", started: Date(timeIntervalSince1970: 10), ended: Date(timeIntervalSince1970: 20),
                               outcome: .finished, command: "go", log: [LogLine(date: Date(timeIntervalSince1970: 11), text: "started")],
                               results: ["end": "done"], marks: ["a": mark], linkPasses: ["l0": 1],
                               messages: ["l0": [LinkMessage(date: Date(timeIntervalSince1970: 12), from: "Alice", text: "hi")]],
                               handOffs: 1, usage: ["a": Usage(cost: 0.5, input: 10, output: 20)])
        let back = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        #expect(back == record)
        #expect(back.cost.cost == 0.5)
    }

    @Test func usageAddsAndFormats() {
        let total = Usage(cost: 0.004, input: 600) + Usage(cost: 0.004, output: 600)
        #expect(total.tokens == 1200)
        #expect(total.price == "<$0.01")
        #expect(total.tokenCount == "1k tokens")
        #expect(Usage(cost: 2, input: 5).since(Usage(cost: 3, input: 1)) == Usage(cost: 0, input: 4))
    }

    @Test func aHoldSurvivesEncoding() throws {
        let hold = PendingHold(id: "h", cardID: "c", kind: .script, text: "msg", from: "Alice", command: "ls", needsAllow: true)
        #expect(try JSONDecoder().decode(PendingHold.self, from: JSONEncoder().encode(hold)) == hold)
    }

    @Test func sessionStatesKeepTheirNames() {
        #expect(SessionState(rawValue: "needsYou") == .needsYou)
        #expect(SessionState.needsYou.label == "Needs you")
        #expect("\(FlowActivity.needsYou)" == "needsYou")
    }
}
