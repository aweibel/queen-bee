import Foundation
import Testing
@testable import QueenBeeCore

/// The For each card: splitting a message into items, sending them on one at a time, and passing on what came back.
@Suite struct ForEachTests {
    private func patch(_ edit: (inout CardPatch) -> Void) -> CardPatch {
        var patch = CardPatch()
        edit(&patch)
        return patch
    }

    private func id(_ name: String, in flow: Flow) throws -> String {
        try #require(flow.resolveCard(name)).id
    }

    /// Start → Each; Each → Worker → Each; Done → End.
    private func eachFlow(command: String, _ settings: CardPatch = CardPatch(), build: (inout Flow) throws -> Void = { _ in }) throws -> Flow {
        var flow = Flow(name: "Test")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = command })
        try flow.addCard(kind: .forEach, name: "Each", patch: settings)
        try flow.addCard(kind: .agent, name: "Worker")
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Each")
        try flow.addLink(from: "Each", port: "each", to: "Worker")
        try flow.addLink(from: "Worker", to: "Each")
        try flow.addLink(from: "Each", port: "done", to: "End")
        try build(&flow)
        return flow
    }

    /// The text of the message handed over, without the line saying which run it belongs to.
    private func body(_ delivery: Delivery?) -> String? {
        delivery.map { String($0.text.split(separator: "\n", maxSplits: 1).last ?? "") }
    }

    // MARK: Items

    @Test func itemsComeOneLineAtATimeWithBlankLinesSkipped() {
        #expect(Checks.items(in: "apples\n\n  pears \r\nplums\n", split: .auto) == ["apples", "pears", "plums"])
        #expect(Checks.items(in: "   \n ", split: .auto).isEmpty)
    }

    @Test func aJSONArrayGivesItsElements() {
        #expect(Checks.items(in: #"["a", {"k": 1}, 2, ""]"#, split: .auto) == ["a", #"{"k":1}"#, "2"])
        // As agents often write it, in a fence.
        #expect(Checks.items(in: "```json\n[\"x\", \"y\"]\n```", split: .auto) == ["x", "y"])
        #expect(Checks.items(in: "```\n[\"x\"]\n```", split: .auto) == ["x"])
        // JSON that isn't an array, and an array split by lines, are lines.
        #expect(Checks.items(in: #"{"a": 1}"#, split: .auto) == [#"{"a": 1}"#])
        #expect(Checks.items(in: "[\"a\",\n\"b\"]", split: .lines) == ["[\"a\",", "\"b\"]"])
    }

    // MARK: Going through them

    @Test func eachItemGoesOutInTurnAndDoneCarriesEveryResult() async throws {
        // More items than a link's usual 3 passes: each item is a fresh pass through the cards on Each.
        let flow = try eachFlow(command: "a\nb\nc\nd\ne")
        let worker = try id("Worker", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(started.deliveries.map(\.toCardID) == [worker])
        #expect(body(started.deliveries.first) == "a")
        #expect(started.log.contains("For each \"Each\" → Each (item 1 of 5)"))
        var last = RunOutput()
        for (item, next) in zip(["a", "b", "c", "d", "e"], ["b", "c", "d", "e", nil]) {
            last = await engine.agentReplied(flow: flow, cardID: worker, text: item.uppercased())
            #expect(body(last.deliveries.first) == next)
        }
        #expect(last.finished && last.ending == .finishedWithAnswer)
        let combined = Checks.combine(["a", "b", "c", "d", "e"].enumerated().map { (from: "item \($0.offset + 1): \($0.element)", text: $0.element.uppercased()) })
        #expect(last.results.map(\.text) == [combined])
        #expect(last.log.contains("For each \"Each\" → Done, with what came back for all 5 items"))
    }

    @Test func aJSONArrayMessageIsSplitIntoItsElements() async throws {
        let flow = try eachFlow(command: #"["first", "second"]"#)
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(body(started.deliveries.first) == "first")
        let next = await engine.agentReplied(flow: flow, cardID: try id("Worker", in: flow), text: "1")
        #expect(body(next.deliveries.first) == "second")
    }

    @Test func aMessageWithNoItemsGoesStraightToDone() async throws {
        let flow = try eachFlow(command: "[]")
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(out.deliveries.isEmpty)
        #expect(out.results.map(\.text) == ["[]"])
        #expect(out.log.contains("For each \"Each\" found no items in the message from Start, so it went straight to Done"))
        #expect(out.finished)
    }

    @Test func itemsPastTheMostAreLeftOut() async throws {
        let flow = try eachFlow(command: "1\n2\n3\n4\n5", patch { $0.maxItems = 2 })
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(started.log.contains("For each \"Each\" found 5 items and sends on the first 2, its most"))
        let worker = try id("Worker", in: flow)
        _ = await engine.agentReplied(flow: flow, cardID: worker, text: "one")
        let done = await engine.agentReplied(flow: flow, cardID: worker, text: "two")
        #expect(done.results.count == 1 && done.finished)
    }

    @Test func aLoopInsideTheBodyRunsForEachItem() async throws {
        // Each → Worker → Check; Again → Worker; Done → back into Each.
        var flow = Flow(name: "Test")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "a\nb" })
        try flow.addCard(kind: .forEach, name: "Each")
        try flow.addCard(kind: .agent, name: "Worker")
        try flow.addCard(kind: .loop, name: "Check", patch: patch { $0.check = .contains; $0.value = "OK"; $0.maxTries = 3 })
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Each")
        try flow.addLink(from: "Each", port: "each", to: "Worker")
        try flow.addLink(from: "Worker", to: "Check")
        try flow.addLink(from: "Check", port: "again", to: "Worker")
        try flow.addLink(from: "Check", port: "done", to: "Each")
        try flow.addLink(from: "Each", port: "done", to: "End")
        let worker = try id("Worker", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let again = await engine.agentReplied(flow: flow, cardID: worker, text: "draft a")
        #expect(body(again.deliveries.first) == "draft a")
        let next = await engine.agentReplied(flow: flow, cardID: worker, text: "OK a")
        #expect(body(next.deliveries.first) == "b")
        _ = await engine.agentReplied(flow: flow, cardID: worker, text: "draft b")
        let done = await engine.agentReplied(flow: flow, cardID: worker, text: "OK b")
        #expect(done.results.first?.text.contains("## From item 2: b\nOK b") == true)
        #expect(done.ending == .finishedWithAnswer)
    }

    @Test func anOrInTheBodyPassesOnAMessageForEveryItem() async throws {
        // Each → Which; Yes → A, No → B; both → First → back into Each. Each item goes one way.
        var flow = Flow(name: "Test")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "yes 1\nno 2\nyes 3" })
        try flow.addCard(kind: .forEach, name: "Each")
        try flow.addCard(kind: .ifElse, name: "Which", patch: patch { $0.check = .contains; $0.value = "yes" })
        try flow.addCard(kind: .agent, name: "A")
        try flow.addCard(kind: .agent, name: "B")
        try flow.addCard(kind: .or, name: "First")
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Each")
        try flow.addLink(from: "Each", port: "each", to: "Which")
        try flow.addLink(from: "Which", port: "yes", to: "A")
        try flow.addLink(from: "Which", port: "no", to: "B")
        try flow.addLink(from: "A", to: "First")
        try flow.addLink(from: "B", to: "First")
        try flow.addLink(from: "First", to: "Each")
        try flow.addLink(from: "Each", port: "done", to: "End")
        let a = try id("A", in: flow), b = try id("B", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(started.deliveries.map(\.toCardID) == [a])
        let second = await engine.agentReplied(flow: flow, cardID: a, text: "A 1")
        #expect(second.deliveries.map(\.toCardID) == [b])
        let third = await engine.agentReplied(flow: flow, cardID: b, text: "B 2")
        #expect(third.deliveries.map(\.toCardID) == [a])
        let done = await engine.agentReplied(flow: flow, cardID: a, text: "A 3")
        #expect(done.results.first?.text.contains("## From item 3: yes 3\nA 3") == true)
        #expect(done.finished)
    }

    @Test func aMessageFromOutsideTheBodyWhileItemsAreOutIsDropped() async throws {
        let flow = try eachFlow(command: "a\nb") {
            try $0.addCard(kind: .agent, name: "Other")
            try $0.addLink(from: "Start", to: "Other")
            try $0.addLink(from: "Other", to: "Each")
        }
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Other", in: flow), text: "late")
        #expect(out.log.contains("For each \"Each\" is still going through its items, so it dropped a message from Other"))
        #expect(out.deliveries.isEmpty && !out.finished)
    }

    @Test func aRunWhoseItemNeverComesBackSaysSo() async throws {
        var flow = try eachFlow(command: "a\nb")
        let worker = try id("Worker", in: flow)
        flow.links.removeAll { $0.from == worker }
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Worker", in: flow), text: "A")
        #expect(out.finished && out.ending == .endedWithoutAnswer)
        #expect(out.log.contains("For each \"Each\" was still waiting for what came back for item 1 of 2 when the run ended"))
    }

    @Test func stoppingMidWayEndsTheRunAndInterruptsTheWorker() async throws {
        let flow = try eachFlow(command: "a\nb\nc")
        let worker = try id("Worker", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: worker, text: "A")
        let stopped = await engine.stop()
        #expect(stopped.finished && stopped.ending == .stopped && stopped.leftWaiting == [worker])
        let late = await engine.agentReplied(flow: flow, cardID: worker, text: "B")
        #expect(late.deliveries.isEmpty && late.results.isEmpty)
        // A new run starts from the first item again.
        let again = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(body(again.deliveries.first) == "a")
    }

    @Test func everyHandOffForAnItemCountsTowardTheRunsLimit() async throws {
        // Two agents per item, 30 items: the run stops at the hand-off limit part-way.
        let items = (1...30).map(String.init).joined(separator: "\n")
        let flow = try eachFlow(command: items, patch { $0.maxItems = 30 }) { flow in
            try flow.addCard(kind: .agent, name: "Checker")
            let each = flow.resolveCard("Each")?.id, worker = flow.resolveCard("Worker")?.id
            flow.links.removeAll { $0.to == each && $0.from == worker }
            try flow.addLink(from: "Worker", to: "Checker")
            try flow.addLink(from: "Checker", to: "Each")
        }
        let worker = try id("Worker", in: flow), checker = try id("Checker", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        var handOffs = 1
        var last = RunOutput()
        for turn in 0..<100 {
            last = await engine.agentReplied(flow: flow, cardID: turn.isMultiple(of: 2) ? worker : checker, text: "ok")
            handOffs += last.deliveries.count
            if last.finished { break }
        }
        #expect(last.finished && last.ending == .hitLimit)
        #expect(handOffs == Engine.maxDeliveries)
    }

    @Test func startingARunAtTheCardGoesThroughTheMessageGiven() async throws {
        let flow = try eachFlow(command: "unused")
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: flow, at: try id("Each", in: flow), message: "x\ny", fromName: "You")
        #expect(body(out.deliveries.first) == "x")
    }

    // MARK: Settings and warnings

    @Test func settingsAreKeptWithinTheirLimits() throws {
        var flow = Flow(name: "Test")
        let card = try flow.addCard(kind: .forEach, name: "Each", patch: patch { $0.maxItems = 500; $0.split = .lines })
        #expect(card.maxItems == Engine.mostItems && card.split == .lines)
        #expect(try flow.updateCard("Each", patch: patch { $0.maxItems = 0 }).maxItems == 1)
        // A setting of another kind of card is left alone.
        #expect(try flow.updateCard("Each", patch: patch { $0.maxTries = 4 }).maxTries == nil)
        #expect(ports(of: card) == ["each", "done"])
    }

    @Test func warningsSayWhatTheCardIsMissing() throws {
        var flow = Flow(name: "Test")
        try flow.addCard(kind: .start, name: "Start", patch: patch { $0.command = "go" })
        try flow.addCard(kind: .forEach, name: "Each")
        try flow.addCard(kind: .agent, name: "Worker")
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Each")
        let each = try id("Each", in: flow)
        #expect(warnings(for: flow)[each] == "Nothing on Each")
        try flow.addLink(from: "Each", port: "each", to: "Worker")
        #expect(warnings(for: flow)[each] == "Nothing on Each links back to it")
        try flow.addLink(from: "Worker", to: "Each")
        #expect(warnings(for: flow)[each] == "Nothing on Done")
        try flow.addLink(from: "Each", port: "done", to: "End")
        #expect(warnings(for: flow)[each] == nil)
    }
}
