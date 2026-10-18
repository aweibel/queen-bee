import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RemoteSnapshotTests {
    private func base() throws -> RemoteFlowSnapshot {
        var flow = Flow(name: "Demo")
        _ = try flow.addCard(kind: .start, x: 10, y: 20)
        let run = RemoteRunState(isRunning: false, marks: [:], linkPasses: [:], liveLinkIDs: [], handOffs: 0, holds: [],
                                 results: [:], usage: [:], sessions: [:], awaitingAnswer: [], banner: nil)
        return RemoteFlowSnapshot(flow: flow, run: run, log: [LogLine(date: Date(timeIntervalSince1970: 1), text: "one")],
                                  messages: ["l": [LinkMessage(date: Date(timeIntervalSince1970: 2), from: "A", text: "hi")]], runs: [])
    }

    @Test func nothingChangedSendsNothing() throws {
        let old = try base()
        #expect(RemoteSnapshot.updates(from: old, to: old, revision: 1).isEmpty)
    }

    @Test func aMovedCardSendsOnlyTheFlow() throws {
        let old = try base()
        var new = old
        new.flow.cards[0].x = 99
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 7) == [.flow(id: old.flow.id, revision: 7, flow: new.flow)])
    }

    @Test func aRunChangeSendsOnlyTheRunState() throws {
        let old = try base()
        var new = old
        new.run.isRunning = true
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.run(id: old.flow.id, state: new.run)])
    }

    @Test func undoAndSchedulesAreSentAloneAndSmall() throws {
        let old = try base()
        var new = old
        new.edit.undo = "Undo Move"
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.edit(id: old.flow.id, state: new.edit)])
        var later = new
        later.edit.armed = [old.flow.cards[0].id]
        later.edit.nextFires = [old.flow.cards[0].id: Date(timeIntervalSince1970: 60)]
        #expect(RemoteSnapshot.updates(from: new, to: later, revision: 1) == [.edit(id: old.flow.id, state: later.edit)])
        // Neither the flow nor the run's state is sent again for it.
        let sent = try Remote.encode(HostMessage.edit(id: old.flow.id, state: later.edit))
        #expect(sent.count < 200)
    }

    @Test func anEditSendsTheFlowAndThenItsUndo() throws {
        let old = try base()
        var new = old
        new.flow.cards[0].x = 99
        new.edit.undo = "Undo Move"
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 2)
                == [.flow(id: old.flow.id, revision: 2, flow: new.flow), .edit(id: old.flow.id, state: new.edit)])
    }

    @Test func newLogLinesAreSentAlone() throws {
        let old = try base()
        var new = old
        let added = LogLine(date: Date(timeIntervalSince1970: 3), text: "two")
        new.log.append(added)
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.log(id: old.flow.id, lines: [added], reset: false)])
    }

    @Test func aClearedLogIsSentWhole() throws {
        let old = try base()
        var new = old
        new.log = [LogLine(date: Date(timeIntervalSince1970: 9), text: "fresh")]
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.log(id: old.flow.id, lines: new.log, reset: true)])
    }

    /// Past the cap the oldest line goes as each new one comes. Only the new lines are sent, not the whole log again.
    @Test func aLogAtItsCapSendsOnlyItsNewLines() throws {
        var old = try base()
        old.log = (0..<LogLine.mostKept).map { LogLine(date: Date(timeIntervalSince1970: Double($0)), text: "line \($0)") }
        var new = old
        let added = [LogLine(date: Date(timeIntervalSince1970: 9_000), text: "a"), LogLine(date: Date(timeIntervalSince1970: 9_001), text: "b")]
        new.log = Array((old.log + added).suffix(LogLine.mostKept))
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.log(id: old.flow.id, lines: added, reset: false)])
        // And the device, adding them, holds what the Mac holds.
        #expect(RemoteSnapshot.appending(added, to: old.log) == new.log)
    }

    @Test func aLogThatSharesNothingWithTheOldOneIsSentWhole() throws {
        var old = try base()
        old.log = (0..<LogLine.mostKept).map { LogLine(date: Date(timeIntervalSince1970: Double($0)), text: "line \($0)") }
        var new = old
        // Each line has an id of its own, so the same words are not the same lines.
        new.log = old.log.map { LogLine(date: $0.date, text: $0.text) }
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.log(id: old.flow.id, lines: new.log, reset: true)])
        // Lines that went from the start of a log under its cap aren't dropped by the device on its own, so that is sent whole too.
        var short = old
        short.log = Array(old.log.dropFirst(10)) + [LogLine(date: Date(timeIntervalSince1970: 9_000), text: "a")]
        #expect(RemoteSnapshot.updates(from: old, to: short, revision: 1) == [.log(id: old.flow.id, lines: short.log, reset: true)])
    }

    @Test func onlyChangedLinksAreSent() throws {
        let old = try base()
        var new = old
        new.messages["m"] = [LinkMessage(date: Date(timeIntervalSince1970: 4), from: "B", text: "yo")]
        new.messages["l"] = nil
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [
            .messages(id: old.flow.id, link: "l", all: []),
            .messages(id: old.flow.id, link: "m", all: new.messages["m"]!),
        ])
    }

    @Test func aFinishedRunSendsTheHistory() throws {
        let old = try base()
        var new = old
        new.runs = [RunRecord(id: "r", started: Date(timeIntervalSince1970: 1), ended: Date(timeIntervalSince1970: 2), outcome: .finished,
                              command: "go", log: [], results: [:], marks: [:], linkPasses: [:], messages: [:], handOffs: 0)]
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.history(id: old.flow.id, runs: new.runs)])
    }
}
