import Foundation

/// Answers the plain-English questions an If, Loop or Switch card asks about a message.
public protocol Judge: Sendable {
    /// Whether `statement` is true of `message`, or nil if it could not be judged.
    func holds(statement: String, message: String) async -> Bool?
    /// One of `branches`, or nil.
    func pick(branches: [String], message: String) async -> String?
}

/// A message for the app to send to an agent's session.
public struct Delivery: Equatable, Sendable {
    public let toCardID: String
    public let text: String
    public let fromName: String

    public init(toCardID: String, text: String, fromName: String) {
        self.toCardID = toCardID; self.text = text; self.fromName = fromName
    }
}

/// A final answer that reached an End card.
public struct EndResult: Equatable, Sendable {
    public let cardID: String
    public let cardName: String
    public let text: String
    public let saveTo: String?

    public init(cardID: String, cardName: String, text: String, saveTo: String?) {
        self.cardID = cardID; self.cardName = cardName; self.text = text; self.saveTo = saveTo
    }
}

/// One card a message reached while an event was handled, for showing where a run has been.
public struct CardVisit: Equatable, Sendable {
    public let cardID: String
    /// The link the message came in by. Nil for a Start card and for an agent's own reply.
    public let viaLinkID: String?
    /// The output it left by. Nil when it stopped here: handed to an agent, taken by an End,
    /// held by an And that is still waiting, or dropped by an Or.
    public let port: String?

    public init(cardID: String, viaLinkID: String?, port: String?) {
        self.cardID = cardID; self.viaLinkID = viaLinkID; self.port = port
    }
}

/// A message that went along a link, for showing what each link carried.
public struct Travel: Equatable, Sendable {
    public let linkID: String
    public let text: String
    public let fromName: String

    public init(linkID: String, text: String, fromName: String) {
        self.linkID = linkID; self.text = text; self.fromName = fromName
    }
}

/// A message stopped at a card that can't answer straight away: an Approval waiting for the
/// person, or a Script waiting for its command to finish. The app answers with `holdResolved`.
public struct Hold: Equatable, Sendable {
    public let id: String
    public let cardID: String
    public let kind: CardKind
    /// The message that is waiting.
    public let text: String
    public let fromName: String

    public init(id: String, cardID: String, kind: CardKind, text: String, fromName: String) {
        self.id = id; self.cardID = cardID; self.kind = kind; self.text = text; self.fromName = fromName
    }

    /// What leaves an Approval by Rejected when the person said why: their note, then the
    /// message they turned down. Nil when the note is blank, and the message goes on as it was.
    public static func rejection(note: String, of message: String) -> String? {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        return "\(note)\n\n--- The message that was rejected ---\n\(message)"
    }
}

/// Everything one event caused.
public struct RunOutput: Equatable, Sendable {
    public var deliveries: [Delivery]
    public var log: [String]
    public var results: [EndResult]
    /// Every card a message reached, in order.
    public var visits: [CardVisit]
    /// Messages now waiting at an Approval or a Script card.
    public var holds: [Hold]
    /// Each message that went along a link, in order.
    public var travels: [Travel] = []
    /// True when this call ended the run.
    public var finished: Bool
    /// The run this call belonged to, nil if there was none.
    public var runID: String?
    /// Agents the run has just come to hang on: each asked a question, has had no answer, and
    /// nothing else is under way. Empty unless this call is what left the run that way.
    public var stalledOn: [String] = []
    /// Every agent the run is owed a reply from whose last turn ended on a question of its own.
    /// Nil when this call didn't look, so what was known before still stands.
    public var asking: [String]?
    /// Whether the run hangs on those agents alone. Only meaningful alongside `asking`.
    public var isStalled = false
    /// How the run ended. Set only when `finished` is.
    public var ending: RunEnding?
    /// Agents the run was still waiting on when it ended. They may be in the middle of a turn that
    /// nothing will use now, so the app interrupts them.
    public var leftWaiting: [String] = []

    public init(deliveries: [Delivery] = [], log: [String] = [], results: [EndResult] = [],
                visits: [CardVisit] = [], holds: [Hold] = [], finished: Bool = false, runID: String? = nil,
                ending: RunEnding? = nil) {
        self.deliveries = deliveries; self.log = log; self.results = results
        self.visits = visits; self.holds = holds; self.finished = finished; self.runID = runID; self.ending = ending
    }
}

/// What came of asking the judge.
private enum Judged<T: Sendable>: Sendable {
    /// Its answer, nil when it couldn't give one.
    case answer(T?)
    /// It took longer than the engine waits.
    case timedOut
    /// The run was stopped while it was thinking.
    case stopped
}

/// The first of several racing answers, for whoever waits on it. Later answers are dropped.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var given: T?
    private var isGiven = false
    private var waiter: CheckedContinuation<T, Never>?

    func give(_ answer: T) {
        lock.lock()
        guard !isGiven else { return lock.unlock() }
        isGiven = true
        given = answer
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: answer)
    }

    var answer: T {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isGiven, let given {
                    lock.unlock()
                    continuation.resume(returning: given)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }
}

/// Runs a flow: takes events (a run started, an agent replied) and answers with what to deliver, record and log.
/// It starts no processes and reads no terminals. One run at a time.
public actor Engine {
    /// The most messages one run hands to agents. A run that would hand over one more stops instead.
    public static let maxDeliveries = 50
    /// How long an If, Loop or Switch card's question is given before it counts as unanswered.
    public static let judgeTimeout: Duration = .seconds(60)
    /// Only an agent's turn ends an event, so logic cards wired in a circle would otherwise pass one message
    /// round for as long as their links allow.
    static let maxArrivalsPerEvent = 200
    static let defaultMaxTries = 3
    /// The most items a For each card sends on in one go, and how many it sends unless set.
    public static let mostItems = 50
    static let defaultItems = 20

    private struct Message {
        var text: String
        /// The agent whose reply this is. It survives logic cards so the receiver knows who it is hearing from.
        var fromName: String
        var fromStart: Bool
    }

    /// The items a For each card is going through, one at a time.
    private struct Round {
        var items: [String]
        /// The item out now, counting from 0.
        var current = 0
        /// What came back for each item so far, in order.
        var results: [(from: String, text: String)] = []
    }

    private struct Run {
        let id: String
        /// Agents handed a message and not heard from since.
        var pending: Set<String> = []
        /// How many hand-offs each agent has had and not answered. `pending` ends the run and holds
        /// one entry however many there are; this is what says a reply was asked for.
        var owed: [String: Int] = [:]
        /// Agents whose last turn ended on a question of their own, not on their reply.
        var asking: Set<String> = []
        /// Whether the app has been told the run hangs on those agents.
        var saidStalled = false
        var passes: [String: Int] = [:]
        var deliveries = 0
        /// And card id, then source card id, to the message waiting there.
        var waiting: [String: [String: Message]] = [:]
        var fired: Set<String> = []
        var tries: [String: Int] = [:]
        /// Messages waiting at Approval and Script cards, by hold id.
        var held: [String: (cardID: String, message: Message)] = [:]
        var hitLimit = false
        /// A message reached an End card.
        var answered = false
        /// A Loop card ran out of tries.
        var gaveUp = false
        /// For each card id to the items it is going through.
        var rounds: [String: Round] = [:]
    }

    private let judge: any Judge
    private let judgeTimeout: Duration
    private var run: Run?
    /// The run that is starting or going. Set as soon as a run begins to start, so Stop can end a run whose
    /// first event is still being worked out, and cleared the moment it ends. An event that finds it changed
    /// when it is done belongs to a run that is over, and what it decided is dropped.
    private var live: String?
    /// Gives up on the judge call under way, if there is one.
    private var abandonJudging: (@Sendable () -> Void)?

    // Judge calls suspend, and an actor lets other calls in while one is suspended. Each event has to see the
    // run as the one before left it, so calls take turns in the order they arrived. Stop doesn't wait its turn.
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    public init(judge: any Judge, judgeTimeout: Duration = Engine.judgeTimeout) {
        self.judge = judge
        self.judgeTimeout = judgeTimeout
    }

    public var isRunning: Bool { live != nil }
    public var runID: String? { live }

    /// The run a hand-off's text says it belongs to, or nil for text that isn't a hand-off.
    public static func runID(inHandOff text: String) -> String? {
        let prefix = "[Queen Bee · run "
        guard let start = text.range(of: prefix) else { return nil }
        let id = text[start.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return id.isEmpty ? nil : String(id)
    }

    // MARK: Events

    public func start(flow: Flow, startCardID: String?, command: String?) async -> RunOutput {
        await takeTurn()
        defer { endTurn() }

        if let live {
            return RunOutput(log: ["A run is already going. Stop it before starting another."], runID: live)
        }
        let given = startCardID.flatMap { flow.card($0) }.flatMap { $0.kind == .start ? $0 : nil }
        guard let card = given ?? flow.cards.first(where: { $0.kind == .start }) else {
            return RunOutput(log: ["Nothing to run: this flow has no Start card"], finished: true)
        }
        let typed = command ?? ""
        let text = Self.isBlank(typed) ? card.command ?? "" : typed
        guard !Self.isBlank(text) else {
            return RunOutput(log: ["Nothing to run: the Start card has no command"], finished: true)
        }

        var state = Run(id: Flow.newID())
        live = state.id
        var output = RunOutput(runID: state.id)
        output.visits.append(CardVisit(cardID: card.id, viaLinkID: nil, port: "out"))
        await send(Message(text: text, fromName: "Start", fromStart: true), from: card, in: flow, state: &state, output: &output)
        settle(state, in: flow, &output)
        return output
    }

    /// Starts a run part-way through a flow: `message` arrives at `cardID` as if a link had
    /// brought it. For trying one stretch of a flow again without running what comes before it.
    public func start(flow: Flow, at cardID: String, message text: String, fromName: String) async -> RunOutput {
        await takeTurn()
        defer { endTurn() }

        if let live {
            return RunOutput(log: ["A run is already going. Stop it before starting another."], runID: live)
        }
        guard let card = flow.card(cardID), acceptsInput(card) else {
            return RunOutput(log: ["Nothing to run: that card takes no input"], finished: true)
        }
        guard !Self.isBlank(text) else {
            return RunOutput(log: ["Nothing to run: there is no message to give \(card.name)"], finished: true)
        }
        var state = Run(id: Flow.newID())
        live = state.id
        var output = RunOutput(runID: state.id)
        output.log.append("Run started at \(card.name)")
        // No link brought this message, so it has none to count against.
        let entry = Link(id: "", from: "", to: card.id)
        let message = Message(text: text, fromName: fromName, fromStart: false)
        // An And waits for every card linked into it, which a message given by hand can never
        // satisfy. Started here, it passes the message straight on.
        let next: (port: String, message: Message)? = card.kind == .and
            ? ("out", Message(text: text, fromName: card.name, fromStart: false))
            : await arrive(message, at: card, by: entry, in: flow, state: &state, output: &output)
        output.visits.append(CardVisit(cardID: card.id, viaLinkID: nil, port: next?.port))
        if let next, !state.hitLimit {
            await send(next.message, from: card, port: next.port, in: flow, state: &state, output: &output)
        }
        settle(state, in: flow, &output)
        return output
    }

    /// An agent's turn ended. Its reply goes on along its card's links.
    /// `waitingOnAnswer` is for a turn in which the agent asked someone a question: the answer
    /// can only reach it as a new turn, so what it said on the way out is not its reply. Nothing
    /// is passed on and the card stays owed, until the turn after the answer.
    /// `forRun` is the run the hand-off that began the turn belonged to, when the app knows it. A turn
    /// working on a run that has ended is not this run's reply, even from an agent this run is owed one by.
    public func agentReplied(flow: Flow, cardID: String, text: String, waitingOnAnswer: Bool = false,
                             forRun: String? = nil) async -> RunOutput {
        await takeTurn()
        defer { endTurn() }

        guard var state = run else { return RunOutput() }
        var output = RunOutput(runID: state.id)
        if let forRun, forRun != state.id {
            output.log.append("\(flow.card(cardID)?.name ?? "An agent") finished work for a run that has ended, so its reply was not passed on")
            settle(state, in: flow, &output)
            return output
        }
        if waitingOnAnswer {
            if state.pending.contains(cardID), state.asking.insert(cardID).inserted {
                output.log.append("\(flow.card(cardID)?.name ?? "An agent") asked a question and is waiting for the answer")
            }
            settle(state, in: flow, &output)
            return output
        }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a reply to a hand-off of this run goes on. An agent's turn can end for other reasons:
        // the person typed to it, or it is finishing work from a run that was stopped. Passing that
        // on would carry the run past cards it hasn't reached, an unanswered Approval among them.
        guard let owed = state.owed[cardID], owed > 0 else {
            if !reply.isEmpty, let card = flow.card(cardID) {
                output.log.append("\(card.name) finished a turn, but nothing in this run was waiting on it, so its reply was not passed on")
            }
            settle(state, in: flow, &output)
            return output
        }
        state.owed[cardID] = owed - 1
        state.asking.remove(cardID)
        state.pending.remove(cardID)
        if let card = flow.card(cardID) {
            if reply.isEmpty || reply.caseInsensitiveCompare("[no reply]") == .orderedSame {
                output.log.append("\(card.name) had nothing to pass on")
            } else {
                output.visits.append(CardVisit(cardID: card.id, viaLinkID: nil, port: "out"))
                await send(Message(text: text, fromName: card.name, fromStart: false), from: card, in: flow, state: &state, output: &output)
            }
        } else {
            output.log.append("A reply came from a card that is no longer in the flow")
        }
        settle(state, in: flow, &output)
        return output
    }

    /// The person answered an Approval, or a Script's command finished. `port` is the output the
    /// message leaves by. `text` replaces the message: the person's edit, or what the script printed.
    public func holdResolved(flow: Flow, holdID: String, port: String, text: String?) async -> RunOutput {
        await takeTurn()
        defer { endTurn() }

        guard var state = run else { return RunOutput() }
        var output = RunOutput(runID: state.id)
        guard let held = state.held.removeValue(forKey: holdID) else { return output }
        state.pending.remove(Self.holdKey(holdID))
        if let card = flow.card(held.cardID) {
            var message = held.message
            if let text, !Self.isBlank(text) { message.text = text }
            if card.kind != .approval { message.fromName = card.name; message.fromStart = false }
            output.log.append("\(Self.title(card)) → \(portLabel(port))")
            output.visits.append(CardVisit(cardID: card.id, viaLinkID: nil, port: port))
            await send(message, from: card, port: port, in: flow, state: &state, output: &output)
        } else {
            output.log.append("A card that was holding a message is no longer in the flow")
        }
        settle(state, in: flow, &output)
        return output
    }

    private static func holdKey(_ id: String) -> String { "hold:" + id }

    /// An agent's session ended or its turn failed. That stops the run only when the run is waiting on the
    /// agent: any other agent, one the run hasn't reached or has already heard from, can come and go.
    /// `name` is the card's name for one that has just been taken out of `flow`.
    public func agentFailed(flow: Flow, cardID: String, name: String? = nil, reason: String) async -> RunOutput {
        await takeTurn()
        defer { endTurn() }

        guard let state = run else { return RunOutput() }
        guard state.pending.contains(cardID) || state.owed[cardID, default: 0] > 0 else { return RunOutput(runID: state.id) }
        let name = flow.card(cardID)?.name ?? name ?? "An agent"
        let why = Self.isBlank(reason) ? "" : ": \(reason.trimmingCharacters(in: .whitespacesAndNewlines))"
        var output = RunOutput(log: ["Run stopped because \(name) failed\(why)"], finished: true, runID: state.id, ending: .failed)
        output.leftWaiting = Self.agents(in: state.pending).filter { $0 != cardID }
        end()
        return output
    }

    /// Ends the run straight away, without waiting for an event that is being worked out. Such an event is
    /// still going, most likely waiting on the judge: it is told to give up, and what it decides is dropped.
    /// `ending` and `line` say why, for a run the app stops itself, as it does one that has spent its limit.
    public func stop(ending: RunEnding = .stopped, line: String = "Run stopped") async -> RunOutput {
        guard let id = live else { return RunOutput() }
        var output = RunOutput(log: [line], finished: true, runID: id, ending: ending)
        // Nil while the run's first event is still being worked out: nothing has been handed to anyone yet.
        if let run, run.id == id { output.leftWaiting = Self.agents(in: run.pending) }
        end()
        abandonJudging?()
        abandonJudging = nil
        return output
    }

    private func end() {
        run = nil
        live = nil
    }

    /// The agents among what a run is waiting on: everything but the messages held at cards.
    private static func agents(in pending: Set<String>) -> [String] {
        pending.filter { !$0.hasPrefix(holdKey("")) }.sorted()
    }

    // MARK: Taking turns

    private func takeTurn() async {
        if busy {
            await withCheckedContinuation { queue.append($0) }
        } else {
            busy = true
        }
    }

    /// Hands the turn straight to the next caller, so `busy` stays true and nobody can slip in between.
    private func endTurn() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }

    // MARK: Routing

    /// The run ends when nobody is left to hear from.
    private func settle(_ state: Run, in flow: Flow, _ output: inout RunOutput) {
        // Stopped while this event was being worked out. The run is over, and nothing it decided happens.
        guard live == state.id else {
            output = RunOutput()
            return
        }
        if state.hitLimit || state.pending.isEmpty {
            end()
            output.finished = true
            output.asking = []
            output.leftWaiting = Self.agents(in: state.pending)
            output.ending = state.hitLimit ? .hitLimit : state.gaveUp ? .gaveUp : state.answered ? .finishedWithAnswer : .endedWithoutAnswer
            // An And that never heard from every card linked into it is why a run ends with nothing to show.
            for (andID, have) in state.waiting.sorted(by: { $0.key < $1.key }) where !have.isEmpty {
                guard let card = flow.card(andID) else { continue }
                let missing = Set(flow.links(into: andID).map(\.from)).subtracting(have.keys)
                let names = flow.cards.filter { missing.contains($0.id) }.map(\.name).joined(separator: ", ")
                output.log.append("\(Self.title(card)) was still waiting for \(names.isEmpty ? "a message" : names) when the run ended")
            }
            // So is a For each whose item never found its way back.
            for (id, round) in state.rounds.sorted(by: { $0.key < $1.key }) {
                guard let card = flow.card(id) else { continue }
                output.log.append("\(Self.title(card)) was still waiting for what came back for item \(round.current + 1) of \(round.items.count) when the run ended")
            }
        } else {
            var state = state
            // A held message is owed too, under its own key, so a run with one is not stalled.
            let stalled = state.pending.isSubset(of: state.asking)
            if stalled, !state.saidStalled { output.stalledOn = state.pending.sorted() }
            output.asking = state.asking.sorted()
            output.isStalled = stalled
            state.saidStalled = stalled
            run = state
        }
    }

    /// Carries a message out of `card` and on through logic cards until every copy has reached an agent or an
    /// End, or been dropped.
    private func send(_ message: Message, from card: Card, port: String = "out", in flow: Flow,
                      state: inout Run, output: inout RunOutput) async {
        var travelling = leaving(card, port: port, message, in: flow, output: &output)
        var arrivals = 0
        while !travelling.isEmpty {
            // Stopped meanwhile: nothing more is judged for a run that is over.
            guard live == state.id else { return }
            let (link, message) = travelling.removeFirst()
            guard let target = flow.card(link.to) else { continue }

            let passes = state.passes[link.id, default: 0]
            if passes >= link.maxPasses {
                let source = flow.card(link.from)?.name ?? "?"
                output.log.append("Link \(source) → \(target.name) stopped: it reached its limit of \(link.maxPasses) for this run")
                continue
            }
            state.passes[link.id] = passes + 1
            output.travels.append(Travel(linkID: link.id, text: message.text, fromName: message.fromName))

            arrivals += 1
            if arrivals > Self.maxArrivalsPerEvent {
                output.log.append("Stopped passing a message on: logic cards are linked in a circle with no agent between them")
                return
            }

            let next = await arrive(message, at: target, by: link, in: flow, state: &state, output: &output)
            output.visits.append(CardVisit(cardID: target.id, viaLinkID: link.id, port: next?.port))
            if state.hitLimit { return }
            if let next {
                travelling += leaving(target, port: next.port, next.message, in: flow, output: &output)
            }
        }
    }

    private func leaving(_ card: Card, port: String, _ message: Message, in flow: Flow,
                         output: inout RunOutput) -> [(Link, Message)] {
        let links = flow.links(from: card.id, port: port)
        if links.isEmpty {
            // Say where a message ended, or a run that stops here looks like it stalled.
            switch card.kind {
            case .agent: output.log.append("\(card.name) replied. Nothing is linked from it.")
            case .start: output.log.append("Nothing is linked from the Start card")
            default: output.log.append("\(Self.title(card)) has nothing linked on \(portLabel(port))")
            }
        }
        return links.map { ($0, message) }
    }

    /// What a card does with a message. Returns the port the message leaves by, or nil if it stops here.
    private func arrive(_ message: Message, at card: Card, by link: Link, in flow: Flow,
                        state: inout Run, output: inout RunOutput) async -> (port: String, message: Message)? {
        let title = Self.title(card)
        switch card.kind {
        case .agent:
            if state.deliveries >= Self.maxDeliveries {
                // The run ends here, so the hand-offs this event has already made would be work nobody uses.
                output.deliveries.removeAll()
                output.log.append("Run stopped: agents had been handed \(Self.maxDeliveries) messages, which is the most one run allows. Nothing more was sent.")
                state.hitLimit = true
                return nil
            }
            state.deliveries += 1
            let tag = message.fromStart
                ? "[Queen Bee · run \(state.id) · start]"
                : "[Queen Bee · run \(state.id) · hand-off \(state.deliveries) · from \(message.fromName)]"
            output.deliveries.append(Delivery(toCardID: card.id, text: tag + "\n" + message.text, fromName: message.fromName))
            output.log.append("\(message.fromName) → \(card.name)")
            state.pending.insert(card.id)
            state.owed[card.id, default: 0] += 1
            return nil

        case .ifElse:
            let judged = await check(card, message)
            if case .timedOut = judged { output.log.append("\(title) took too long to judge, so it counts as No") }
            if case .answer(nil) = judged { output.log.append("\(title) could not be judged, so it counts as No") }
            let port = if case .answer(true) = judged { "yes" } else { "no" }
            output.log.append("\(title) → \(portLabel(port))")
            return (port, message)

        case .switchCard:
            let branches = card.branches ?? []
            var picked: String?
            if !branches.isEmpty {
                let judge = judge
                let message = message.text
                switch await ask({ await judge.pick(branches: branches, message: message) }) {
                case .answer(let answer): picked = answer
                case .timedOut: output.log.append("\(title) took too long to judge, so it counts as Other")
                case .stopped: break
                }
            }
            let branch = picked.flatMap { Checks.parseBranch($0, branches: branches) }
            output.log.append("\(title) → \(branch ?? "Other")")
            return (branch ?? "other", message)

        case .and:
            state.waiting[card.id, default: [:]][link.from] = message
            let have = state.waiting[card.id] ?? [:]
            var sources: [String] = []
            for source in flow.links(into: card.id).map(\.from) where !sources.contains(source) { sources.append(source) }
            let missing = sources.filter { have[$0] == nil }
            if !missing.isEmpty {
                let names = missing.map { flow.card($0)?.name ?? "?" }.joined(separator: ", ")
                output.log.append("\(title) is waiting for \(names)")
                return nil
            }
            state.waiting[card.id] = nil
            let parts = sources.compactMap { have[$0] }
            output.log.append("\(title) → passed on \(parts.count) messages together")
            let text = Checks.combine(parts.map { (from: $0.fromName, text: $0.text) })
            return ("out", Message(text: text, fromName: card.name, fromStart: false))

        case .or:
            // Once per run, or once per round of a loop it sits in: see `orCards(after:)`.
            if !state.fired.insert(card.id).inserted {
                output.log.append("\(title) dropped a later reply from \(message.fromName)")
                return nil
            }
            output.log.append("\(title) → passed on the reply from \(message.fromName)")
            return ("out", message)

        case .prompt:
            var rewritten = message
            rewritten.text = Checks.fillTemplate(card.template ?? "", message: message.text, from: message.fromName)
            return ("out", rewritten)

        case .loop:
            let tries = state.tries[card.id, default: 0] + 1
            let limit = max(card.maxTries ?? Self.defaultMaxTries, 1)
            let judged = await check(card, message)
            if case .timedOut = judged { output.log.append("\(title) took too long to judge, so it counts as a failed try") }
            if case .answer(nil) = judged { output.log.append("\(title) could not be judged, so it counts as a failed try") }
            if case .answer(true) = judged {
                output.log.append("\(title) → Done")
            } else if tries >= limit {
                state.tries[card.id] = nil
                // A flow that says what to do when the tries run out has dealt with it, and the run goes on as usual.
                if !flow.links(from: card.id, port: "gave-up").isEmpty {
                    output.log.append("\(title) → Gave up after \(tries) tries")
                    return ("gave-up", message)
                }
                output.log.append("\(title) → Done after \(tries) tries")
                state.gaveUp = true
            } else {
                state.tries[card.id] = tries
                // A new round: each Or it leads back to passes on the first reply of this round, as it did the last.
                state.fired.subtract(orCards(after: card, port: "again", in: flow))
                output.log.append("\(title) → Again (try \(tries) of \(limit))")
                return ("again", message)
            }
            // Leaving by Done finishes this round of the loop, so coming back later starts counting afresh.
            state.tries[card.id] = nil
            return ("done", message)

        case .end:
            let saveTo = card.saveTo.flatMap { Self.isBlank($0) ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            output.results.append(EndResult(cardID: card.id, cardName: card.name, text: message.text, saveTo: saveTo))
            output.log.append("\(title) got the final answer from \(message.fromName)")
            state.answered = true
            return nil

        case .approval, .script, .flow:
            if card.kind == .flow, Self.isBlank(card.flowRef ?? "") {
                output.log.append("\(title) has no flow chosen, so it counts as Fail")
                return ("fail", message)
            }
            if card.kind == .script, Self.isBlank(card.command ?? "") {
                output.log.append("\(title) has no command, so it counts as Fail")
                return ("fail", message)
            }
            let hold = Hold(id: Flow.newID(), cardID: card.id, kind: card.kind, text: message.text, fromName: message.fromName)
            state.held[hold.id] = (card.id, message)
            state.pending.insert(Self.holdKey(hold.id))
            output.holds.append(hold)
            output.log.append(card.kind == .approval ? "\(title) is waiting for you"
                              : card.kind == .script ? "\(title) is running its command" : "\(title) is running its flow")
            return nil

        case .forEach:
            return forEach(card, message, by: link, in: flow, state: &state, output: &output)

        case .note, .start:
            output.log.append("Dropped a message linked into \(title), which takes no input")
            return nil
        }
    }

    /// A For each card. A message that comes back to it along its body is what came back for the item that is out,
    /// and the next item goes; any other message is a new list to go through. Each item is a fresh pass through
    /// the body: its links count their passes again and its Or cards pass on a first message again.
    private func forEach(_ card: Card, _ message: Message, by link: Link, in flow: Flow,
                         state: inout Run, output: inout RunOutput) -> (port: String, message: Message)? {
        let title = Self.title(card)
        let body = body(of: card, in: flow)
        func goOn(_ round: Round) -> (port: String, message: Message) {
            state.rounds[card.id] = round
            for id in body.links { state.passes[id] = nil }
            state.fired.subtract(body.cards)
            output.log.append("\(title) → Each (item \(round.current + 1) of \(round.items.count))")
            return ("each", Message(text: round.items[round.current], fromName: card.name, fromStart: false))
        }

        if var round = state.rounds[card.id] {
            guard body.links.contains(link.id) else {
                output.log.append("\(title) is still going through its items, so it dropped a message from \(message.fromName)")
                return nil
            }
            let item = round.items[round.current]
            let short = item.count > 60 ? String(item.prefix(60)) + "…" : item
            round.results.append((from: "item \(round.current + 1): \(short)", text: message.text))
            round.current += 1
            if round.current < round.items.count { return goOn(round) }
            state.rounds[card.id] = nil
            output.log.append("\(title) → Done, with what came back for \(round.items.count == 1 ? "its item" : "all \(round.items.count) items")")
            return ("done", Message(text: Checks.combine(round.results), fromName: card.name, fromStart: false))
        }

        let all = Checks.items(in: message.text, split: card.split ?? .auto)
        guard !all.isEmpty else {
            output.log.append("\(title) found no items in the message from \(message.fromName), so it went straight to Done")
            return ("done", message)
        }
        let most = min(max(card.maxItems ?? Self.defaultItems, 1), Self.mostItems)
        if all.count > most { output.log.append("\(title) found \(all.count) items and sends on the first \(most), its most") }
        return goOn(Round(items: Array(all.prefix(most))))
    }

    /// The links a For each card's items travel, from its Each output until they come back into it, and the cards
    /// on the way. A link back into the card from one of those cards is how an item's result comes back.
    private func body(of card: Card, in flow: Flow) -> (links: Set<String>, cards: Set<String>) {
        var links: Set<String> = [], cards: Set<String> = []
        var next = flow.links(from: card.id, port: "each")
        while let link = next.popLast() {
            guard links.insert(link.id).inserted, link.to != card.id else { continue }
            if cards.insert(link.to).inserted { next += flow.links(from: link.to) }
        }
        return (links, cards)
    }

    /// An If or Loop card's check. An answer of nil when a judge check has no statement or the judge could not answer.
    private func check(_ card: Card, _ message: Message) async -> Judged<Bool> {
        let value = card.value ?? ""
        if let answer = Checks.textCheck(card.check ?? .judge, value: value, message: message.text) { return .answer(answer) }
        if Self.isBlank(value) { return .answer(nil) }
        let judge = judge
        let statement = value.trimmingCharacters(in: .whitespacesAndNewlines), text = message.text
        return await ask { await judge.holds(statement: statement, message: text) }
    }

    /// Asks the judge, for no longer than the timeout and no longer than the run lasts. A call that is given
    /// up on is cancelled, which stops the process behind it.
    private func ask<T: Sendable>(_ question: @escaping @Sendable () async -> T?) async -> Judged<T> {
        let first = FirstAnswer<Judged<T>>()
        let work = Task { first.give(.answer(await question())) }
        let timeout = judgeTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            first.give(.timedOut)
        }
        abandonJudging = { first.give(.stopped) }
        let answer = await first.answer
        abandonJudging = nil
        work.cancel()
        timer.cancel()
        return answer
    }

    /// The Or cards a message leaving `card` by `port` can reach, however far on.
    private func orCards(after card: Card, port: String, in flow: Flow) -> Set<String> {
        var seen: Set<String> = []
        var found: Set<String> = []
        var next = flow.links(from: card.id, port: port).map(\.to)
        while let id = next.popLast() {
            guard seen.insert(id).inserted, let reached = flow.card(id) else { continue }
            if reached.kind == .or { found.insert(id) }
            next += flow.links(from: id).map(\.to)
        }
        return found
    }

    /// How a logic card is named in the log, for example `If "Approved?"`.
    private static func title(_ card: Card) -> String {
        let kind: String = switch card.kind {
        case .ifElse: "If"
        case .loop: "Loop"
        default: card.kind.label
        }
        return "\(kind) \"\(card.name)\""
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
