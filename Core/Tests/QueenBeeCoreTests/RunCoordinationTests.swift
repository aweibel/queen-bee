import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RunCoordinationTests {
    // MARK: Messages kept for Retry

    @Test func aLongMessageIsShownCutShortAndGivenAgainWhole() throws {
        var shown: [String: [LinkMessage]] = [:]
        var whole: [UUID: String] = [:]
        let long = String(repeating: "word ", count: 5_000)
        CarriedMessages.add(long, from: "Writer", at: Date(), link: "l1", to: &shown, whole: &whole)
        let kept = try #require(shown["l1"]?.last)
        #expect(kept.text.count == CarriedMessages.shownLength)
        // What Retry starts with is the message as the card was given it.
        let retried = CarriedMessages.whole(kept, from: whole)
        #expect(retried.text == long && retried.id == kept.id && retried.from == "Writer")
        // A short message is kept as it is, with no second copy.
        CarriedMessages.add("short", from: "Writer", at: Date(), link: "l1", to: &shown, whole: &whole)
        #expect(whole.count == 1)
        #expect(CarriedMessages.whole(try #require(shown["l1"]?.last), from: whole).text == "short")
    }

    @Test func wholeMessagesGoWhenTheirShortCopyDoes() {
        var shown: [String: [LinkMessage]] = [:]
        var whole: [UUID: String] = [:]
        let long = String(repeating: "x", count: CarriedMessages.shownLength + 1)
        for _ in 0..<(CarriedMessages.perLink + 3) {
            CarriedMessages.add(long, from: "A", at: Date(), link: "l1", to: &shown, whole: &whole)
        }
        #expect(shown["l1"]?.count == CarriedMessages.perLink)
        #expect(whole.count == CarriedMessages.perLink)
        #expect(Set(whole.keys) == Set(shown["l1"]?.map(\.id) ?? []))
        #expect(CarriedMessages.kept(whole, for: [:]).isEmpty)
    }

    // MARK: Two Flow cards, one sub-flow

    @MainActor @Test func twoFlowCardsRunningOneFlowTakeTurns() async {
        let turns = RunTurns()
        var order: [String] = []
        #expect(await turns.take { true })
        order.append("first runs")
        let second = Task { @MainActor in
            let took = await turns.take { true }
            order.append("second runs")
            return took
        }
        // The second waits while the first has the turn.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(order == ["first runs"])
        order.append("first ends")
        turns.release()
        #expect(await second.value)
        #expect(order == ["first runs", "first ends", "second runs"])
    }

    @MainActor @Test func aFlowCardWaitsOutARunStartedSomeOtherWay() async {
        let turns = RunTurns()
        var personsRunIsGoing = true
        let card = Task { @MainActor in await turns.take { !personsRunIsGoing } }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(turns.isTaken == false)
        personsRunIsGoing = false
        turns.somethingEnded()
        #expect(await card.value)
        #expect(turns.isTaken)
    }

    @MainActor @Test func aFlowCardStoppedWhileWaitingGivesUpItsPlace() async {
        let turns = RunTurns()
        _ = await turns.take { true }
        let waiting = Task { @MainActor in await turns.take { true } }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        #expect(await waiting.value == false)
    }

    @Test func aFlowCardNeverRunsAFlowItsRunIsInsideOrPastTheLimit() {
        #expect(subflowRefusal(running: "b", named: "Summary", levelsLeft: 2, inside: ["a"]) == nil)
        #expect(subflowRefusal(running: "a", named: "Outer", levelsLeft: 2, inside: ["a"])?.contains("already inside it") == true)
        #expect(subflowRefusal(running: "b", named: "Summary", levelsLeft: 0, inside: [])?.contains("sub-flow limit") == true)
    }

    // MARK: History saved in the background

    @Test func anOlderSaveNeverOverwritesANewerOne() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qb-latest-\(Flow.newID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let writer = LatestWins()
        let older = writer.ticket(), newer = writer.ticket()
        #expect(newer > older)
        #expect(await writer.write({ Data("new".utf8) }, ticket: newer, to: url))
        #expect(await !writer.write({ Data("old".utf8) }, ticket: older, to: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }
}

/// The most a run may spend, and how long a card waits for the person.
@Suite struct RunLimitsTests {
    @Test func aRunMayGoOnUpToItsSpendingLimit() {
        #expect(SpendingLimit.passed(limit: nil, spent: Usage(cost: 1_000)) == nil)
        #expect(SpendingLimit.passed(limit: 5, spent: Usage(cost: 5)) == nil)
        #expect(SpendingLimit.passed(limit: 5, spent: Usage(cost: 5.12))
                == "Run stopped: its agents had spent about $5.12, more than this flow's limit of $5.00 for one run")
    }

    @Test func aLimitIsKeptWithinItsRangeToTheCent() {
        #expect(SpendingLimit.clamped(0) == nil && SpendingLimit.clamped(-3) == nil && SpendingLimit.clamped(.nan) == nil)
        #expect(SpendingLimit.clamped(0.001) == 0.01)
        #expect(SpendingLimit.clamped(2.345) == 2.35 || SpendingLimit.clamped(2.345) == 2.34)
        #expect(SpendingLimit.clamped(1_000_000) == SpendingLimit.range.upperBound)
    }

    @Test func aTimeLimitIsSaidInPlainWords() {
        #expect(HoldTimeLimit.describe(minutes: 45) == "45 minutes")
        #expect(HoldTimeLimit.describe(minutes: 60) == "1 hour")
        #expect(HoldTimeLimit.describe(minutes: 480) == "8 hours")
        #expect(HoldTimeLimit.describe(minutes: 90) == "1 hour 30 minutes")
        #expect(HoldTimeLimit.describe(minutes: 2 * 24 * 60) == "2 days")
    }

    @Test func aCardWithATimeLimitAnswersWithItsChosenOutput() throws {
        var flow = Flow(name: "Test")
        var patch = CardPatch()
        patch.waitMinutes = 480
        let approval = try flow.addCard(kind: .approval, name: "Sign off", patch: patch)
        #expect(HoldTimeLimit.wait(for: approval) == .seconds(480 * 60))
        #expect(HoldTimeLimit.port(for: approval) == "rejected")
        #expect(HoldTimeLimit.line(for: approval) == "No answer after 8 hours, so it was rejected")
        patch = CardPatch()
        patch.whenNoAnswer = "approved"
        let approving = try flow.updateCard("Sign off", patch: patch)
        #expect(HoldTimeLimit.port(for: approving) == "approved")
        #expect(HoldTimeLimit.line(for: approving) == "No answer after 8 hours, so it was approved")
        // A script nobody allowed never runs.
        patch = CardPatch()
        patch.waitMinutes = 30
        let script = try flow.addCard(kind: .script, name: "Deploy", patch: patch)
        #expect(HoldTimeLimit.port(for: script) == "fail")
        #expect(HoldTimeLimit.line(for: script) == "No answer after 30 minutes, so its command was not run")
    }

    @Test func aTimeLimitIsClearedByZeroAndKeptUnderAWeek() throws {
        var flow = Flow(name: "Test")
        var patch = CardPatch()
        patch.waitMinutes = 1_000_000
        #expect(try flow.addCard(kind: .approval, name: "A", patch: patch).waitMinutes == HoldTimeLimit.longestMinutes)
        patch.waitMinutes = 0
        let cleared = try flow.updateCard("A", patch: patch)
        #expect(cleared.waitMinutes == nil && HoldTimeLimit.wait(for: cleared) == nil)
        // Other kinds of card have no time limit.
        patch.waitMinutes = 10
        #expect(try flow.addCard(kind: .note, name: "N", patch: patch).waitMinutes == nil)
    }

    @Test func aRunStoppedForSpendingSaysSoAndInterruptsItsAgents() async throws {
        var flow = Flow(name: "Test")
        var patch = CardPatch()
        patch.command = "Go"
        try flow.addCard(kind: .start, name: "Start", patch: patch)
        let writer = try flow.addCard(kind: .agent, name: "Writer")
        try flow.addLink(from: "Start", to: "Writer")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.stop(ending: .spentLimit, line: "Run stopped: too dear")
        #expect(out.finished && out.ending == .spentLimit && out.log == ["Run stopped: too dear"])
        #expect(out.leftWaiting == [writer.id])
        #expect(RunEnding.spentLimit.outcome == .stopped)
    }

    @Test func anEndingThisVersionDoesNotKnowReadsAsStopped() throws {
        let record = try JSONDecoder().decode([RunEnding].self, from: Data(#"["finishedWithAnswer", "somethingNew"]"#.utf8))
        #expect(record == [.finishedWithAnswer, .stopped])
        #expect(String(decoding: try JSONEncoder().encode(RunEnding.spentLimit), as: UTF8.self) == #""spentLimit""#)
    }

    @Test func aFlowFromBeforeSpendingLimitsHasNone() throws {
        let flow = Flow(name: "Old")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(flow)) as? [String: Any])
        json["spendingLimit"] = nil
        let read = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.spendingLimit == nil)
    }
}

