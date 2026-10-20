import Foundation
import Testing
@testable import QueenBeeCore

/// A judge that takes as long as it is given before answering, or until it is cancelled.
private struct SlowJudge: Judge {
    let delay: Duration
    let answer: Bool?

    func holds(statement: String, message: String) async -> Bool? {
        try? await Task.sleep(for: delay)
        return answer
    }

    func pick(branches: [String], message: String) async -> String? {
        try? await Task.sleep(for: delay)
        return answer == true ? branches.first : nil
    }
}

/// How runs end, and what a run does with agents and judges it isn't waiting on.
@Suite struct RunEndingTests {
    private func patch(_ edit: (inout CardPatch) -> Void) -> CardPatch {
        var patch = CardPatch()
        edit(&patch)
        return patch
    }

    private func id(_ name: String, in flow: Flow) throws -> String {
        try #require(flow.resolveCard(name)).id
    }

    /// Start → Writer → Reviewer, and an Idle agent nothing links to.
    private func chainWithIdle() throws -> Flow {
        var flow = Flow(name: "Test")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .agent, name: "Reviewer")
        try flow.addCard(kind: .agent, name: "Idle")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "Reviewer")
        return flow
    }

    // MARK: Agents the run isn't waiting on

    @Test func anAgentTheRunIsNotWaitingOnCanFailWithoutStoppingIt() async throws {
        let flow = try chainWithIdle()
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        for name in ["Idle", "Reviewer"] {
            let out = await engine.agentFailed(flow: flow, cardID: try id(name, in: flow), reason: "session exited")
            #expect(!out.finished && out.log.isEmpty && out.deliveries.isEmpty)
        }
        // A card that has gone from the flow isn't one the run is waiting on either.
        let gone = await engine.agentFailed(flow: flow, cardID: "deleted1", reason: "session exited")
        #expect(!gone.finished)
        #expect(await engine.runID == started.runID)
        // The run carries on as before.
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "draft")
        #expect(out.deliveries.map(\.toCardID) == [try id("Reviewer", in: flow)])
    }

    @Test func anAgentTheRunIsWaitingOnStopsItWhenItFails() async throws {
        let flow = try chainWithIdle()
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentFailed(flow: flow, cardID: try id("Writer", in: flow), reason: "session exited")
        #expect(out.finished && out.ending == .failed)
        #expect(out.log == ["Run stopped because Writer failed: session exited"])
    }

    @Test func aDeletedCardIsNamedByTheNameItHad() async throws {
        let flow = try chainWithIdle()
        var without = flow
        try without.removeCard(try id("Writer", in: flow))
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentFailed(flow: without, cardID: try id("Writer", in: flow), name: "Writer", reason: "its card was deleted")
        #expect(out.log == ["Run stopped because Writer failed: its card was deleted"])
    }

    // MARK: Or inside a loop

    @Test func anOrInsideALoopPassesOnOneReplyEachRound() async throws {
        // Start → Writer A and Writer B → Or → Reviewer → Loop; Again → both writers; Done → End.
        var flow = Flow(name: "Loop")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
        try flow.addCard(kind: .agent, name: "Writer A")
        try flow.addCard(kind: .agent, name: "Writer B")
        try flow.addCard(kind: .or, name: "First")
        try flow.addCard(kind: .agent, name: "Reviewer")
        try flow.addCard(kind: .loop, name: "Good?", patch: patch { $0.check = .contains; $0.value = "APPROVED"; $0.maxTries = 5 })
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Writer A")
        try flow.addLink(from: "Start", to: "Writer B")
        try flow.addLink(from: "Writer A", to: "First")
        try flow.addLink(from: "Writer B", to: "First")
        try flow.addLink(from: "First", to: "Reviewer")
        try flow.addLink(from: "Reviewer", to: "Good?")
        try flow.addLink(from: "Good?", port: "again", to: "Writer A")
        try flow.addLink(from: "Good?", port: "again", to: "Writer B")
        try flow.addLink(from: "Good?", port: "done", to: "End")
        let a = try id("Writer A", in: flow), b = try id("Writer B", in: flow), reviewer = try id("Reviewer", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)

        // Round 1: A is first, B is dropped.
        #expect(await engine.agentReplied(flow: flow, cardID: a, text: "A1").deliveries.map(\.toCardID) == [reviewer])
        #expect(await engine.agentReplied(flow: flow, cardID: b, text: "B1").deliveries.isEmpty)
        let again = await engine.agentReplied(flow: flow, cardID: reviewer, text: "Try again")
        #expect(again.deliveries.map(\.toCardID) == [a, b])

        // Round 2: the Or passes on the first reply again.
        let second = await engine.agentReplied(flow: flow, cardID: b, text: "B2")
        #expect(second.deliveries.map(\.toCardID) == [reviewer])
        #expect(await engine.agentReplied(flow: flow, cardID: a, text: "A2").deliveries.isEmpty)
        let done = await engine.agentReplied(flow: flow, cardID: reviewer, text: "APPROVED")
        #expect(done.results.map(\.text) == ["APPROVED"])
        #expect(done.finished && done.ending == .finishedWithAnswer)
    }

    // MARK: How a run ended

    @Test func aRunThatReachesAnEndFinishedWithAnAnswer() async throws {
        var flow = Flow(name: "T")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "End")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "done")
        #expect(out.finished && out.ending == .finishedWithAnswer)
    }

    @Test func aRunThatNeverReachesAnEndSaysSo() async throws {
        let flow = try chainWithIdle()
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "draft")
        let out = await engine.agentReplied(flow: flow, cardID: try id("Reviewer", in: flow), text: "ok")
        #expect(out.finished && out.ending == .endedWithoutAnswer)
    }

    @Test func anAndLeftWaitingIsNamedWhenTheRunEnds() async throws {
        // Start → A and B → Both → End, and B has nothing to pass on.
        var flow = Flow(name: "T")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
        try flow.addCard(kind: .agent, name: "A")
        try flow.addCard(kind: .agent, name: "B")
        try flow.addCard(kind: .and, name: "Both")
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "A")
        try flow.addLink(from: "Start", to: "B")
        try flow.addLink(from: "A", to: "Both")
        try flow.addLink(from: "B", to: "Both")
        try flow.addLink(from: "Both", to: "End")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "from A")
        let out = await engine.agentReplied(flow: flow, cardID: try id("B", in: flow), text: "[no reply]")
        #expect(out.finished && out.ending == .endedWithoutAnswer)
        #expect(out.log.contains("And \"Both\" was still waiting for B when the run ended"))
    }

    @Test func aLoopThatRanOutOfTriesGaveUp() async throws {
        var flow = Flow(name: "T")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .loop, name: "Polish", patch: patch { $0.check = .contains; $0.value = "FINAL"; $0.maxTries = 1 })
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "Polish")
        try flow.addLink(from: "Polish", port: "again", to: "Writer")
        try flow.addLink(from: "Polish", port: "done", to: "End")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "draft")
        #expect(out.results.map(\.text) == ["draft"])
        #expect(out.finished && out.ending == .gaveUp)
    }

    @Test func aStoppedRunSaysSoAndNamesTheAgentsItWasWaitingOn() async throws {
        let flow = try chainWithIdle()
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.stop()
        #expect(out.finished && out.ending == .stopped)
        #expect(out.leftWaiting == [try id("Writer", in: flow)])
    }

    // MARK: Replies from runs that have ended

    @Test func aReplyToAnEarlierRunIsNotPassedOn() async throws {
        let flow = try chainWithIdle()
        let writer = try id("Writer", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        let first = try #require(await engine.start(flow: flow, startCardID: nil, command: nil).runID)
        _ = await engine.stop()
        let second = await engine.start(flow: flow, startCardID: nil, command: nil)
        let delivery = try #require(second.deliveries.first)
        #expect(Engine.runID(inHandOff: delivery.text) == second.runID)
        #expect(Engine.runID(inHandOff: "Write a haiku") == nil)

        // The Writer is owed a reply in the second run, but this one answers the first.
        let late = await engine.agentReplied(flow: flow, cardID: writer, text: "old draft", forRun: first)
        #expect(late.deliveries.isEmpty && !late.finished)
        #expect(late.log == ["Writer finished work for a run that has ended, so its reply was not passed on"])
        let reply = await engine.agentReplied(flow: flow, cardID: writer, text: "new draft", forRun: second.runID)
        #expect(reply.deliveries.map(\.toCardID) == [try id("Reviewer", in: flow)])
    }

    // MARK: The judge

    /// Start → Writer → If → Yes: Editor, No: End.
    private func judged() throws -> Flow {
        var flow = Flow(name: "T")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .ifElse, name: "Good?", patch: patch { $0.check = .judge; $0.value = "It is good" })
        try flow.addCard(kind: .agent, name: "Editor")
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "Good?")
        try flow.addLink(from: "Good?", port: "yes", to: "Editor")
        try flow.addLink(from: "Good?", port: "no", to: "End")
        return flow
    }

    @Test func aJudgeThatTakesTooLongCountsAsNo() async throws {
        let flow = try judged()
        let engine = Engine(judge: SlowJudge(delay: .seconds(30), answer: true), judgeTimeout: .milliseconds(50))
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let clock = ContinuousClock()
        let began = clock.now
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "draft")
        #expect(clock.now - began < .seconds(5))
        #expect(out.log.contains("If \"Good?\" took too long to judge, so it counts as No"))
        #expect(out.results.map(\.text) == ["draft"])
    }

    @Test func stopDoesNotWaitForTheJudge() async throws {
        let flow = try judged()
        let engine = Engine(judge: SlowJudge(delay: .seconds(30), answer: true), judgeTimeout: .seconds(60))
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let writer = try id("Writer", in: flow)
        let clock = ContinuousClock()
        let began = clock.now
        let reply = Task { await engine.agentReplied(flow: flow, cardID: writer, text: "draft") }
        try await Task.sleep(for: .milliseconds(50))
        let stopped = await engine.stop()
        #expect(stopped.finished && stopped.ending == .stopped)
        // What the interrupted event decided belongs to a run that is over, so none of it is acted on.
        let late = await reply.value
        #expect(late.deliveries.isEmpty && late.results.isEmpty && late.runID == nil && !late.finished)
        #expect(clock.now - began < .seconds(5))
        #expect(await !engine.isRunning)
        // And a new run can start straight away.
        #expect(await engine.start(flow: flow, startCardID: nil, command: nil).deliveries.count == 1)
    }
}
