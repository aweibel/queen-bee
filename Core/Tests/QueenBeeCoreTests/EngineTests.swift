import Foundation
import Testing
@testable import QueenBeeCore

/// Answers from a queue and remembers what it was asked. An empty queue answers nil, as a failed judge call does.
actor ScriptedJudge: Judge {
    private var holdsAnswers: [Bool?]
    private var pickAnswers: [String?]
    private let delay: Duration?
    private(set) var statements: [(statement: String, message: String)] = []
    private(set) var picks: [(branches: [String], message: String)] = []
    private var inFlight = 0
    private(set) var mostInFlight = 0

    init(holds: [Bool?] = [], picks: [String?] = [], delay: Duration? = nil) {
        holdsAnswers = holds; pickAnswers = picks; self.delay = delay
    }

    func holds(statement: String, message: String) async -> Bool? {
        statements.append((statement, message))
        await work()
        return holdsAnswers.isEmpty ? nil : holdsAnswers.removeFirst()
    }

    func pick(branches: [String], message: String) async -> String? {
        picks.append((branches, message))
        await work()
        return pickAnswers.isEmpty ? nil : pickAnswers.removeFirst()
    }

    /// Suspends like a real call would, so overlapping engine calls would show up as two in flight.
    private func work() async {
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        if let delay { try? await Task.sleep(for: delay) }
        inFlight -= 1
    }
}

@Suite struct EngineTests {
    // MARK: Building flows

    private func flow(_ build: (inout Flow) throws -> Void) rethrows -> Flow {
        var flow = Flow(name: "Test")
        try build(&flow)
        return flow
    }

    private func patch(_ edit: (inout CardPatch) -> Void) -> CardPatch {
        var patch = CardPatch()
        edit(&patch)
        return patch
    }

    private func id(_ name: String, in flow: Flow) throws -> String {
        try #require(flow.resolveCard(name)).id
    }

    /// Start → Writer → Reviewer.
    private func chain() throws -> Flow {
        try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Write a haiku" })
            try $0.addCard(kind: .agent, name: "Writer")
            try $0.addCard(kind: .agent, name: "Reviewer")
            try $0.addLink(from: "Start", to: "Writer")
            try $0.addLink(from: "Writer", to: "Reviewer")
        }
    }

    /// A fresh run of `flow`, for a test that has the same agent answer more than once: an agent
    /// is owed one reply for each message it was handed, so a second answer needs a second run.
    private func restart(_ engine: Engine, _ flow: Flow) async {
        _ = await engine.stop()
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
    }

    /// Start → Writer → `logic` card, so tests only add what comes after it.
    private func writerInto(_ kind: CardKind, name: String, _ settings: CardPatch = CardPatch(),
                            then build: (inout Flow) throws -> Void) throws -> Flow {
        try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
            try $0.addCard(kind: .agent, name: "Writer")
            try $0.addCard(kind: kind, name: name, patch: settings)
            try $0.addLink(from: "Start", to: "Writer")
            // Some tests send the Writer's reply through more than three times; the link limit isn't their subject.
            try $0.addLink(from: "Writer", to: name, maxPasses: 10)
            try build(&$0)
        }
    }

    // MARK: Start and agents

    @Test func startDeliversTheCommandToTheLinkedAgent() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: flow, startCardID: nil, command: nil)
        let run = try #require(out.runID)
        #expect(out.deliveries == [
            Delivery(toCardID: try id("Writer", in: flow), text: "[Queen Bee · run \(run) · start]\nWrite a haiku", fromName: "Start"),
        ])
        #expect(out.log == ["Start → Writer"])
        #expect(!out.finished)
        #expect(await engine.isRunning)
        #expect(await engine.runID == run)
    }

    @Test func aTypedCommandReplacesTheCardsCommand() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        let typed = await engine.start(flow: flow, startCardID: try id("Start", in: flow), command: "Write a limerick")
        #expect(typed.deliveries.first?.text.hasSuffix("\nWrite a limerick") == true)
        _ = await engine.stop()
        let blank = await engine.start(flow: flow, startCardID: nil, command: "  ")
        #expect(blank.deliveries.first?.text.hasSuffix("\nWrite a haiku") == true)
    }

    @Test func startPicksTheGivenStartCard() async throws {
        var flow = try chain()
        try flow.addCard(kind: .start, name: "Second", patch: patch { $0.command = "Review this" })
        try flow.addLink(from: "Second", to: "Reviewer")
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: flow, startCardID: try id("Second", in: flow), command: nil)
        #expect(out.deliveries.map(\.toCardID) == [try id("Reviewer", in: flow)])
        #expect(out.deliveries.first?.text.hasSuffix("\nReview this") == true)
    }

    @Test func aFlowWithNoStartCardRunsNothing() async throws {
        let flow = try flow { try $0.addCard(kind: .agent, name: "Writer") }
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: flow, startCardID: nil, command: "Go")
        #expect(out.deliveries.isEmpty && out.log.count == 1 && out.finished && out.runID == nil)
        #expect(await !engine.isRunning)
    }

    @Test func anAgentsReplyGoesToTheNextAgent() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        let run = try #require(started.runID)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        #expect(out.deliveries == [
            Delivery(toCardID: try id("Reviewer", in: flow),
                     text: "[Queen Bee · run \(run) · hand-off 2 · from Writer]\nOld pond", fromName: "Writer"),
        ])
        #expect(out.log == ["Writer → Reviewer"])
        #expect(!out.finished && out.runID == run)
    }

    @Test func theRunFinishesWhenNothingIsPending() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        let out = await engine.agentReplied(flow: flow, cardID: try id("Reviewer", in: flow), text: "Lovely")
        #expect(out.deliveries.isEmpty && out.finished && out.runID != nil)
        #expect(await !engine.isRunning)
        #expect(await engine.runID == nil)
    }

    @Test func aReplyWithNoRunActiveRoutesNothing() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        #expect(out == RunOutput())
        #expect(out.runID == nil && !out.finished)
    }

    @Test func noReplyPassesNothingOn() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "  [No Reply]\n")
        #expect(out.deliveries.isEmpty && out.finished)

        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let empty = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: " \n")
        #expect(empty.deliveries.isEmpty && empty.finished)
    }

    @Test func aTurnThatEndsOnAQuestionIsNotTheAnswer() async throws {
        var flow = try chain()
        let from = try id("Writer", in: flow)
        let link = try #require(flow.links.first { $0.from == from })
        try flow.updateLink(link.id, maxPasses: 1)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let writer = try id("Writer", in: flow)

        let asked = await engine.agentReplied(flow: flow, cardID: writer, text: "I've asked the orchestrator.", waitingOnAnswer: true)
        #expect(asked.deliveries.isEmpty && asked.visits.isEmpty && !asked.finished)
        #expect(asked.log == ["Writer asked a question and is waiting for the answer"])
        // Nobody else is working, so the run now hangs on that answer.
        #expect(asked.stalledOn == [writer] && asked.asking == [writer])

        // The answer came, and the turn after it is the reply. The link's one pass is still unspent.
        let out = await engine.agentReplied(flow: flow, cardID: writer, text: "Old pond")
        #expect(out.deliveries.count == 1 && out.deliveries.first?.text.hasSuffix("Old pond") == true)
        #expect(out.stalledOn.isEmpty && out.asking == [])
    }

    @Test func aQuestionFromAnAgentTheRunIsNotWaitingOnChangesNothing() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Reviewer", in: flow), text: "Asked", waitingOnAnswer: true)
        #expect(out.log.isEmpty && out.asking == [] && out.stalledOn.isEmpty && !out.finished)
    }

    @Test func aCallThatDoesNotSettleTheRunSaysNothingAboutWhoIsAsking() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Asked", waitingOnAnswer: true)
        // A second Run pressed while the first hangs is refused, and must not look like news that nobody is asking.
        let again = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(again.asking == nil)
    }

    @Test func aRunWithOthersStillWorkingIsNotStalledByAQuestion() async throws {
        let flow = try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
            try $0.addCard(kind: .agent, name: "A")
            try $0.addCard(kind: .agent, name: "B")
            try $0.addLink(from: "Start", to: "A")
            try $0.addLink(from: "Start", to: "B")
        }
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "Hold on", waitingOnAnswer: true)
        #expect(out.stalledOn.isEmpty && !out.finished)
        let then = await engine.agentReplied(flow: flow, cardID: try id("B", in: flow), text: "[no reply]")
        #expect(then.stalledOn == [try id("A", in: flow)] && !then.finished)
    }

    @Test func aReplyTypedIntoAnIdleAgentJoinsTheRun() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        // The Reviewer was never handed anything, but its person typed to it mid-run.
        let out = await engine.agentReplied(flow: flow, cardID: try id("Reviewer", in: flow), text: "Unprompted")
        #expect(out.deliveries.isEmpty && !out.finished)
        #expect(await engine.isRunning)
    }

    // MARK: If

    @Test func ifRoutesOnATextCheck() async throws {
        let flow = try writerInto(.ifElse, name: "Approved?", patch { $0.check = .contains; $0.value = "approved" }) {
            try $0.addCard(kind: .agent, name: "Publisher")
            try $0.addCard(kind: .agent, name: "Fixer")
            try $0.addLink(from: "Approved?", port: "yes", to: "Publisher")
            try $0.addLink(from: "Approved?", port: "no", to: "Fixer")
        }
        let judge = ScriptedJudge()
        let engine = Engine(judge: judge)
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let yes = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "APPROVED, ship it")
        #expect(yes.deliveries.map(\.toCardID) == [try id("Publisher", in: flow)])
        #expect(yes.deliveries.first?.fromName == "Writer")
        #expect(yes.log == ["If \"Approved?\" → Yes", "Writer → Publisher"])

        await restart(engine, flow)
        let no = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Needs work")
        #expect(no.deliveries.map(\.toCardID) == [try id("Fixer", in: flow)])
        #expect(no.log == ["If \"Approved?\" → No", "Writer → Fixer"])
        #expect(await judge.statements.isEmpty)
    }

    @Test func ifRoutesOnAJudgeCheck() async throws {
        let flow = try writerInto(.ifElse, name: "Good?", patch { $0.check = .judge; $0.value = "The poem is a haiku" }) {
            try $0.addCard(kind: .agent, name: "Publisher")
            try $0.addCard(kind: .agent, name: "Fixer")
            try $0.addLink(from: "Good?", port: "yes", to: "Publisher")
            try $0.addLink(from: "Good?", port: "no", to: "Fixer")
        }
        let judge = ScriptedJudge(holds: [true, false])
        let engine = Engine(judge: judge)
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let yes = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        #expect(yes.deliveries.map(\.toCardID) == [try id("Publisher", in: flow)])
        await restart(engine, flow)
        let no = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "A sonnet")
        #expect(no.deliveries.map(\.toCardID) == [try id("Fixer", in: flow)])
        let asked = await judge.statements
        #expect(asked.map(\.statement) == ["The poem is a haiku", "The poem is a haiku"])
        #expect(asked.map(\.message) == ["Old pond", "A sonnet"])
    }

    @Test func anUnjudgeableConditionCountsAsNo() async throws {
        let flow = try writerInto(.ifElse, name: "Good?", patch { $0.check = .judge; $0.value = "The poem is a haiku" }) {
            try $0.addCard(kind: .agent, name: "Publisher")
            try $0.addCard(kind: .agent, name: "Fixer")
            try $0.addLink(from: "Good?", port: "yes", to: "Publisher")
            try $0.addLink(from: "Good?", port: "no", to: "Fixer")
        }
        let engine = Engine(judge: ScriptedJudge(holds: [nil]))
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        #expect(out.deliveries.map(\.toCardID) == [try id("Fixer", in: flow)])
        #expect(out.log.count == 3)
        #expect(out.log.first?.contains("could not be judged") == true)
        #expect(out.log.dropFirst().first == "If \"Good?\" → No")
    }

    // MARK: Switch

    @Test func switchTakesThePickedBranchOrOther() async throws {
        let flow = try writerInto(.switchCard, name: "Triage", patch { $0.branches = ["bug", "feature"] }) {
            try $0.addCard(kind: .agent, name: "Fixer")
            try $0.addCard(kind: .agent, name: "Builder")
            try $0.addCard(kind: .agent, name: "Helper")
            try $0.addLink(from: "Triage", port: "bug", to: "Fixer")
            try $0.addLink(from: "Triage", port: "feature", to: "Builder")
            try $0.addLink(from: "Triage", port: "other", to: "Helper")
        }
        let judge = ScriptedJudge(picks: ["feature", "Bug", "poetry", nil])
        let engine = Engine(judge: judge)
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let writer = try id("Writer", in: flow)

        let feature = await engine.agentReplied(flow: flow, cardID: writer, text: "Add dark mode")
        #expect(feature.deliveries.map(\.toCardID) == [try id("Builder", in: flow)])
        #expect(feature.log.first == "Switch \"Triage\" → feature")
        await restart(engine, flow)
        let bug = await engine.agentReplied(flow: flow, cardID: writer, text: "It crashes")
        #expect(bug.deliveries.map(\.toCardID) == [try id("Fixer", in: flow)])
        await restart(engine, flow)
        let unknown = await engine.agentReplied(flow: flow, cardID: writer, text: "A haiku")
        #expect(unknown.deliveries.map(\.toCardID) == [try id("Helper", in: flow)])
        #expect(unknown.log.first == "Switch \"Triage\" → Other")
        await restart(engine, flow)
        let failed = await engine.agentReplied(flow: flow, cardID: writer, text: "???")
        #expect(failed.deliveries.map(\.toCardID) == [try id("Helper", in: flow)])

        let asked = await judge.picks
        #expect(asked.count == 4)
        #expect(asked.first?.branches == ["bug", "feature"])
        #expect(asked.first?.message == "Add dark mode")
    }

    // MARK: And, Or

    /// Start → A and B, both → `kind` → Editor.
    private func fanIn(_ kind: CardKind, name: String) throws -> Flow {
        try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
            try $0.addCard(kind: .agent, name: "A")
            try $0.addCard(kind: .agent, name: "B")
            try $0.addCard(kind: kind, name: name)
            try $0.addCard(kind: .agent, name: "Editor")
            try $0.addLink(from: "Start", to: "A")
            try $0.addLink(from: "Start", to: "B")
            try $0.addLink(from: "A", to: name)
            try $0.addLink(from: "B", to: name)
            try $0.addLink(from: name, to: "Editor")
        }
    }

    @Test func andWaitsForEveryInputAndCombinesThemInLinkOrder() async throws {
        let flow = try fanIn(.and, name: "Both")
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(started.deliveries.map(\.toCardID) == [try id("A", in: flow), try id("B", in: flow)])
        #expect(started.deliveries.allSatisfy { $0.text.contains("· start]") })

        // B answers first; the And still lists A first because A's link comes first.
        let first = await engine.agentReplied(flow: flow, cardID: try id("B", in: flow), text: "Second draft")
        #expect(first.deliveries.isEmpty && !first.finished)
        let second = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "First draft")
        let delivery = try #require(second.deliveries.first)
        #expect(second.deliveries.count == 1)
        #expect(delivery.toCardID == (try id("Editor", in: flow)))
        #expect(delivery.fromName == "Both")
        #expect(delivery.text.hasSuffix("· from Both]\n## From A\nFirst draft\n\n## From B\nSecond draft"))
    }

    @Test func andStartsOverAfterItFires() async throws {
        var flow = try fanIn(.and, name: "Both")
        try flow.addLink(from: "Editor", to: "A")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "one")
        _ = await engine.agentReplied(flow: flow, cardID: try id("B", in: flow), text: "two")
        _ = await engine.agentReplied(flow: flow, cardID: try id("Editor", in: flow), text: "again please")
        // Only A has answered since the And last fired, so it waits for B again.
        let out = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "three")
        #expect(out.deliveries.isEmpty)
    }

    @Test func orPassesTheFirstReplyAndDropsLaterOnes() async throws {
        let flow = try fanIn(.or, name: "First")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let first = await engine.agentReplied(flow: flow, cardID: try id("B", in: flow), text: "B wins")
        #expect(first.deliveries.map(\.toCardID) == [try id("Editor", in: flow)])
        #expect(first.deliveries.first?.fromName == "B")
        #expect(first.deliveries.first?.text.hasSuffix("· from B]\nB wins") == true)
        let later = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "A is late")
        #expect(later.deliveries.isEmpty)
        #expect(later.log.count == 1)
        #expect(later.log.first?.contains("dropped") == true)
    }

    @Test func orFiresAgainInANewRun() async throws {
        let flow = try fanIn(.or, name: "First")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "one")
        _ = await engine.stop()
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "two")
        #expect(out.deliveries.count == 1)
    }

    // MARK: Prompt, End

    @Test func promptRewritesTheMessageAndKeepsTheSender() async throws {
        let flow = try writerInto(.prompt, name: "Brief", patch { $0.template = "{{from}} wrote this. Review it:\n{{message}}" }) {
            try $0.addCard(kind: .agent, name: "Reviewer")
            try $0.addLink(from: "Brief", to: "Reviewer")
        }
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        let delivery = try #require(out.deliveries.first)
        #expect(delivery.fromName == "Writer")
        #expect(delivery.text.hasSuffix("· from Writer]\nWriter wrote this. Review it:\nOld pond"))
    }

    @Test func aPromptRightAfterStartStillCountsAsTheStart() async throws {
        let flow = try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "haiku" })
            try $0.addCard(kind: .prompt, name: "Brief", patch: patch { $0.template = "Write a {{message}} for {{from}}" })
            try $0.addCard(kind: .agent, name: "Writer")
            try $0.addLink(from: "Start", to: "Brief")
            try $0.addLink(from: "Brief", to: "Writer")
        }
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(out.deliveries.first?.fromName == "Start")
        #expect(out.deliveries.first?.text.hasSuffix("· start]\nWrite a haiku for Start") == true)
    }

    @Test func endRecordsTheResultAndWhereToSaveIt() async throws {
        let flow = try writerInto(.end, name: "Done", patch { $0.saveTo = "out/haiku.md" }) {
            try $0.addCard(kind: .end, name: "Shown")
            try $0.addLink(from: "Writer", to: "Shown")
        }
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        #expect(out.results == [
            EndResult(cardID: try id("Done", in: flow), cardName: "Done", text: "Old pond", saveTo: "out/haiku.md"),
            EndResult(cardID: try id("Shown", in: flow), cardName: "Shown", text: "Old pond", saveTo: nil),
        ])
        #expect(out.deliveries.isEmpty && out.finished)
    }

    // MARK: Loop

    /// Writer → Loop; Again → Writer; Done → End.
    private func loopFlow(_ settings: CardPatch) throws -> Flow {
        try writerInto(.loop, name: "Polish", settings) {
            try $0.addCard(kind: .end, name: "Done")
            try $0.addLink(from: "Polish", port: "again", to: "Writer", maxPasses: 10)
            try $0.addLink(from: "Polish", port: "done", to: "Done")
        }
    }

    @Test func loopGoesAgainUntilItsCheckHolds() async throws {
        let flow = try loopFlow(patch { $0.check = .contains; $0.value = "FINAL"; $0.maxTries = 5 })
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let writer = try id("Writer", in: flow)
        let again = await engine.agentReplied(flow: flow, cardID: writer, text: "draft")
        #expect(again.deliveries.map(\.toCardID) == [writer])
        #expect(again.deliveries.first?.text.hasSuffix("· from Writer]\ndraft") == true)
        #expect(again.log.first == "Loop \"Polish\" → Again (try 1 of 5)")
        let done = await engine.agentReplied(flow: flow, cardID: writer, text: "FINAL draft")
        #expect(done.deliveries.isEmpty)
        #expect(done.results.map(\.text) == ["FINAL draft"])
        #expect(done.log.first == "Loop \"Polish\" → Done")
        #expect(done.finished)
    }

    @Test func loopGivesUpAfterMaxTries() async throws {
        let flow = try loopFlow(patch { $0.check = .judge; $0.value = "It is perfect"; $0.maxTries = 2 })
        // One real "no" and one failed judge call: both count as a try.
        let engine = Engine(judge: ScriptedJudge(holds: [false, nil]))
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let writer = try id("Writer", in: flow)
        let again = await engine.agentReplied(flow: flow, cardID: writer, text: "one")
        #expect(again.deliveries.map(\.toCardID) == [writer])
        let done = await engine.agentReplied(flow: flow, cardID: writer, text: "two")
        #expect(done.deliveries.isEmpty)
        #expect(done.results.map(\.text) == ["two"])
        #expect(done.log.contains { $0.contains("could not be judged") })
        #expect(done.log.contains("Loop \"Polish\" → Done after 2 tries"))
    }

    @Test func loopTriesDefaultToThree() async throws {
        var flow = try loopFlow(patch { $0.check = .contains; $0.value = "FINAL" })
        let index = try #require(flow.cards.firstIndex { $0.name == "Polish" })
        flow.cards[index].maxTries = nil
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let writer = try id("Writer", in: flow)
        var ports: [Bool] = []
        for _ in 1...3 {
            let out = await engine.agentReplied(flow: flow, cardID: writer, text: "draft")
            ports.append(out.results.isEmpty)
        }
        #expect(ports == [true, true, false])
    }

    // MARK: Limits

    /// Start → Writer ⇄ Reviewer.
    private func pingPong(maxPasses: Int) throws -> Flow {
        var flow = try chain()
        try flow.updateLink(try #require(flow.links.last).id, maxPasses: maxPasses)
        try flow.addLink(from: "Reviewer", to: "Writer", maxPasses: maxPasses)
        return flow
    }

    @Test func aLinkStopsAtItsMaxPasses() async throws {
        let flow = try pingPong(maxPasses: 2)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let writer = try id("Writer", in: flow), reviewer = try id("Reviewer", in: flow)
        var handOffs = 0
        var last = RunOutput()
        for turn in 0..<10 {
            last = await engine.agentReplied(flow: flow, cardID: turn.isMultiple(of: 2) ? writer : reviewer, text: "turn \(turn)")
            handOffs += last.deliveries.count
            if last.finished { break }
        }
        #expect(handOffs == 4)
        #expect(last.log == ["Link Writer → Reviewer stopped: it reached its limit of 2 for this run"])
        #expect(last.finished)
        #expect(await !engine.isRunning)
    }

    @Test func passCountsStartFreshEachRun() async throws {
        var flow = try chain()
        try flow.updateLink(try #require(flow.links.last).id, maxPasses: 1)
        let engine = Engine(judge: ScriptedJudge())
        for _ in 1...2 {
            _ = await engine.start(flow: flow, startCardID: nil, command: nil)
            let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "draft")
            #expect(out.deliveries.count == 1)
            _ = await engine.stop()
        }
    }

    @Test func theRunStopsAfterFiftyDeliveries() async throws {
        let flow = try pingPong(maxPasses: 50)
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        let writer = try id("Writer", in: flow), reviewer = try id("Reviewer", in: flow)
        var deliveries = started.deliveries
        var last = started
        var turn = 0
        while !last.finished, turn < 200 {
            last = await engine.agentReplied(flow: flow, cardID: turn.isMultiple(of: 2) ? writer : reviewer, text: "turn \(turn)")
            deliveries += last.deliveries
            turn += 1
        }
        // Fifty were handed over and answered. The fifty-first, which would be past the limit, never goes.
        #expect(deliveries.count == 50)
        #expect(deliveries.last?.text.contains("hand-off 50 ") == true)
        #expect(last.deliveries.isEmpty)
        #expect(last.finished && last.ending == .hitLimit)
        #expect(last.log.last?.contains("50") == true)
        #expect(await !engine.isRunning)
        let after = await engine.agentReplied(flow: flow, cardID: reviewer, text: "too late")
        #expect(after == RunOutput())
    }

    @Test func handOffsMadeAlongsideTheOneThatPassesTheLimitAreNotSentEither() async throws {
        // Start → Writer → Reviewer and Editor; Reviewer → Writer. Each of the Writer's replies makes two hand-offs.
        let flow = try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
            for name in ["Writer", "Reviewer", "Editor"] { try $0.addCard(kind: .agent, name: name) }
            try $0.addLink(from: "Start", to: "Writer")
            try $0.addLink(from: "Writer", to: "Reviewer", maxPasses: 50)
            try $0.addLink(from: "Writer", to: "Editor", maxPasses: 50)
            try $0.addLink(from: "Reviewer", to: "Writer", maxPasses: 50)
        }
        let engine = Engine(judge: ScriptedJudge())
        var owed = await engine.start(flow: flow, startCardID: nil, command: nil).deliveries.map(\.toCardID)
        var handed = owed.count
        var last = RunOutput()
        while !owed.isEmpty, !last.finished {
            last = await engine.agentReplied(flow: flow, cardID: owed.removeFirst(), text: "reply")
            handed += last.deliveries.count
            owed += last.deliveries.map(\.toCardID)
        }
        // The Writer's last reply would have made the 50th and the 51st. Neither went.
        #expect(handed == 49)
        #expect(last.finished && last.ending == .hitLimit && last.deliveries.isEmpty)
    }

    @Test func logicCardsInACircleAreCutOff() async throws {
        let flow = try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
            try $0.addCard(kind: .prompt, name: "One", patch: patch { $0.template = "{{message}}" })
            try $0.addCard(kind: .prompt, name: "Two", patch: patch { $0.template = "{{message}}" })
            try $0.addLink(from: "Start", to: "One")
            try $0.addLink(from: "One", to: "Two", maxPasses: 50)
            try $0.addLink(from: "Two", to: "One", maxPasses: 50)
        }
        // The link limits alone would stop this at 101 arrivals, so loosen them to reach the engine's own guard.
        var loose = flow
        for index in loose.links.indices { loose.links[index].maxPasses = 100_000 }
        let engine = Engine(judge: ScriptedJudge())
        let out = await engine.start(flow: loose, startCardID: nil, command: nil)
        #expect(out.deliveries.isEmpty && out.finished)
        #expect(out.log.last?.contains("circle") == true)
        #expect(await !engine.isRunning)
    }

    // MARK: Stopping

    @Test func stopEndsTheRun() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.stop()
        #expect(out.finished && out.runID == started.runID && out.log.count == 1)
        #expect(await !engine.isRunning)
        #expect(await engine.stop() == RunOutput())
        let late = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        #expect(late.deliveries.isEmpty)
    }

    @Test func startWhileRunningChangesNothing() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        let first = await engine.start(flow: flow, startCardID: nil, command: nil)
        let second = await engine.start(flow: flow, startCardID: nil, command: "Something else")
        #expect(second.deliveries.isEmpty && second.log.count == 1 && !second.finished)
        #expect(await engine.runID == first.runID)
        // The first run carries on as if nothing happened.
        let out = await engine.agentReplied(flow: flow, cardID: try id("Writer", in: flow), text: "Old pond")
        #expect(out.deliveries.first?.text.contains("hand-off 2 ") == true)
    }

    @Test func aFailedAgentEndsTheRun() async throws {
        let flow = try chain()
        let engine = Engine(judge: ScriptedJudge())
        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        let out = await engine.agentFailed(flow: flow, cardID: try id("Writer", in: flow), reason: "API error 529")
        #expect(out.finished && out.runID == started.runID)
        #expect(out.log.count == 1)
        #expect(out.log.first?.contains("Writer") == true && out.log.first?.contains("API error 529") == true)
        #expect(await !engine.isRunning)
        #expect(await engine.agentFailed(flow: flow, cardID: try id("Writer", in: flow), reason: "again") == RunOutput())
    }

    // MARK: Racing replies

    @Test func twoRepliesArrivingTogetherAreBothHandledOneAtATime() async throws {
        let flow = try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
            try $0.addCard(kind: .agent, name: "A")
            try $0.addCard(kind: .agent, name: "B")
            try $0.addCard(kind: .ifElse, name: "Good?", patch: patch { $0.check = .judge; $0.value = "It is good" })
            try $0.addCard(kind: .agent, name: "Editor")
            try $0.addLink(from: "Start", to: "A")
            try $0.addLink(from: "Start", to: "B")
            try $0.addLink(from: "A", to: "Good?")
            try $0.addLink(from: "B", to: "Good?")
            try $0.addLink(from: "Good?", port: "yes", to: "Editor")
        }
        let judge = ScriptedJudge(holds: [true, true], delay: .milliseconds(40))
        let engine = Engine(judge: judge)
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        async let first = engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "from A")
        async let second = engine.agentReplied(flow: flow, cardID: try id("B", in: flow), text: "from B")
        let outputs = try await [first, second]

        let deliveries = outputs.flatMap(\.deliveries)
        #expect(deliveries.count == 2)
        #expect(Set(deliveries.map(\.fromName)) == ["A", "B"])
        // Hand-off numbers come from shared run state, so overlapping calls would repeat one.
        #expect(Set(deliveries.map { $0.text.contains("hand-off 3 ") ? 3 : $0.text.contains("hand-off 4 ") ? 4 : 0 }) == [3, 4])
        #expect(await judge.mostInFlight == 1)
        #expect(await judge.statements.count == 2)
    }

    @Test func racingRepliesIntoAnAndFireItOnce() async throws {
        let flow = try fanIn(.and, name: "Both")
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let a = try id("A", in: flow), b = try id("B", in: flow)
        let outputs = await withTaskGroup(of: RunOutput.self) { group in
            group.addTask { await engine.agentReplied(flow: flow, cardID: a, text: "from A") }
            group.addTask { await engine.agentReplied(flow: flow, cardID: b, text: "from B") }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let deliveries = outputs.flatMap(\.deliveries)
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.text.contains("## From A\nfrom A\n\n## From B\nfrom B") == true)
    }

    // MARK: Visits

    @Test func visitsRecordEveryCardAMessageReaches() async {
        var flow = Flow(name: "Visits")
        let start = try! flow.addCard(kind: .start, patch: { var p = CardPatch(); p.command = "Go"; return p }())
        let writer = try! flow.addCard(kind: .agent, name: "Writer")
        var patch = CardPatch(); patch.check = .contains; patch.value = "yes"
        let check = try! flow.addCard(kind: .ifElse, name: "Check", patch: patch)
        let end = try! flow.addCard(kind: .end, name: "Out")
        let toWriter = try! flow.addLink(from: start.id, to: writer.id)
        let toCheck = try! flow.addLink(from: writer.id, to: check.id)
        let toEnd = try! flow.addLink(from: check.id, port: "yes", to: end.id)
        let engine = Engine(judge: SilentJudge())

        let started = await engine.start(flow: flow, startCardID: nil, command: nil)
        #expect(started.visits == [
            CardVisit(cardID: start.id, viaLinkID: nil, port: "out"),
            CardVisit(cardID: writer.id, viaLinkID: toWriter.id, port: nil),
        ])

        let replied = await engine.agentReplied(flow: flow, cardID: writer.id, text: "yes, done")
        #expect(replied.visits == [
            CardVisit(cardID: writer.id, viaLinkID: nil, port: "out"),
            CardVisit(cardID: check.id, viaLinkID: toCheck.id, port: "yes"),
            CardVisit(cardID: end.id, viaLinkID: toEnd.id, port: nil),
        ])
    }

    @Test func aSecondReplyToOneHandOffIsNotPassedOn() async throws {
        var flow = try chain()
        try flow.addCard(kind: .agent, name: "Editor")
        try flow.addLink(from: "Reviewer", to: "Editor")
        let writer = try id("Writer", in: flow), reviewer = try id("Reviewer", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let first = await engine.agentReplied(flow: flow, cardID: writer, text: "A haiku")
        #expect(first.deliveries.map(\.toCardID) == [reviewer])

        // The Writer was handed one message and has answered it. Another turn of its own goes nowhere.
        let second = await engine.agentReplied(flow: flow, cardID: writer, text: "Another haiku")
        #expect(second.deliveries.isEmpty && second.visits.isEmpty && !second.finished)
        #expect(second.log.first?.hasPrefix("Writer finished a turn, but nothing in this run was waiting on it") == true)
    }

    @Test func anAgentHandedTwoMessagesMayAnswerBoth() async throws {
        // Start → A and B, both → C → D.
        let flow = try flow {
            try $0.addCard(kind: .start, name: "Start", patch: patch { $0.command = "Go" })
            for name in ["A", "B", "C", "D"] { try $0.addCard(kind: .agent, name: name) }
            try $0.addLink(from: "Start", to: "A")
            try $0.addLink(from: "Start", to: "B")
            try $0.addLink(from: "A", to: "C")
            try $0.addLink(from: "B", to: "C")
            try $0.addLink(from: "C", to: "D")
        }
        let c = try id("C", in: flow), d = try id("D", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: try id("A", in: flow), text: "from A")
        _ = await engine.agentReplied(flow: flow, cardID: try id("B", in: flow), text: "from B")

        let one = await engine.agentReplied(flow: flow, cardID: c, text: "about A")
        let two = await engine.agentReplied(flow: flow, cardID: c, text: "about B")
        #expect(one.deliveries.map(\.toCardID) == [d] && two.deliveries.map(\.toCardID) == [d])
        // Both hand-offs are answered now, so a third turn is one nobody asked for.
        let three = await engine.agentReplied(flow: flow, cardID: c, text: "one more thing")
        #expect(three.deliveries.isEmpty)
    }

    @Test func anAgentThatAskedAQuestionStillOwesItsReply() async throws {
        let flow = try chain()
        let writer = try id("Writer", in: flow)
        let engine = Engine(judge: ScriptedJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        _ = await engine.agentReplied(flow: flow, cardID: writer, text: "Which season?", waitingOnAnswer: true)
        let reply = await engine.agentReplied(flow: flow, cardID: writer, text: "A haiku")
        #expect(reply.deliveries.map(\.toCardID) == [try id("Reviewer", in: flow)])
    }

    @Test func aReplyThatPassesNothingOnLeavesNoVisit() async {
        var flow = Flow(name: "Quiet")
        let start = try! flow.addCard(kind: .start, patch: { var p = CardPatch(); p.command = "Go"; return p }())
        let writer = try! flow.addCard(kind: .agent, name: "Writer")
        try! flow.addLink(from: start.id, to: writer.id)
        let engine = Engine(judge: SilentJudge())
        _ = await engine.start(flow: flow, startCardID: nil, command: nil)
        let replied = await engine.agentReplied(flow: flow, cardID: writer.id, text: "[no reply]")
        #expect(replied.visits.isEmpty)
    }
}

/// A judge for flows whose checks are all text checks: it is never asked anything.
private struct SilentJudge: Judge {
    func holds(statement: String, message: String) async -> Bool? { nil }
    func pick(branches: [String], message: String) async -> String? { nil }
}
