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

    @Test func aCommandADeviceWroteIsAllowedAtTheMacOnly() throws {
        let fromFile = PendingHold(id: "h", cardID: "c", kind: .script, text: "msg", from: "Start", command: "ls", needsAllow: true)
        var fromDevice = fromFile
        fromDevice.allowOnMac = true
        #expect(fromFile.canBeAllowedFromDevice)
        #expect(!fromDevice.canBeAllowedFromDevice)
        #expect(try JSONDecoder().decode(PendingHold.self, from: JSONEncoder().encode(fromDevice)) == fromDevice)
        // A hold as an older Mac sends it, with nothing said about where the command came from.
        let older = Data(#"{"id":"h","cardID":"c","kind":"script","text":"msg","from":"Start","command":"ls","needsAllow":true}"#.utf8)
        #expect(try JSONDecoder().decode(PendingHold.self, from: older) == fromFile)
        // And nothing is added to a hold that has nothing to say about it.
        #expect(!String(decoding: try JSONEncoder().encode(fromFile), as: UTF8.self).contains("allowOnMac"))
        // An approval, or a command already allowed, is not a command to allow.
        #expect(!PendingHold(id: "h", cardID: "c", kind: .approval, text: "ok?", from: "A").canBeAllowedFromDevice)
        #expect(!PendingHold(id: "h", cardID: "c", kind: .script, text: "m", from: "A", command: "ls").canBeAllowedFromDevice)
    }

    @Test func sessionStatesKeepTheirNames() {
        #expect(SessionState(rawValue: "needsYou") == .needsYou)
        #expect(SessionState.needsYou.label == "Needs you")
        #expect("\(FlowActivity.needsYou)" == "needsYou")
    }
}

@Suite struct RunNumberTests {
    private func run(_ number: Int?) -> RunRecord {
        RunRecord(id: UUID().uuidString, started: Date(), ended: Date(), outcome: .finished, command: "", log: [],
                  results: [:], marks: [:], linkPasses: [:], messages: [:], handOffs: 0, number: number)
    }

    @Test func theFirstRunIsOne() {
        #expect(RunRecord.nextNumber(after: []) == 1)
    }

    @Test func numbersCarryOnPastTheHighest() {
        #expect(RunRecord.nextNumber(after: [run(7), run(8)]) == 9)
    }

    /// Runs kept before numbering count as numbered by their place, so the first numbered run follows them.
    @Test func runsFromBeforeNumberingAreCounted() {
        #expect(RunRecord.nextNumber(after: [run(nil), run(nil), run(nil)]) == 4)
    }

    @Test func aRunWithoutANumberStillReads() throws {
        let data = try JSONEncoder().encode(run(nil))
        #expect(!String(decoding: data, as: UTF8.self).contains("number"))
        #expect(try JSONDecoder().decode(RunRecord.self, from: data).number == nil)
    }
}
