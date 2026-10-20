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
