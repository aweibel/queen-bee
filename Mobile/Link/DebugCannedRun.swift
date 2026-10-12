#if DEBUG
import Foundation
import QueenBeeCore

/// A made-up Mac with a made-up run, for checking the panels without one. Launched with `-qbCannedRun <n>`,
/// the app looks for no Mac: it is handed the first n stages below, as the messages a Mac would send, through
/// the same door real ones come in by. `scripts/e2e.py panels` reads back what the panels then show.
/// Everything here is invented: the flow, the names, the messages and the figures. None of it is in a
/// release build.
///
///   1  a flow arrives part-way through its third run: an agent and a script are both waiting on the person
///   2  the run moves on, and stops at an approval
///   3  the run ends, and the Mac files it with the two before it
///   4  a fourth run begins
///   5  that run is stopped on the Mac, and the agent's session has ended
///   6  the flow's sessions are closed on the Mac, so none has been started
///
/// With `-qbControl 1` the made-up Mac lets the device control it, and answers each command roughly as a
/// real one would: it changes the run, or refuses in the real Mac's words. With `-qbSilent 1` it never answers.
/// What is typed for a session that is running shows up in that session's terminal, as it would once the
/// program echoed it. With `-qbStale 1` the sessions have ended without the device being told, so typing is refused.
/// It makes the edits it is asked for too, to its own copy of the flow, and sends the flow back: see `MadeUpEdits`.
enum DebugCannedRun {
    static var isWanted: Bool { wanted > 0 }
    private static var wanted: Int { UserDefaults.standard.integer(forKey: "qbCannedRun") }
    /// The last stage played, for the test to wait on.
    private(set) static var stage = 0
    /// True once every stage that was asked for has played.
    private(set) static var isPlayed = false
    /// The run as the made-up Mac has it now, for it to answer commands from.
    private static var current: RemoteRunState?
    /// The flow as the made-up Mac has it now, with its Undo and Redo.
    private static var edits: MadeUpEdits?
    /// What the device was last sent of those, so it is only sent what has changed.
    private static var told: (flow: Flow, edit: RemoteEditState, revision: Int)?
    /// The size each made-up terminal was started at, by session, so more can be printed in it.
    private static let screens = [writer: (cols: 58, rows: 16), orchestrator: (cols: 40, rows: 30)]

    static let flowID = "canned10"
    private static let start = "start001", writer = "writer01", style = "style001", both = "both0001"
    private static let short = "short001", sign = "sign0001", sent = "sent0001", dropped = "drop0001"
    private static let orchestrator = TerminalRegistry.orchestratorKey

    private static let command = "Write a welcome note for new members of the book club."
    private static let guide = "Keep it warm and plain. No exclamation marks. Under 100 words."
    private static let note = """
        Welcome to the book club.

        We meet on the first Thursday of each month, in the back room of the library, at seven. This month we are reading a short novel about a lighthouse keeper, and you are welcome whether or not you have finished it.

        Bring a mug if you have one. Tea and biscuits are on us. If you would like to suggest a book for next month, write its name on the list by the door, and we will vote before we leave.

        We are glad you are here.
        """

    static func play(_ client: RemoteClient) async {
        func card(_ id: String, _ kind: CardKind, _ name: String, _ x: Double, _ y: Double, _ width: Double = 240, _ height: Double = 120,
                  _ set: (inout Card) -> Void = { _ in }) -> Card {
            var card = Card(id: id, kind: kind, name: name, x: x, y: y, width: width, height: height)
            set(&card)
            return card
        }
        var flow = Flow(id: flowID, name: "Welcome note", cards: [
            card(start, .start, "Start", 40, 240) {
                $0.command = command
                $0.trigger = Trigger(kind: .weekly, hour: 9, minute: 0, weekdays: [2, 4])
            },
            card(writer, .agent, "Writer", 340, 40, 480, 300) {
                $0.instructions = "You write short notes for a neighbourhood book club. Keep to what you are asked for, and follow the style guide you are given. "
                    + "Write in plain, friendly English. Never promise anything on the club's behalf: no prizes, no free books, no changes to when it meets. "
                    + "If the request is unclear, write the best note you can and say in one line at the end what you assumed."
                $0.model = "opus"
                $0.effort = "high"
                $0.permissionMode = "acceptEdits"
                $0.cwd = "notes"
            },
            card(style, .script, "Style guide", 460, 400, 240, 120) { $0.command = "cat docs/style.md" },
            card(both, .and, "Both ready", 900, 240),
            card(short, .ifElse, "Short enough?", 1200, 240, 240, 140) {
                $0.check = .judge
                $0.value = "The note is under 100 words and friendly"
            },
            card(sign, .approval, "Sign off", 1500, 240, 240, 120) { $0.text = "Is this note right to send?" },
            card(sent, .end, "Sent", 1800, 160) { $0.saveTo = "output/welcome.md" },
            card(dropped, .end, "Dropped", 1800, 340) { $0.saveTo = "" },
        ], links: [
            Link(id: "l0", from: start, to: writer), Link(id: "l1", from: start, to: style),
            Link(id: "l2", from: writer, to: both), Link(id: "l3", from: style, port: "pass", to: both),
            Link(id: "l4", from: both, to: short), Link(id: "l5", from: short, port: "yes", to: sign),
            Link(id: "l6", from: short, port: "no", to: writer, maxPasses: 2), Link(id: "l7", from: sign, port: "approved", to: sent),
            Link(id: "l8", from: sign, port: "rejected", to: dropped),
        ])
        flow.groups = [CardGroup(id: "group001", name: "Checks", cardIDs: [short, sign])]

        // Times count back from now, so the runs are today's and their lengths are fixed.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }
        func mark(arrivals: Int = 0, passes: Int = 0, port: String? = nil, failed: Bool = false) -> RunMark {
            var mark = RunMark()
            mark.arrivals = arrivals
            mark.passes = passes
            mark.failed = failed
            if let port {
                mark.ports = [port: passes]
                mark.lastPort = port
            }
            return mark
        }
        func lines(_ texts: [String], from secondsAgo: Double, every gap: Double = 6) -> [LogLine] {
            texts.enumerated().map { LogLine(date: at(secondsAgo - Double($0.offset) * gap), text: $0.element) }
        }

        // The two runs before this one: one that went through, and one that stopped at the script.
        let oldNote = "Welcome to the book club. We meet on the first Thursday of each month at seven, in the back room of the library. Tea is on us."
        let firstLog = lines(["Run started at Start", "Start → Writer", "Start → Style guide", "Style guide → Pass", "Writer → Both ready",
                              "Both ready → passed on 2 messages together", "Short enough? → Yes", "Sign off is waiting for you", "Sign off → Approved",
                              "Sent got the final answer from Sign off"], from: 3 * 3600)
        let first = RunRecord(
            id: "run00001", started: at(3 * 3600), ended: at(3 * 3600 - 95), outcome: .finished, command: command, log: firstLog,
            results: [sent: oldNote],
            marks: [start: mark(passes: 2, port: "out"), writer: mark(arrivals: 1, passes: 1, port: "out"), style: mark(arrivals: 1, passes: 1, port: "pass"),
                    both: mark(arrivals: 2, passes: 1, port: "out"), short: mark(arrivals: 1, passes: 1, port: "yes"),
                    sign: mark(arrivals: 1, passes: 1, port: "approved"), sent: mark(arrivals: 1)],
            linkPasses: ["l0": 1, "l1": 1, "l2": 1, "l3": 1, "l4": 1, "l5": 1, "l7": 1],
            messages: ["l0": [LinkMessage(date: at(3 * 3600 - 6), from: "Start", text: command)],
                       "l2": [LinkMessage(date: at(3 * 3600 - 24), from: "Writer", text: oldNote)],
                       "l7": [LinkMessage(date: at(3 * 3600 - 90), from: "Sign off", text: oldNote)]],
            handOffs: 6, usage: [writer: Usage(cost: 0.42, input: 1_800, output: 1_150, cacheRead: 61_000, cacheWrite: 9_400)])
        let secondLog = lines(["Run started at Start", "Start → Writer", "Start → Style guide", "Style guide → Fail",
                               "Run stopped because Style guide failed: Style guide has nothing linked on Fail"], from: 3600)
        let second = RunRecord(
            id: "run00002", started: at(3600), ended: at(3600 - 21), outcome: .failed, command: command, log: secondLog, results: [:],
            marks: [start: mark(passes: 2, port: "out"), writer: mark(arrivals: 1), style: mark(arrivals: 1, passes: 1, port: "fail", failed: true)],
            linkPasses: ["l0": 1, "l1": 1], messages: ["l0": [LinkMessage(date: at(3600 - 6), from: "Start", text: command)]],
            handOffs: 1, usage: [writer: Usage(cost: 0.08, input: 400, output: 260, cacheRead: 12_000, cacheWrite: 2_100)])

        // 1: the third run has reached the agent and the script, and both are waiting on the person.
        let began = 90.0
        var log = firstLog + secondLog + lines(["Run started at Start", "Start → Writer", "Start → Style guide", "Style guide is waiting for you to let its command run"], from: began)
        var sessions: [String: SessionState] = [writer: .needsYou, orchestrator: .idle]
        var usage = [writer: Usage(cost: 0.50, input: 2_200, output: 1_410, cacheRead: 73_000, cacheWrite: 11_500),
                     orchestrator: Usage(cost: 0.21, input: 900, output: 620, cacheRead: 30_000, cacheWrite: 4_000)]
        var run = RemoteRunState(
            isRunning: true, marks: [start: mark(passes: 2, port: "out"), writer: mark(arrivals: 1), style: mark(arrivals: 1)],
            linkPasses: ["l0": 1, "l1": 1], liveLinkIDs: [], handOffs: 1,
            holds: [PendingHold(id: "hold0001", cardID: style, kind: .script, text: command, from: "Start", command: "cat docs/style.md", needsAllow: true)],
            results: [:], usage: usage, sessions: sessions, awaitingAnswer: [], banner: nil)
        var messages: [String: [LinkMessage]] = [
            "l0": [LinkMessage(date: at(began - 6), from: "Start", text: command)],
            "l1": [LinkMessage(date: at(began - 12), from: "Start", text: command)],
        ]
        func done(_ n: Int) async -> Bool {
            stage = n
            // Read by the state file, which is written again when the canvas says it has changed.
            client.canvas.didChangeWhatIsShown()
            try? await Task.sleep(for: .milliseconds(600))
            if n >= wanted {
                isPlayed = true
                DebugLaunch.afterCanned(client)
            }
            return n >= wanted
        }
        func tell(_ link: String) { client.debugTake(.messages(id: flowID, link: link, all: messages[link] ?? [])) }
        func terminal(_ key: String, cols: Int, rows: Int, _ text: String) {
            client.debugTake(.terminal(id: flowID, key: key, chunk: TerminalChunk(reset: true, cols: cols, rows: rows, data: Data(text.utf8))))
        }
        let esc = "\u{1b}"

        client.debugOutbox = { id, command in answer(client, id, command) }
        client.debugTake(.welcome(RemoteWelcome(version: Remote.version, macName: "Example Mac", canControl: UserDefaults.standard.bool(forKey: "qbControl"))))
        let summary = RemoteFlowSummary(id: flowID, name: flow.name, isSubflow: false, activity: .needsYou)
        // Others beside it, so the list of flows has every kind of row. Only the first can be opened.
        func other(_ n: Int, _ name: String, _ activity: FlowActivity = .quiet, isSubflow: Bool = false) -> RemoteFlowSummary {
            RemoteFlowSummary(id: "other00\(n)", name: name, isSubflow: isSubflow, activity: activity)
        }
        client.debugTake(.library(RemoteLibrary(projects: [
            RemoteProject(id: "p", name: "Book club", flows: [summary, other(1, "Monthly newsletter", .running), other(2, "Reading list", .failed),
                                                             other(3, "Thank the speakers"), other(4, "Check the spelling", isSubflow: true)]),
            RemoteProject(id: "q", name: "Allotment society", flows: [other(5, "Seed order with a long name that runs on"), other(6, "Rota")]),
        ])))
        client.open(flowID)
        client.debugTake(.opened(RemoteFlowSnapshot(flow: flow, run: run, log: log, messages: messages, runs: [first, second])))
        current = run
        edits = MadeUpEdits(flow: flow)
        told = (flow, RemoteEditState(), 0)
        terminal(writer, cols: screens[writer]?.cols ?? 0, rows: screens[writer]?.rows ?? 0, "\(esc)[1;38;5;208m● Writer\(esc)[0m in \(esc)[36m~/example/notes\(esc)[0m\r\n\r\n> \(command)\r\n\r\n"
            + "I'd like to save the draft.\r\n\r\n\(esc)[1mAllow writing to notes/welcome.md?\(esc)[0m\r\n\(esc)[7m 1. Yes \(esc)[0m\r\n 2. No\r\n")
        terminal(orchestrator, cols: screens[orchestrator]?.cols ?? 0, rows: screens[orchestrator]?.rows ?? 0, "\(esc)[1mOrchestrator\(esc)[0m\r\n\(esc)[2mRuns the flow called Welcome note.\(esc)[0m\r\n\r\n"
            + "\(esc)[32m✓\(esc)[0m run started\r\n\(esc)[33m…\(esc)[0m waiting on two cards\r\n")
        if await done(1) { return }

        // 2: both were answered on the Mac, the note went through the checks, and it waits to be signed off.
        sessions[writer] = .idle
        usage[writer] = Usage(cost: 0.71, input: 3_100, output: 2_050, cacheRead: 98_000, cacheWrite: 15_200)
        run.sessions = sessions
        run.usage = usage
        run.marks = [start: mark(passes: 2, port: "out"), writer: mark(arrivals: 1, passes: 1, port: "out"), style: mark(arrivals: 1, passes: 1, port: "pass"),
                     both: mark(arrivals: 2, passes: 1, port: "out"), short: mark(arrivals: 1, passes: 1, port: "yes"), sign: mark(arrivals: 1)]
        run.linkPasses = ["l0": 1, "l1": 1, "l2": 1, "l3": 1, "l4": 1, "l5": 1]
        run.handOffs = 5
        run.holds = [PendingHold(id: "hold0002", cardID: sign, kind: .approval, text: note, from: "Short enough?")]
        client.debugTake(.run(id: flowID, state: run))
        current = run
        let more = lines(["Style guide → Pass", "Writer → Both ready", "Both ready → passed on 2 messages together", "Short enough? → Yes", "Sign off is waiting for you"], from: began - 30)
        log += more
        client.debugTake(.log(id: flowID, lines: more, reset: false))
        messages["l2"] = [LinkMessage(date: at(began - 36), from: "Writer", text: note)]
        messages["l3"] = [LinkMessage(date: at(began - 30), from: "Style guide", text: guide)]
        messages["l4"] = [LinkMessage(date: at(began - 42), from: "Both ready", text: "From Writer:\n\(note)\n\nFrom Style guide:\n\(guide)")]
        messages["l5"] = [LinkMessage(date: at(began - 48), from: "Short enough?", text: note)]
        ["l2", "l3", "l4", "l5"].forEach(tell)
        if await done(2) { return }

        // 3: approved on the Mac. The run ends and is kept, with what it used.
        run.isRunning = false
        run.holds = []
        run.marks[sign] = mark(arrivals: 1, passes: 1, port: "approved")
        run.marks[sent] = mark(arrivals: 1)
        run.linkPasses["l7"] = 1
        run.handOffs = 6
        run.results = [sent: note]
        usage[writer] = Usage(cost: 0.87, input: 3_600, output: 2_450, cacheRead: 121_000, cacheWrite: 18_300)
        run.usage = usage
        client.debugTake(.run(id: flowID, state: run))
        current = run
        let last = lines(["Sign off → Approved", "Sent got the final answer from Sign off"], from: 12)
        log += last
        client.debugTake(.log(id: flowID, lines: last, reset: false))
        messages["l7"] = [LinkMessage(date: at(12), from: "Sign off", text: note)]
        tell("l7")
        let third = RunRecord(id: "run00003", started: at(began), ended: at(6), outcome: .finished, command: command,
                              log: Array(log.suffix(11)), results: run.results, marks: run.marks, linkPasses: run.linkPasses,
                              messages: messages, handOffs: 6,
                              usage: [writer: Usage(cost: 0.37, input: 1_400, output: 1_040, cacheRead: 48_000, cacheWrite: 6_800)])
        client.debugTake(.history(id: flowID, runs: [first, second, third]))
        if await done(3) { return }

        // 4: Run is pressed again on the Mac. The canvas is cleared for the new run.
        run.isRunning = true
        run.marks = [start: mark(passes: 2, port: "out"), writer: mark(arrivals: 1), style: mark(arrivals: 1)]
        run.linkPasses = ["l0": 1, "l1": 1]
        run.handOffs = 1
        run.results = [:]
        run.sessions[writer] = .working
        client.debugTake(.run(id: flowID, state: run))
        current = run
        let again = lines(["Run started at Start", "Start → Writer", "Start → Style guide"], from: 0, every: 0)
        client.debugTake(.log(id: flowID, lines: again, reset: false))
        for link in messages.keys.sorted() {
            messages[link] = link == "l0" || link == "l1" ? [LinkMessage(date: now, from: "Start", text: command)] : nil
            tell(link)
        }
        if await done(4) { return }

        // 5
        run.isRunning = false
        run.sessions[writer] = .exited
        client.debugTake(.run(id: flowID, state: run))
        current = run
        if await done(5) { return }

        // 6
        run.sessions[writer] = .notStarted
        run.sessions[orchestrator] = .notStarted
        client.debugTake(.run(id: flowID, state: run))
        current = run
        _ = await done(6)
    }

    /// What the made-up Mac makes of a command: it changes the run and says done, or refuses as the real
    /// one does in `App/Remote/RemoteCommands.swift`.
    private static func answer(_ client: RemoteClient, _ id: Int, _ command: RemoteCommand) {
        guard !UserDefaults.standard.bool(forKey: "qbSilent") else { return }
        if command.isEdit { return answer(client, id, edit: command) }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard var run = current else { return }
            var refusal: String?
            let gone = "That is no longer waiting for an answer."
            func held(_ id: String, _ kind: CardKind) -> Bool { run.holds.contains { $0.id == id && $0.kind == kind && (kind == .approval || $0.needsAllow) } }
            if !client.mirror.canControl {
                refusal = Remote.watchOnlyRefusal
            } else {
                switch command {
                case .run, .runFrom:
                    if run.isRunning { refusal = "A run is already going. Stop it before starting another." }
                    run.isRunning = true
                    run.marks = [:]
                    run.linkPasses = [:]
                    run.results = [:]
                case .stop:
                    if !run.isRunning { refusal = "No run is going." }
                    run.isRunning = false
                    run.holds = []
                case .approve(_, let holdID, _), .reject(_, let holdID, _):
                    if !held(holdID, .approval) { refusal = gone }
                    run.holds.removeAll { $0.id == holdID }
                case .allowScript(_, let holdID), .refuseScript(_, let holdID):
                    if !held(holdID, .script) { refusal = gone }
                    run.holds.removeAll { $0.id == holdID }
                case .startSession(_, let cardID):
                    run.sessions[cardID] = .starting
                case .openOnMac:
                    for key in [writer, orchestrator] where (run.sessions[key] ?? .notStarted) == .notStarted { run.sessions[key] = .starting }
                case .prompt(_, let key, let text):
                    if isRunning(key, in: run) { echo(client, key, "\r\n> \(text.replacingOccurrences(of: "\n", with: "\r\n  "))\r\n") } else { refusal = notRunning }
                case .keys(_, let key, let data):
                    // Only plain text is printed back: a real program decides for itself what any other key shows.
                    let isText = data.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
                    if isRunning(key, in: run) { echo(client, key, isText ? String(decoding: data, as: UTF8.self) : "") } else { refusal = notRunning }
                default:
                    // Edits are answered in `answer(_:_:edit:)`.
                    break
                }
            }
            if refusal == nil {
                current = run
                client.debugTake(.run(id: flowID, state: run))
            }
            client.debugTake(.answer(id: id, refusal: refusal))
        }
    }

    /// What the made-up Mac makes of an edit. It is made at once, so the steps of a drag are made in the
    /// order they were sent. Then, as the real Mac does, the answer goes first and the changed flow a moment
    /// after it. A step of a drag that isn't the last gets no answer.
    private static func answer(_ client: RemoteClient, _ id: Int, edit command: RemoteCommand) {
        guard var mac = edits else { return }
        let refusal = client.mirror.canControl ? mac.obey(command) : Remote.watchOnlyRefusal
        edits = mac
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            if command.isAnswered { client.debugTake(.answer(id: id, refusal: refusal)) }
            try? await Task.sleep(for: .milliseconds(50))
            tellFlow(client)
        }
    }

    /// Sends the device the flow and its Undo and Redo, if either has changed since it was last sent them.
    private static func tellFlow(_ client: RemoteClient) {
        guard let mac = edits, var sent = told else { return }
        if mac.flow != sent.flow {
            sent.flow = mac.flow
            sent.revision += 1
            client.debugTake(.flow(id: flowID, revision: sent.revision, flow: mac.flow))
        }
        if mac.state != sent.edit {
            sent.edit = mac.state
            client.debugTake(.edit(id: flowID, state: mac.state))
        }
        told = sent
    }

    /// Something a test has the made-up Mac do by itself, as if someone were sitting at it:
    ///   move:<card>:<x>,<y>    move a card there
    ///   delete:<card>          delete a card
    ///   refuse:<words>         refuse every edit from now on, in those words
    ///   accept                 stop refusing
    static func macDoes(_ what: String, _ client: RemoteClient) {
        guard var mac = edits else { return }
        let parts = what.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let card = parts.count > 1 ? mac.flow.cards.first { $0.name == parts[1] } : nil
        switch parts[0] {
        case "move":
            let place = (parts.count > 2 ? parts[2] : "").split(separator: ",").compactMap { Double($0) }
            guard let card, place.count == 2 else { return }
            mac.changeAtMac("Move") { flow in
                guard let index = flow.cards.firstIndex(where: { $0.id == card.id }) else { return }
                flow.cards[index].x = place[0]
                flow.cards[index].y = place[1]
            }
        case "delete":
            guard let card else { return }
            mac.changeAtMac("Delete Card") { try? $0.removeCard(card.id) }
        case "refuse":
            mac.refusing = parts.dropFirst().joined(separator: ":")
        case "accept":
            mac.refusing = nil
        default:
            return
        }
        edits = mac
        tellFlow(client)
    }

    private static let notRunning = "That session isn't running."

    private static func isRunning(_ key: String, in run: RemoteRunState) -> Bool {
        let state = run.sessions[key] ?? .notStarted
        return state != .notStarted && state != .exited && !UserDefaults.standard.bool(forKey: "qbStale")
    }

    /// Prints in a session's terminal what the program there would print back. With it goes a question to
    /// the terminal, where its cursor is, as a real program asks while it draws. The terminal answers, and
    /// the answer must go nowhere: typing has not opened a way back to the Mac for it.
    private static func echo(_ client: RemoteClient, _ key: String, _ text: String) {
        guard let screen = screens[key], !text.isEmpty else { return }
        client.debugTake(.terminal(id: flowID, key: key, chunk: TerminalChunk(reset: false, cols: screen.cols, rows: screen.rows, data: Data(("\u{1b}[6n" + text).utf8))))
    }
}
#endif
