import Foundation
import Testing
@testable import QueenBeeCore

/// Approval and Script cards: a message waits at them until the app answers.
@Suite struct HoldTests {
    private func flow(_ kind: CardKind, command: String? = nil) throws -> Flow {
        var flow = Flow(name: "Test")
        var start = CardPatch()
        start.command = "Go"
        try flow.addCard(kind: .start, name: "Start", patch: start)
        try flow.addCard(kind: .agent, name: "Writer")
        var gate = CardPatch()
        gate.command = command
        try flow.addCard(kind: kind, name: "Gate", patch: gate)
        try flow.addCard(kind: .agent, name: "Sender")
        try flow.addCard(kind: .end, name: "Dropped")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "Gate")
        try flow.addLink(from: "Gate", port: kind == .approval ? "approved" : "pass", to: "Sender")
        try flow.addLink(from: "Gate", port: kind == .approval ? "rejected" : "fail", to: "Dropped")
        return flow
    }

    private func reachGate(_ flow: Flow, _ engine: Engine) async throws -> Hold {
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try #require(flow.resolveCard("Writer")).id, text: "Dear all")
        #expect(!out.finished)
        return try #require(out.holds.first)
    }

    // MARK: Replies nobody asked for

    /// Start → Writer → Gate (Approval) → Sender → Sent (End, saves a file).
    private func gatedSend() throws -> Flow {
        var flow = try flow(.approval)
        var save = CardPatch()
        save.saveTo = "sent.txt"
        try flow.addCard(kind: .end, name: "Sent", patch: save)
        try flow.addLink(from: "Sender", to: "Sent")
        return flow
    }

    @Test func aReplyFromAnAgentPastAnUnansweredApprovalIsNotPassedOn() async throws {
        let flow = try gatedSend()
        let engine = Engine(judge: ScriptedJudge())
        let hold = try await reachGate(flow, engine)
        let sender = try #require(flow.resolveCard("Sender"))

        // The Sender finishes a turn of its own while the Approval is still waiting for the person.
        let out = await engine.agentReplied(flow: flow, cardID: sender.id, text: "Sent it anyway")
        #expect(out.results.isEmpty && out.deliveries.isEmpty && out.visits.isEmpty)
        #expect(!out.finished)
        #expect(out.log == ["Sender finished a turn, but nothing in this run was waiting on it, so its reply was not passed on"])

        // The Approval is still there to answer, and answering it works as before.
        let approved = await engine.holdResolved(flow: flow, holdID: hold.id, port: "approved", text: nil)
        #expect(approved.deliveries.map(\.toCardID) == [sender.id])
        let done = await engine.agentReplied(flow: flow, cardID: sender.id, text: "Sent")
        #expect(done.results.map(\.text) == ["Sent"] && done.finished)
    }

    @Test func aReplyLeftOverFromAnEarlierRunIsNotPassedOnInTheNext() async throws {
        let flow = try gatedSend()
        let engine = Engine(judge: ScriptedJudge())
        let first = try await reachGate(flow, engine)
        _ = await engine.holdResolved(flow: flow, holdID: first.id, port: "approved", text: nil)
        _ = await engine.stop()

        // A new run reaches the Approval; the Sender's reply to the stopped run turns up now.
        _ = try await reachGate(flow, engine)
        let late = await engine.agentReplied(flow: flow, cardID: try #require(flow.resolveCard("Sender")).id, text: "Sent")
        #expect(late.results.isEmpty && !late.finished)
        #expect(await engine.isRunning)
    }

    @Test func anApprovalHoldsTheMessageAndKeepsTheRunGoing() async throws {
        let flow = try flow(.approval)
        let engine = Engine(judge: ScriptedJudge())
        let hold = try await reachGate(flow, engine)
        #expect(hold.kind == .approval && hold.text == "Dear all" && hold.fromName == "Writer")
        #expect(await engine.isRunning)
    }

    @Test func approvingPassesTheEditedMessageOnFromItsWriter() async throws {
        let flow = try flow(.approval)
        let engine = Engine(judge: ScriptedJudge())
        let hold = try await reachGate(flow, engine)
        let out = await engine.holdResolved(flow: flow, holdID: hold.id, port: "approved", text: "Dear team")
        #expect(out.deliveries.count == 1)
        #expect(out.deliveries.first?.text.hasSuffix("from Writer]\nDear team") == true)
        #expect(out.log.first == "Approval \"Gate\" → Approved")
    }

    @Test func rejectingTakesTheOtherOutputAndCanEndTheRun() async throws {
        let flow = try flow(.approval)
        let engine = Engine(judge: ScriptedJudge())
        let hold = try await reachGate(flow, engine)
        let out = await engine.holdResolved(flow: flow, holdID: hold.id, port: "rejected", text: nil)
        #expect(out.results.map(\.text) == ["Dear all"])
        #expect(out.finished)
    }

    @Test func rejectingWithANoteSendsTheNoteAheadOfTheMessage() async throws {
        let flow = try flow(.approval)
        let engine = Engine(judge: ScriptedJudge())
        let hold = try await reachGate(flow, engine)
        let text = try #require(Hold.rejection(note: "  Too formal. ", of: hold.text))
        #expect(text.hasPrefix("Too formal.\n") && text.hasSuffix("\nDear all"))
        let out = await engine.holdResolved(flow: flow, holdID: hold.id, port: "rejected", text: text)
        #expect(out.results.map(\.text) == [text])
    }

    @Test func rejectingWithNoNoteLeavesTheMessageAsItWas() {
        #expect(Hold.rejection(note: " \n", of: "Dear all") == nil)
    }

    @Test func aHoldAnsweredTwiceOnlyCountsOnce() async throws {
        let flow = try flow(.approval)
        let engine = Engine(judge: ScriptedJudge())
        let hold = try await reachGate(flow, engine)
        _ = await engine.holdResolved(flow: flow, holdID: hold.id, port: "approved", text: nil)
        let again = await engine.holdResolved(flow: flow, holdID: hold.id, port: "approved", text: nil)
        #expect(again.deliveries.isEmpty && again.log.isEmpty)
    }

    @Test func aScriptPassesOnWhatItPrintedUnderItsOwnName() async throws {
        let flow = try flow(.script, command: "npm test")
        let engine = Engine(judge: ScriptedJudge())
        let hold = try await reachGate(flow, engine)
        #expect(hold.kind == .script)
        let out = await engine.holdResolved(flow: flow, holdID: hold.id, port: "pass", text: "12 passed")
        #expect(out.deliveries.first?.text.hasSuffix("from Gate]\n12 passed") == true)
    }

    @Test func aScriptWithNoCommandFailsWithoutWaiting() async throws {
        let flow = try flow(.script, command: "  ")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try #require(flow.resolveCard("Writer")).id, text: "Dear all")
        #expect(out.holds.isEmpty)
        #expect(out.results.map(\.cardName) == ["Dropped"])
    }

    @Test func stoppingARunForgetsWhatWasHeld() async throws {
        let flow = try flow(.approval)
        let engine = Engine(judge: ScriptedJudge())
        let hold = try await reachGate(flow, engine)
        _ = await engine.stop()
        let late = await engine.holdResolved(flow: flow, holdID: hold.id, port: "approved", text: nil)
        #expect(late.deliveries.isEmpty)
    }

    @Test func warningsCoverTheNewCards() throws {
        var flow = Flow(name: "Test")
        let script = try flow.addCard(kind: .script, name: "Tests")
        let gate = try flow.addCard(kind: .approval, name: "Gate")
        #expect(warnings(for: flow)[script.id] == "Write the command")
        #expect(warnings(for: flow)[gate.id] == "Nothing on Approved")
    }
}

@Suite struct TravelTests {
    @Test func eachLinkRecordsWhatItCarried() async throws {
        var flow = Flow(name: "Test")
        var start = CardPatch()
        start.command = "Go"
        try flow.addCard(kind: .start, name: "Start", patch: start)
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .end, name: "Done")
        let first = try flow.addLink(from: "Start", to: "Writer")
        let second = try flow.addLink(from: "Writer", to: "Done")
        let engine = Engine(judge: ScriptedJudge())
        let began = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(began.travels == [Travel(linkID: first.id, text: "Go", fromName: "Start")])
        let replied = await engine.agentReplied(flow: flow, cardID: try #require(flow.resolveCard("Writer")).id, text: "A draft")
        #expect(replied.travels == [Travel(linkID: second.id, text: "A draft", fromName: "Writer")])
    }
}

@Suite struct RunFromHereTests {
    @Test func startingAtAnAgentDeliversTheMessageToIt() async throws {
        var flow = Flow(name: "Test")
        let writer = try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .end, name: "Done")
        try flow.addLink(from: "Writer", to: "Done")
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: flow, at: writer.id, message: "Try again", fromName: "You")
        #expect(out.deliveries.map(\.toCardID) == [writer.id])
        #expect(out.deliveries.first?.text.hasSuffix("from You]\nTry again") == true)
        #expect(!out.finished && out.runID != nil)
    }

    @Test func startingAtAnAndPassesTheMessageOn() async throws {
        var flow = Flow(name: "Test")
        try flow.addCard(kind: .agent, name: "A")
        try flow.addCard(kind: .agent, name: "B")
        let both = try flow.addCard(kind: .and, name: "Both")
        try flow.addCard(kind: .end, name: "Done")
        try flow.addLink(from: "A", to: "Both")
        try flow.addLink(from: "B", to: "Both")
        try flow.addLink(from: "Both", to: "Done")
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: flow, at: both.id, message: "Both answers", fromName: "You")
        #expect(out.results.map(\.text) == ["Both answers"] && out.finished)
    }

    @Test func aCardThatTakesNoInputOrABlankMessageStartsNothing() async throws {
        var flow = Flow(name: "Test")
        let start = try flow.addCard(kind: .start, name: "Start")
        let writer = try flow.addCard(kind: .agent, name: "Writer")
        let engine = Engine(judge: ScriptedJudge())
        #expect(await engine.start(flow: flow, at: start.id, message: "Hi", fromName: "You").runID == nil)
        #expect(await engine.start(flow: flow, at: writer.id, message: "  ", fromName: "You").runID == nil)
        #expect(await !engine.isRunning)
    }
}
