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
        #expect(!mirror.canControl)
        #expect(mirror.waiting.isEmpty)
        #expect(mirror.lastRefusal == nil)
    }

    @Test func theMacSaysWhetherTheDeviceMayControlIt() {
        var mirror = RemoteMirror()
        _ = mirror.apply(.welcome(RemoteWelcome(version: Remote.version, macName: "Studio", canControl: true)))
        #expect(mirror.canControl)
        _ = mirror.apply(.control(canControl: false))
        #expect(!mirror.canControl)
        _ = mirror.apply(.control(canControl: true))
        #expect(mirror.canControl)
        _ = mirror.apply(.welcome(RemoteWelcome(version: Remote.version, macName: "Studio", canControl: false)))
        #expect(!mirror.canControl)
    }

    @Test func aDeviceTurnedAwayNoLongerControls() {
        var mirror = RemoteMirror()
        _ = mirror.apply(.welcome(RemoteWelcome(version: Remote.version, macName: "Studio", canControl: true)))
        _ = mirror.apply(.refused("No longer paired."))
        #expect(!mirror.canControl)
    }

    @Test func aCommandWaitsUntilItIsAnswered() {
        var mirror = RemoteMirror()
        let stop = RemoteCommand.stop(flowID: "f"), run = RemoteCommand.run(flowID: "f", command: nil)
        let first = mirror.willSend(stop), second = mirror.willSend(run)
        #expect(first != second)
        #expect(mirror.isWaiting(for: stop) && mirror.isWaiting(for: run))
        #expect(!mirror.isWaiting(for: .stop(flowID: "other")))
        #expect(mirror.apply(.answer(id: first, refusal: nil)).isEmpty)
        #expect(!mirror.isWaiting(for: stop) && mirror.isWaiting(for: run))
        #expect(mirror.lastRefusal == nil)
    }

    @Test func aRefusalIsKeptInTheMacsWordsUntilCleared() {
        var mirror = RemoteMirror()
        let run = RemoteCommand.run(flowID: "f", command: nil)
        let id = mirror.willSend(run)
        _ = mirror.apply(.answer(id: id, refusal: "A run is already going."))
        #expect(mirror.waiting.isEmpty)
        #expect(mirror.lastRefusal == RemoteRefusal(id: id, command: run, text: "A run is already going."))
        mirror.clearRefusal()
        #expect(mirror.lastRefusal == nil)
    }

    @Test func anAnswerToNothingChangesNothing() {
        var mirror = RemoteMirror()
        let id = mirror.willSend(.stop(flowID: "f"))
        _ = mirror.apply(.answer(id: id + 5, refusal: "No."))
        #expect(mirror.waiting.count == 1)
        #expect(mirror.lastRefusal == nil)
    }

    @Test func nothingWaitsAcrossADroppedLink() {
        var mirror = RemoteMirror()
        let first = mirror.willSend(.stop(flowID: "f")), second = mirror.willSend(.openOnMac(flowID: "f"))
        #expect(mirror.dropWaiting() == [first, second])
        #expect(mirror.waiting.isEmpty)
        let third = mirror.willSend(.stop(flowID: "f"))
        // Ids are never used twice, so a late answer to an old command can't be taken for a new one's.
        #expect(third > second)
        _ = mirror.apply(.welcome(RemoteWelcome(version: Remote.version, macName: "Studio", canControl: true)))
        #expect(mirror.waiting.isEmpty)
    }

    @Test func aCommandTheMacIsSlowOverStopsBeingWaitedFor() {
        var mirror = RemoteMirror()
        let run = mirror.willSend(.run(flowID: "f", command: nil)), stop = mirror.willSend(.stop(flowID: "f"))
        #expect(mirror.giveUpWaiting(for: run) == .run(flowID: "f", command: nil))
        #expect(mirror.waiting == [stop: .stop(flowID: "f")])
        #expect(mirror.giveUpWaiting(for: run) == nil)
        // Its answer, when it does come, is nothing to anyone: it is not taken for a refusal of something else.
        _ = mirror.apply(.answer(id: run, refusal: "A run is already going."))
        #expect(mirror.lastRefusal == nil)
        #expect(mirror.waiting == [stop: .stop(flowID: "f")])
    }

    @Test func aStepOfADragIsSentAndNotWaitedFor() {
        var mirror = RemoteMirror()
        let step = RemoteCommand.moveCards(flowID: "f", moves: ["a": RemotePoint(x: 1, y: 2)], final: false)
        // Twenty a second for as long as a finger is down: none of them may pile up.
        let ids = (0..<200).map { _ in mirror.willSend(step) }
        #expect(Set(ids).count == 200)
        #expect(mirror.waiting.isEmpty)
        #expect(!mirror.isWaiting(for: step))
        let last = RemoteCommand.moveCards(flowID: "f", moves: ["a": RemotePoint(x: 1, y: 2)], final: true)
        let id = mirror.willSend(last)
        #expect(id > ids.max() ?? 0)
        #expect(mirror.waiting == [id: last])
        _ = mirror.apply(.answer(id: id, refusal: "That card is no longer in the flow."))
        #expect(mirror.waiting.isEmpty)
        #expect(mirror.lastRefusal?.command == last)
    }

    @Test func undoAndSchedulesFollowTheMac() throws {
        let start = try base()
        #expect(start.edit == RemoteEditState())
        var mirror = mirror(holding: start)
        let state = RemoteEditState(undo: "Undo Add Note", redo: nil, armed: ["s"], nextFires: ["s": Date(timeIntervalSince1970: 60)])
        _ = mirror.apply(.edit(id: start.flow.id, state: state))
        #expect(mirror.snapshot?.edit == state)
        // Only the open flow's.
        _ = mirror.apply(.edit(id: "other", state: RemoteEditState(undo: "Undo Tidy Up")))
        #expect(mirror.snapshot?.edit == state)
        // And the rest of what was on show is untouched.
        #expect(mirror.snapshot?.flow == start.flow)
        #expect(mirror.snapshot?.run == start.run)
        #expect(mirror.revision == 0)
    }

    @Test func theRolesComeWithTheFlowList() {
        var mirror = RemoteMirror()
        _ = mirror.apply(.library(RemoteLibrary(projects: [], roles: [RemoteRole(id: "r", name: "Reviewer")])))
        #expect(mirror.library?.roles == [RemoteRole(id: "r", name: "Reviewer")])
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

    @Test func openingTheFlowAlreadyOpenKeepsWhatIsOnShow() throws {
        // The Mac doesn't send the open flow again when it is asked for again, so clearing it would leave nothing.
        let held = try base()
        var mirror = mirror(holding: held)
        _ = mirror.apply(.flow(id: held.flow.id, revision: 4, flow: held.flow))
        let cleared = mirror.willOpen(held.flow.id)
        #expect(!cleared)
        #expect(mirror.snapshot == held)
        #expect(mirror.revision == 4)
        // Still waiting for it: nothing to clear, and the Mac's reply is still on its way.
        var waiting = RemoteMirror()
        let first = waiting.willOpen(held.flow.id), again = waiting.willOpen(held.flow.id)
        #expect(first && !again)
        _ = waiting.apply(.opened(held))
        #expect(waiting.snapshot == held)
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

    @Test func aLogAtItsCapDropsItsOldestLinesAsTheMacsDoes() throws {
        var held = try base()
        held.log = (0..<LogLine.mostKept).map { line(Double($0), "line \($0)") }
        var mirror = mirror(holding: held)
        var mac = held
        let added = line(9_999, "newest")
        mac.log = Array((mac.log + [added]).suffix(LogLine.mostKept))
        for message in RemoteSnapshot.updates(from: held, to: mac, revision: 1) { _ = mirror.apply(message) }
        #expect(mirror.snapshot?.log == mac.log)
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

    /// A device reads terminal bytes without changing the mirror, so output arriving redraws nothing else.
    @Test func terminalBytesCanBeReadWithoutTouchingTheMirror() throws {
        let held = try base()
        let mirror = mirror(holding: held)
        let chunk = TerminalChunk(reset: false, cols: 80, rows: 24, data: Data("more".utf8))
        #expect(mirror.terminalEvent(in: .terminal(id: held.flow.id, key: "k", chunk: chunk)) == TerminalEvent(key: "k", chunk: chunk))
        #expect(mirror.terminalEvent(in: .terminal(id: "another", key: "k", chunk: chunk)) == nil)
        #expect(mirror.terminalEvent(in: .log(id: held.flow.id, lines: [], reset: false)) == nil)
        #expect(RemoteMirror().terminalEvent(in: .terminal(id: held.flow.id, key: "k", chunk: chunk)) == nil)
    }

    @Test func aFlowThatLeftTheMacsListIsKnownToNeedAskingForAgain() throws {
        let held = try base()
        var mirror = mirror(holding: held)
        let summary = RemoteFlowSummary(id: held.flow.id, name: "Demo", isSubflow: false, activity: .quiet)
        func library(_ flows: [RemoteFlowSummary]) -> HostMessage {
            .library(RemoteLibrary(projects: [RemoteProject(id: "p", name: "Work", flows: flows)]))
        }
        _ = mirror.apply(library([summary]))
        #expect(!mirror.openFlowWentAway)
        _ = mirror.apply(library([]))
        #expect(mirror.openFlowWentAway)
        // Back in the list, it is still not being sent: only asking again, or a fresh copy, changes that.
        _ = mirror.apply(library([summary]))
        #expect(mirror.openFlowWentAway)
        mirror.willOpen(held.flow.id)
        #expect(!mirror.openFlowWentAway)
        _ = mirror.apply(library([]))
        _ = mirror.apply(.opened(held))
        #expect(!mirror.openFlowWentAway)
        // With no flow open there is nothing to have gone.
        mirror.willOpen(nil)
        _ = mirror.apply(library([]))
        #expect(!mirror.openFlowWentAway)
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
        // An edit, with what it does to Undo, and a schedule turned on at the Mac.
        step {
            $0.flow.cards[0].y = 300
            $0.edit.undo = "Undo Move"
        }
        step {
            $0.edit.armed = [$0.flow.cards[0].id]
            $0.edit.nextFires = [$0.flow.cards[0].id: Date(timeIntervalSince1970: 600)]
        }
        step { $0.edit = RemoteEditState(undo: nil, redo: "Redo Move") }
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
