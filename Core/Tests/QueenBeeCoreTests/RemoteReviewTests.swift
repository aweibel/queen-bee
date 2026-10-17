import Foundation
import Testing
@testable import QueenBeeCore

/// What the review of stage 4 found, and the limits put on it: the pace of a card's bar and of what a device
/// says it watches, what a page can make the Mac send, roles carried without their whole instructions, the log a
/// device's Clear leaves, and pasting all or nothing.
@Suite struct RemoteReviewTests {
    private static func card(_ kind: CardKind, _ name: String, x: Double = 10, y: Double = 20) -> Card {
        Card.make(kind: kind, id: name.lowercased(), name: name, x: x, y: y)
    }

    // MARK: The pace of a card's bar

    @Test func aCardsBarIsSentAtMostFourTimesASecondAndAlwaysTheNewest() {
        let start = Date(timeIntervalSince1970: 1000)
        var throttle = LatestThrottle<String>(perSecond: Remote.browserPagesASecond)
        #expect(throttle.offer("a", now: start) == "a")
        // Too soon: held, and replaced by the one after it.
        #expect(throttle.offer("b", now: start.addingTimeInterval(0.05)) == nil)
        #expect(throttle.offer("c", now: start.addingTimeInterval(0.10)) == nil)
        #expect(throttle.dropped == 1)
        #expect(throttle.nextTry == start.addingTimeInterval(0.25))
        #expect(throttle.due(now: start.addingTimeInterval(0.2)) == nil)
        #expect(throttle.due(now: start.addingTimeInterval(0.25)) == "c")
        #expect(throttle.nextTry == nil)
        // Nothing held: nothing due, however long it has been.
        #expect(throttle.due(now: start.addingTimeInterval(9)) == nil)
        // A page that changes its address a hundred times in a second is sent four of them, the last among them.
        var sent: [Int] = []
        var pacing = LatestThrottle<Int>(perSecond: Remote.browserPagesASecond)
        for step in 0..<100 {
            let now = start.addingTimeInterval(10 + Double(step) * 0.01)
            if let due = pacing.due(now: now) { sent.append(due) }
            if let now = pacing.offer(step, now: now) { sent.append(now) }
        }
        if let last = pacing.due(now: start.addingTimeInterval(11.5)) { sent.append(last) }
        #expect(sent.count <= 6 && sent.last == 99)
    }

    @Test func whatAPageCanMakeTheMacSendIsCapped() throws {
        var page = RemoteBrowserPage(status: .running, isAttached: true, hasPicture: true, url: "https://example.com/" + String(repeating: "a", count: 2_000_000),
                                     title: String(repeating: "t", count: 5_000), addressProblem: String(repeating: "p", count: 1_000))
        page.isWatchOnly = true
        let sent = page.capped
        #expect(sent.url.count == Remote.browserURLLimit && sent.title.count == Remote.browserTitleLimit)
        #expect(sent.addressProblem?.count == Remote.browserTitleLimit && sent.isWatchOnly == nil)
        #expect(try Remote.encode(sent).count < 4_000)
    }

    @Test func aWatchOnlyDeviceShowsOneLineInPlaceOfThePage() {
        let page = RemoteBrowserPage.watchOnly
        #expect(page.notice == BrowserNotice(words: "Turn on “Can control” for this device to see the page."))
        #expect(page.url.isEmpty && page.title.isEmpty && page.notice?.offer == nil)
    }

    @Test func sayingWhichCardsAreOnScreenHasAPaceOfItsOwn() {
        let start = Date(timeIntervalSince1970: 1000)
        var bucket = TokenBucket(capacity: Remote.watchBurst, refill: Remote.watchesASecond, now: start)
        var taken: [Bool] = []
        for _ in 0..<8 { taken.append(bucket.take(now: start)) }
        taken.append(bucket.take(now: start.addingTimeInterval(0.1)))
        taken.append(bucket.take(now: start.addingTimeInterval(0.4)))
        taken.append(bucket.take(now: start.addingTimeInterval(0.4)))
        #expect(taken == Array(repeating: true, count: 8) + [false, true, false])
    }

    // MARK: Roles in the flow list

    @Test func aRoleIsListedWithTheStartOfItsInstructionsAndATellsApartForTheWhole() throws {
        let whole = String(repeating: "Check everything twice. ", count: 400)
        let role = RemoteRole.listed(id: "r", name: "Careful", instructions: whole, model: "", effort: "high", permissionMode: "plan",
                                     changedFrom: "iPad", changedAt: Date(timeIntervalSince1970: 5))
        #expect(role.instructions.count == Remote.roleInstructionsListed && !role.hasAllInstructions)
        var card = Self.card(.agent, "A")
        card.instructions = whole
        card.effort = "high"
        card.permissionMode = "plan"
        #expect(role.matches(card))
        card.instructions = whole + "."
        #expect(!role.matches(card))
        // A change past what is listed is still seen.
        card.instructions = String(whole.dropLast(3)) + "!!!"
        #expect(!role.matches(card))
        let short = RemoteRole.listed(id: "s", name: "Short", instructions: "Hi.", model: "", effort: "", permissionMode: "")
        var plain = Self.card(.agent, "B")
        plain.instructions = "Hi."
        #expect(short.hasAllInstructions && short.matches(plain))
        // A role from a Mac that sends its instructions whole is matched on them.
        #expect(RemoteRole(id: "o", name: "Old", instructions: "Hi.").matches(plain))
        let back = try Remote.decode(RemoteRole.self, from: Remote.encode(role))
        #expect(back == role && back.changedFrom == "iPad")
    }

    // MARK: The log a device's Clear leaves

    @Test func aDevicesClearLeavesWhatDevicesDidAndScheduleChanges() throws {
        let at = { (s: Double) in Date(timeIntervalSince1970: s) }
        let armed = LogLine(date: at(1), text: "iPad turned the schedule on for Start", isKept: true)
        let started = LogLine(date: at(2), text: "Starting Start: on schedule")
        let edit = LogLine(date: at(3), text: "iPad changed Shout's command", isKept: true)
        let off = LogLine(date: at(4), text: "iPad changed what the flow does, so its schedule is off until you turn it on again", isKept: true)
        let run = RunRecord(id: "r", started: at(1), ended: at(3), outcome: .stopped, command: "", log: [armed, started, edit],
                            results: [:], marks: [:], linkPasses: [:], messages: [:], handOffs: 0)
        let left = LogLine.leftByDeviceClear(log: [edit, off, LogLine(date: at(5), text: "Run stopped")], runs: [run])
        #expect(left.map(\.text) == [armed.text, edit.text, off.text])
        // An ordinary line is saved as it always was.
        #expect(try !String(decoding: Remote.encode(started), as: UTF8.self).contains("isKept"))
        #expect(try Remote.decode(LogLine.self, from: Remote.encode(armed)).isKept == true)
    }

    // MARK: Commands in order

    @Test func turningAScheduleOnWaitsBehindTheEditsSentBeforeIt() {
        #expect(RemoteCommand.armSchedule(flowID: "f", cardID: "s", on: true).waitsWithEdits)
        #expect(RemoteCommand.patchCard(flowID: "f", cardID: "s", patch: RemoteCardPatch()).waitsWithEdits)
        #expect(!RemoteCommand.keys(flowID: "f", key: "a", data: Data([0x61])).waitsWithEdits)
        #expect(!RemoteCommand.armSchedule(flowID: "f", cardID: "s", on: true).isEdit)
    }

    // MARK: Pasting

    @Test func aPasteFromADeviceIsAllOrNothing() throws {
        let a = Self.card(.script, "A"), b = Self.card(.agent, "B", x: 400)
        let stray = FlowFragment(cards: [a], links: [Link(id: "l", from: "a", port: "pass", to: "b")])
        #expect(stray.wholeProblem?.contains("isn't being pasted") == true)
        #expect(FlowFragment(cards: [a, a], links: []).wholeProblem?.contains("same id") == true)
        let overlapping = FlowFragment(cards: [a, b, Self.card(.end, "C")], links: [],
                                       groups: [CardGroup(id: "g", name: "One", cardIDs: ["a", "b"]), CardGroup(id: "h", name: "Two", cardIDs: ["b", "c"])])
        #expect(overlapping.wholeProblem != nil)
        let good = FlowFragment(cards: [a, b], links: [Link(id: "l", from: "a", port: "pass", to: "b")],
                                groups: [CardGroup(id: "g", name: "Both", cardIDs: ["a", "b"])])
        #expect(good.wholeProblem == nil)

        var flow = Flow(id: "f", name: "F")
        let made = try flow.insertWhole(good, dx: 10, dy: 10)
        #expect(made.count == 2 && flow.links.count == 1 && flow.groups?.count == 1)

        // A link the Mac wouldn't let anyone draw: the card to itself. Nothing is pasted, where a paste on the
        // Mac would have left the link out and kept the cards.
        let selfish = FlowFragment(cards: [a], links: [Link(id: "l", from: "a", port: "pass", to: "a")])
        let before = flow
        #expect(throws: FlowError.self) { try flow.insertWhole(selfish) }
        #expect(flow == before)
        flow.insert(selfish)
        #expect(flow.cards.count == before.cards.count + 1 && flow.links.count == before.links.count)
    }

    @Test func aPasteIsKeptOnTheCanvas() {
        let fragment = FlowFragment(cards: [Self.card(.end, "A", x: 90_000, y: -10), Self.card(.end, "B", x: 95_000, y: 50)], links: [])
        let step = fragment.offsetOnCanvas(dx: 50_000, dy: -200_000)
        #expect(step.dx == 5_000 && step.dy == -99_990)
        let wild = fragment.offsetOnCanvas(dx: .infinity, dy: .nan)
        #expect(wild.dx == 0 && wild.dy == 0)
        let usual = fragment.offsetOnCanvas(dx: 48, dy: 48)
        #expect(usual.dx == 48 && usual.dy == 48)
    }
}
