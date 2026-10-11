import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RemoteMirrorTests {
    private func line(_ second: Double, _ text: String) -> LogLine { LogLine(date: Date(timeIntervalSince1970: second), text: text) }
    private func said(_ second: Double, _ text: String) -> LinkMessage {
        LinkMessage(date: Date(timeIntervalSince1970: second), from: "A", text: text)
    }
    private func record(_ id: String) -> RunRecord {
        RunRecord(id: id, started: Date(timeIntervalSince1970: 1), ended: Date(timeIntervalSince1970: 2), outcome: .finished,
                  command: "go", log: [], results: [:], marks: [:], linkPasses: [:], messages: [:], handOffs: 0)
    }

    private func base() throws -> RemoteFlowSnapshot {
        var flow = Flow(name: "Demo")
        _ = try flow.addCard(kind: .start, x: 10, y: 20)
        let run = RemoteRunState(isRunning: false, marks: [:], linkPasses: [:], liveLinkIDs: [], handOffs: 0, holds: [],
                                 results: [:], usage: [:], sessions: [:], awaitingAnswer: [], banner: nil)
        return RemoteFlowSnapshot(flow: flow, run: run, log: [line(1, "one")], messages: ["l": [said(2, "hi")]], runs: [])
    }

    /// A mirror that asked for the snapshot's flow and was sent it.
    private func mirror(holding snapshot: RemoteFlowSnapshot) -> RemoteMirror {
        var mirror = RemoteMirror()
        mirror.willOpen(snapshot.flow.id)
        _ = mirror.apply(.opened(snapshot))
        return mirror
    }

    @Test func startsEmpty() {
        let mirror = RemoteMirror()
        #expect(mirror.library == nil)
        #expect(mirror.welcome == nil)
        #expect(mirror.refusal == nil)
        #expect(mirror.openFlowID == nil)
        #expect(mirror.snapshot == nil)
        #expect(mirror.revision == 0)
    }

    @Test func keepsTheWelcomeAndTheLibrary() {
        var mirror = RemoteMirror()
        let welcome = RemoteWelcome(version: Remote.version, macName: "Studio", canControl: false)
        let library = RemoteLibrary(projects: [RemoteProject(id: "p", name: "Work", flows: [
            RemoteFlowSummary(id: "f", name: "Demo", isSubflow: false, activity: .quiet),
        ])])
        #expect(mirror.apply(.welcome(welcome)).isEmpty)
        #expect(mirror.apply(.library(library)).isEmpty)
        #expect(mirror.welcome == welcome)
        #expect(mirror.library == library)
    }

    @Test func keepsARefusalUntilTheNextWelcome() {
        var mirror = RemoteMirror()
        _ = mirror.apply(.refused("Update the app."))
        #expect(mirror.refusal == "Update the app.")
        _ = mirror.apply(.welcome(RemoteWelcome(version: Remote.version, macName: "Studio", canControl: false)))
        #expect(mirror.refusal == nil)
    }

    @Test func openingAFlowClearsWhatWasOnShowUntilTheNewOneArrives() throws {
        let first = try base()
        var mirror = mirror(holding: first)
        _ = mirror.apply(.flow(id: first.flow.id, revision: 4, flow: first.flow))
        #expect(mirror.snapshot == first)
        #expect(mirror.revision == 4)

        var second = try base()
        second.flow.name = "Other"
        mirror.willOpen(second.flow.id)
        #expect(mirror.openFlowID == second.flow.id)
        #expect(mirror.snapshot == nil)
        #expect(mirror.revision == 0)

        _ = mirror.apply(.opened(second))
        #expect(mirror.snapshot == second)
    }

    @Test func closingTheFlowLeavesNothingOpen() throws {
        var mirror = mirror(holding: try base())
        mirror.willOpen(nil)
        #expect(mirror.openFlowID == nil)
        #expect(mirror.snapshot == nil)
    }

    @Test func aSnapshotOfAFlowThatWasNotAskedForIsIgnored() throws {
        let first = try base()
        var late = try base()
        late.flow.name = "Late"
        // The reply to an earlier open can arrive after the person has moved on.
        var mirror = RemoteMirror()
        mirror.willOpen(first.flow.id)
        _ = mirror.apply(.opened(late))
        #expect(mirror.snapshot == nil)

        var none = RemoteMirror()
        _ = none.apply(.opened(first))
        #expect(none.snapshot == nil)
    }

    @Test func aFreshSnapshotOfTheOpenFlowReplacesTheOldOne() throws {
        // After a reconnect the device asks again without clearing what is on screen.
        let old = try base()
        var mirror = mirror(holding: old)
        _ = mirror.apply(.flow(id: old.flow.id, revision: 9, flow: old.flow))
        var fresh = old
        fresh.log = [line(5, "new")]
        _ = mirror.apply(.opened(fresh))
        #expect(mirror.snapshot == fresh)
        #expect(mirror.revision == 0)
    }

    @Test func updatesForAnotherFlowAreIgnored() throws {
        let held = try base()
        var mirror = mirror(holding: held)
        var other = held
        other.flow.name = "Changed"
        other.run.isRunning = true
        let chunk = TerminalChunk(reset: false, cols: 80, rows: 24, data: Data("x".utf8))
        let stray: [HostMessage] = [
            .flow(id: "other", revision: 3, flow: other.flow),
            .run(id: "other", state: other.run),
            .log(id: "other", lines: [line(7, "stray")], reset: true),
            .messages(id: "other", link: "l", all: []),
            .history(id: "other", runs: [record("r")]),
            .terminal(id: "other", key: "k", chunk: chunk),
        ]
        for message in stray { #expect(mirror.apply(message).isEmpty) }
        #expect(mirror.snapshot == held)
        #expect(mirror.revision == 0)
    }

    @Test func updatesBeforeTheSnapshotArrivesAreIgnored() throws {
        let held = try base()
        var mirror = RemoteMirror()
        mirror.willOpen(held.flow.id)
        _ = mirror.apply(.flow(id: held.flow.id, revision: 3, flow: held.flow))
        _ = mirror.apply(.log(id: held.flow.id, lines: [line(7, "early")], reset: false))
        #expect(mirror.snapshot == nil)
        #expect(mirror.revision == 0)
    }

    @Test func logLinesAreAddedOrReplaceTheLog() throws {
        let held = try base()
        var mirror = mirror(holding: held)
        _ = mirror.apply(.log(id: held.flow.id, lines: [line(3, "two")], reset: false))
        #expect(mirror.snapshot?.log.map(\.text) == ["one", "two"])
        _ = mirror.apply(.log(id: held.flow.id, lines: [line(9, "fresh")], reset: true))
        #expect(mirror.snapshot?.log.map(\.text) == ["fresh"])
    }

    @Test func aLinkWithNoMessagesLeftIsDropped() throws {
        let held = try base()
        var mirror = mirror(holding: held)
        let added = [said(4, "yo")]
        _ = mirror.apply(.messages(id: held.flow.id, link: "m", all: added))
        #expect(mirror.snapshot?.messages["m"] == added)
        #expect(mirror.snapshot?.messages["l"] == held.messages["l"])
        _ = mirror.apply(.messages(id: held.flow.id, link: "l", all: []))
        #expect(mirror.snapshot?.messages.keys.sorted() == ["m"])
    }

    @Test func terminalBytesAreHandedOnAndNotKept() throws {
        let held = try base()
        var mirror = mirror(holding: held)
        let before = mirror
        let chunk = TerminalChunk(reset: true, cols: 100, rows: 30, data: Data("hello".utf8))
        #expect(mirror.apply(.terminal(id: held.flow.id, key: "orchestrator", chunk: chunk)) == [TerminalEvent(key: "orchestrator", chunk: chunk)])
        #expect(mirror == before)
    }

    @Test func terminalBytesForTheOpenFlowArriveEvenBeforeItsSnapshot() throws {
        let held = try base()
        var mirror = RemoteMirror()
        mirror.willOpen(held.flow.id)
        let chunk = TerminalChunk(reset: true, cols: 80, rows: 24, data: Data())
        #expect(mirror.apply(.terminal(id: held.flow.id, key: "k", chunk: chunk)).count == 1)
    }

    /// Whatever the Mac decides to send for a change must take the device to the same place.
    @Test func applyingTheMacsUpdatesFollowsEveryChange() throws {
        let start = try base()
        var steps = [start]
        func step(_ change: (inout RemoteFlowSnapshot) throws -> Void) rethrows {
            var next = steps[steps.count - 1]
            try change(&next)
            steps.append(next)
        }
        // The flow: a card moved, then a card and a link added.
        step { $0.flow.cards[0].x = 99 }
        try step {
            let agent = try $0.flow.addCard(kind: .agent, x: 300, y: 20)
            _ = try $0.flow.addLink(from: $0.flow.cards[0].id, to: agent.id)
        }
        // The run.
        step {
            $0.run.isRunning = true
            $0.run.liveLinkIDs = ["l"]
            $0.run.sessions = ["orchestrator": .working]
            $0.run.usage = ["a": Usage(cost: 0.5, input: 10, output: 20)]
        }
        // The log grows, then is cleared and starts again.
        step { $0.log.append(line(3, "two")) }
        step { $0.log += [line(4, "three"), line(5, "four")] }
        step { $0.log = [line(9, "fresh")] }
        step { $0.log = [] }
        // Messages: one link gains a message, another appears, one goes.
        step { $0.messages["l"]?.append(said(6, "again")) }
        step { $0.messages["m"] = [said(7, "yo")] }
        step { $0.messages["l"] = nil }
        step { $0.messages = [:] }
        // History.
        step { $0.runs = [record("r1")] }
        step { $0.runs.append(record("r2")) }
        // Several things at once, as when a run ends.
        step {
            $0.run.isRunning = false
            $0.run.banner = "Finished"
            $0.log.append(line(10, "done"))
            $0.messages["n"] = [said(11, "bye")]
            $0.runs.append(record("r3"))
            $0.flow.name = "Demo 2"
        }
        // Nothing changed.
        step { _ in }

        var mirror = mirror(holding: start)
        var revision = 0
        for (old, new) in zip(steps, steps.dropFirst()) {
            if new.flow != old.flow { revision += 1 }
            for message in RemoteSnapshot.updates(from: old, to: new, revision: revision) {
                #expect(mirror.apply(message).isEmpty)
            }
            #expect(mirror.snapshot == new)
            #expect(mirror.revision == revision)
        }

        // And each change on its own, from a mirror that holds only the one before.
        for (old, new) in zip(steps, steps.dropFirst()) {
            var fresh = self.mirror(holding: old)
            RemoteSnapshot.updates(from: old, to: new, revision: 1).forEach { _ = fresh.apply($0) }
            #expect(fresh.snapshot == new)
        }
    }
}
