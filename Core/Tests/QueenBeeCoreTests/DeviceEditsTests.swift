import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct DeviceEditsTests {
    // MARK: Sizes, in bytes

    /// One character: a letter with that many marks stacked on it.
    private func stacked(_ marks: Int) -> String { "e" + String(repeating: "\u{0301}", count: marks) }

    private func patch(_ change: (inout RemoteCardPatch) -> Void) -> RemoteCommand {
        var patch = RemoteCardPatch()
        change(&patch)
        return .patchCard(flowID: "f", cardID: "a", patch: patch)
    }

    @Test func aNameIsCappedInBytesHoweverFewCharactersItIs() {
        let tall = stacked(500)
        #expect(tall.count == 1)
        #expect(tall.utf8.count == 1001)
        #expect(patch { $0.name = tall }.problem?.contains("too long") == true)
        #expect(RemoteCommand.renameFlow(flowID: "f", name: tall).problem != nil)
        #expect(RemoteCommand.newFlow(projectID: "p", name: tall).problem != nil)
        #expect(RemoteCommand.group(flowID: "f", cardIDs: ["a", "b"], name: tall).problem != nil)
        #expect(RemoteCommand.renameGroup(flowID: "f", groupID: "g", name: tall).problem != nil)
        #expect(RemoteCommand.addLink(flowID: "f", from: "a", port: tall, to: "b").problem != nil)
        #expect(patch { $0.branches = ["ok", tall] }.problem != nil)
        // Marks on a letter as people write them are fine, and so is every character being four bytes.
        #expect(patch { $0.name = "Cafe\u{0301} re\u{0301}sume\u{0301}" }.problem == nil)
        #expect(patch { $0.name = String(repeating: "😀", count: Remote.nameLimit) }.problem == nil)
        #expect(Remote.nameByteLimit == 4 * Remote.nameLimit)
    }

    @Test func longTextIsCappedInBytesToo() {
        // Sixteen thousand characters, each a letter under a pile of marks: megabytes by the old count.
        let heavy = String(repeating: stacked(20), count: Remote.textLimit)
        #expect(heavy.count == Remote.textLimit)
        for field in [\RemoteCardPatch.instructions, \.command, \.value, \.template, \.text] {
            #expect(patch { $0[keyPath: field] = heavy }.problem?.contains("too long") == true)
        }
        #expect(RemoteCommand.prompt(flowID: "f", key: "k", text: heavy).problem?.contains("too long") == true)
        #expect(RemoteCommand.approve(flowID: "f", holdID: "h", text: heavy).problem != nil)
        #expect(RemoteCommand.runFrom(flowID: "f", cardID: "c", text: heavy).problem != nil)
        // Three bytes to a character, as most of the world's writing is, fits to the last character.
        let cjk = String(repeating: "語", count: Remote.textLimit)
        #expect(cjk.utf8.count == Remote.textByteLimit)
        #expect(patch { $0.instructions = cjk }.problem == nil)
        #expect(patch { $0.saveTo = String(repeating: stacked(100), count: 100) }.problem != nil)
    }

    @Test func theBiggestTextStillFitsInOneMessageWithRoomToSpare() throws {
        var biggest = RemoteCardPatch()
        biggest.instructions = String(repeating: "語", count: Remote.textLimit)
        biggest.name = String(repeating: "😀", count: Remote.nameLimit)
        let message = DeviceMessage.command(id: 1, command: .patchCard(flowID: Flow.newID(), cardID: Flow.newID(), patch: biggest))
        #expect(biggest.problem == nil)
        #expect(try Remote.encode(message).count < 64 * 1024 - 8 * 1024)
    }

    @Test func aNameInTheLogIsShortAndWholeCharacters() {
        #expect(Remote.logName("Writer") == "Writer")
        #expect(Remote.logName("  \n ") == "a device")
        #expect(Remote.logName("", or: "a card") == "a card")
        let long = Remote.logName(String(repeating: "n", count: 200))
        #expect(long == String(repeating: "n", count: 60) + "…")
        // Cut between characters, never through one.
        let marked = Remote.logName(String(repeating: stacked(3), count: 100))
        #expect(marked.count == 61)
        #expect(marked.hasPrefix(stacked(3)))
        #expect(marked.unicodeScalars.count == 60 * 4 + 1)
        #expect(Remote.logName("a\u{1B}[2J\nb") == "a [2J b")
    }

    // MARK: What changes what a flow does

    private func flow() throws -> (Flow, start: String, agent: String, note: String, prompt: String) {
        var flow = Flow(name: "F")
        let start = try flow.addCard(kind: .start, x: 0, y: 0).id
        let agent = try flow.addCard(kind: .agent, x: 300, y: 0).id
        let prompt = try flow.addCard(kind: .prompt, x: 600, y: 0).id
        let note = try flow.addCard(kind: .note, x: 0, y: 300).id
        _ = try flow.addLink(from: start, port: "out", to: agent)
        return (flow, start, agent, note, prompt)
    }

    @Test func movingSizingGroupingAndNotesChangeNothingAFlowDoes() throws {
        let (old, start, agent, note, _) = try flow()
        var new = old
        var place = CardPatch()
        place.x = 900; place.y = 40; place.width = 500; place.height = 400
        try new.updateCard(agent, patch: place)
        _ = try new.addGroup(name: "Pair", cardIDs: [start, agent])
        var words = CardPatch()
        words.text = "Remember to water the plants."
        try new.updateCard(note, patch: words)
        _ = try new.addCard(kind: .note, x: 50, y: 50)
        new.name = "Renamed"
        new.cards.reverse()
        #expect(new != old)
        #expect(!new.changesWhatItDoes(from: old))
        // Nor does a session starting behind a card.
        new.cards[new.cards.firstIndex { $0.id == agent }!].sessionID = UUID().uuidString
        #expect(!new.changesWhatItDoes(from: old))
    }

    @Test func aLinkACardOrAnySettingChangesWhatAFlowDoes() throws {
        let (old, start, agent, _, prompt) = try flow()
        func changed(_ change: (inout Flow) throws -> Void) rethrows -> Bool {
            var new = old
            try change(&new)
            return new.changesWhatItDoes(from: old)
        }
        func set(_ id: String, _ change: (inout CardPatch) -> Void) throws -> Bool {
            try changed { flow in
                var patch = CardPatch()
                change(&patch)
                try flow.updateCard(id, patch: patch)
            }
        }
        let results: [Bool] = [
            try changed { flow in _ = try flow.addLink(from: agent, port: "out", to: prompt) },
            try changed { flow in try flow.removeLink(flow.links[0].id) },
            try changed { flow in try flow.updateLink(flow.links[0].id, maxPasses: 9) },
            try changed { flow in _ = try flow.addCard(kind: .script, x: 0, y: 0) },
            try changed { flow in try flow.removeCard(prompt) },
            try set(prompt) { $0.template = "Say: {{message}}" },
            try set(agent) { $0.instructions = "Do something else." },
            try set(agent) { $0.model = "haiku" },
            try set(agent) { $0.effort = "high" },
            try set(agent) { $0.permissionMode = "auto" },
            try set(agent) { $0.name = "Someone else" },
            try set(start) { $0.command = "another" },
            changed { flow in flow.cards[flow.cards.firstIndex { $0.id == start }!].trigger = Trigger(kind: .interval, minutes: 5) },
            changed { flow in flow.cards[flow.cards.firstIndex { $0.id == agent }!].cwd = "/tmp" },
        ]
        #expect(results == Array(repeating: true, count: results.count))
        let nothing = changed { _ in }
        #expect(!nothing)
    }

    // MARK: How fast

    @Test func aDeviceMaySendABurstAndThenSoManyASecond() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var bucket = TokenBucket(now: t0)
        func taken(at time: Date) -> Int {
            var taken = 0
            for _ in 0..<200 where bucket.take(now: time) { taken += 1 }
            return taken
        }
        #expect(taken(at: t0) == 60)
        #expect(taken(at: t0) == 0)
        // A second later there is room for twenty more, and no more than that.
        #expect(taken(at: t0 + 1) == 20)
        // Left alone it fills to a burst again, and never past it.
        #expect(taken(at: t0 + 3_600) == 60)
        // A clock that goes backwards gives nothing away.
        #expect(taken(at: t0) == 0)
        #expect(Remote.tooFastRefusal == "Too many changes at once. Try again in a moment.")
    }

    @Test func aDragsStepsAtTwentyASecondAreNeverRefused() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var bucket = TokenBucket(now: t0)
        var refused = 0
        for step in 0..<2_000 where !bucket.take(now: t0 + Double(step) / 20) { refused += 1 }
        #expect(refused == 0)
    }

    // MARK: How often the log is told

    @Test func theLogIsToldOfTheFirstAndThenHowManyMore() {
        var tally = EditTally()
        var firsts: [Bool] = [tally.count("d/f/addCard")]
        for _ in 0..<13 { firsts.append(tally.count("d/f/addCard")) }
        #expect(firsts == [true] + Array(repeating: false, count: 13))
        // Another kind, another flow and another device are each counted apart.
        let others = [tally.count("d/f/addLink"), tally.count("d/g/addCard"), tally.count("e/f/addCard")]
        #expect(others == [true, true, true])
        let closed = [tally.close("d/f/addCard"), tally.close("d/f/addLink"), tally.close("never")]
        #expect(closed == [13, 0, 0])
        // Closed, the next one is a first again.
        let again = tally.count("d/f/addCard")
        #expect(again)
        #expect(EditTally.more(13) == "13 more times")
        #expect(EditTally.more(1) == "once more")
        #expect(EditTally.window == 30)
    }

    // MARK: Opening the flow that was just made

    @Test func onlyTheFlowThatWasAskedForIsOpened() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func summary(_ id: String, _ name: String) -> RemoteFlowSummary { RemoteFlowSummary(id: id, name: name, isSubflow: false, activity: .quiet) }
        let before = [summary("a", "Rota"), summary("b", "Minutes")]
        let named = NewFlowAwaited(projectID: "p", known: ["a", "b"], name: "  Watering\nrota ", answered: t0)
        #expect(named.name == "Watering rota")
        // Not listed yet.
        #expect(named.flow(among: before, now: t0 + 0.1) == nil)
        // Listed, under the name that was asked for.
        #expect(named.flow(among: before + [summary("c", "Watering rota")], now: t0 + 0.3)?.id == "c")
        // Somebody else's flow turned up instead: another name. It is not opened.
        #expect(named.flow(among: before + [summary("d", "Something else")], now: t0 + 0.3) == nil)
        // Both turned up: the one asked for.
        #expect(named.flow(among: before + [summary("d", "Something else"), summary("c", "Watering rota")], now: t0 + 0.3)?.id == "c")
        // A flow that was there already is never the new one, whatever it is called.
        #expect(NewFlowAwaited(projectID: "p", known: ["a", "b"], name: "Rota", answered: t0).flow(among: before, now: t0 + 0.3) == nil)
        // Too late: whatever shows up now is not opened.
        #expect(named.flow(among: before + [summary("c", "Watering rota")], now: t0 + 5.1) == nil)
        #expect(named.isOver(at: t0 + 5.1))
        #expect(!named.isOver(at: t0 + 4.9))
    }

    @Test func aFlowTheMacNamedIsOpenedOnlyWhenItIsTheOnlyNewOne() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func summary(_ id: String, _ name: String) -> RemoteFlowSummary { RemoteFlowSummary(id: id, name: name, isSubflow: false, activity: .quiet) }
        let unnamed = NewFlowAwaited(projectID: "p", known: ["a"], name: "", answered: t0)
        #expect(unnamed.flow(among: [summary("a", "Rota"), summary("c", "Flow 2")], now: t0 + 1)?.id == "c")
        #expect(unnamed.flow(among: [summary("a", "Rota"), summary("c", "Flow 2"), summary("d", "Flow 3")], now: t0 + 1) == nil)
        #expect(unnamed.flow(among: [summary("a", "Rota")], now: t0 + 1) == nil)
        #expect(unnamed.flow(among: [summary("a", "Rota"), summary("c", "Flow 2")], now: t0 + 6) == nil)
    }
}
