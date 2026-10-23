import AppKit
import Foundation
import Observation
import QueenBeeCore

nonisolated enum Selection: Equatable, Sendable {
    case none
    case card(String)
    case link(String)
    /// Two or more cards, picked with Shift or by dragging a box round them.
    case cards(Set<String>)

    /// One card is `.card`, so its settings show; several are `.cards`.
    static func of(_ ids: Set<String>) -> Selection {
        ids.count > 1 ? .cards(ids) : ids.first.map { .card($0) } ?? .none
    }

    var cardIDs: Set<String> {
        switch self {
        case .card(let id): [id]
        case .cards(let ids): ids
        case .none, .link: []
        }
    }
}

/// What a flow's runs left behind, kept between launches: the log, each End card's answer,
/// and the marks the last run made on cards and links.
nonisolated struct RunHistory: Codable, Sendable {
    var log: [LogLine] = []
    var results: [String: String] = [:]
    var marks: [String: RunMark] = [:]
    var linkPasses: [String: Int] = [:]
    var handOffs = 0
    // Added after the first release that kept history, so a file from then still loads.
    var messages: [String: [LinkMessage]]?
    var runs: [RunRecord]?
    /// The whole text of the latest run's messages that `messages` keeps cut short, by message id.
    var wholeMessages: [String: String]?
}

/// One open flow: the graph, its sessions, and its runs. Every change to the graph goes
/// through here, whether it comes from the canvas, the settings panel or the orchestrator's
/// tools, so all three always see the same thing.
// Named as main-actor here because conforming to a Sendable protocol would otherwise opt the class out of the app's default.
@MainActor @Observable
final class FlowController: ToolHost {
    static let orchestratorKey = Flow.orchestratorKey

    var flow: Flow {
        didSet {
            guard flow != oldValue else { return }
            scheduleSave()
            if flow.cards.map(\.trigger) != oldValue.cards.map(\.trigger) || flow.cards.count != oldValue.cards.count { reschedule() }
            if !holds.isEmpty, flow.cards.map(\.waitMinutes) != oldValue.cards.map(\.waitMinutes) { retimeHolds() }
        }
    }
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored unowned let project: ProjectModel

    var selection: Selection = .none
    /// The agent card whose terminal has the keyboard.
    var focusedCardID: String?
    private(set) var log: [LogLine] = []
    /// Each End card's latest final answer.
    private(set) var results: [String: String] = [:]
    /// A one-line message about the last thing that didn't work.
    var banner: String?
    private(set) var isRunning = false
    /// Bumped when a session object is replaced, so the canvas picks up its new terminal.
    private(set) var sessionGeneration = 0
    /// Bumped whenever a session is added, replaced or dropped. `sessions` itself isn't watched, so this is
    /// how a paired device's copy of the flow learns that the sessions it was told about have changed.
    private(set) var sessionsRevision = 0
    /// Where the latest run has been, card by card. Kept after the run ends, cleared when the next starts.
    private(set) var marks: [String: RunMark] = [:]
    /// How many times each link has fired in the latest run.
    private(set) var linkPasses: [String: Int] = [:]
    /// The links each waiting agent's hand-off travelled, by that agent's card id.
    private var liveLinks: [String: Set<String>] = [:]
    /// Hand-offs made in the latest run.
    private(set) var handOffs = 0
    /// What each link carried in the run on show, oldest first.
    private(set) var messages: [String: [LinkMessage]] = [:]
    /// Earlier runs, oldest first.
    private(set) var runs: [RunRecord] = []
    /// The earlier run the canvas is showing in place of the latest, if any.
    private(set) var viewedRunID: String?
    /// What each session has used since it was made, by card id, with the orchestrator under its key.
    private(set) var usage: [String: Usage] = [:]
    /// Each session's usage when the latest run began, to tell the run's share from the rest.
    @ObservationIgnored private var usageAtRunStart: [String: Usage] = [:]
    /// Reads the agents' use every few seconds while a run goes on, for its spending limit.
    @ObservationIgnored private var spendingWatch: Task<Void, Never>?
    /// The cost breakdown is open over the canvas.
    var showsCost = false
    /// How many more levels of sub-flow the run that is going may still enter.
    @ObservationIgnored private var runLevelsLeft = Nesting.usualLimit
    /// The flow's own settings are open over the canvas.
    var showsFlowSettings = false
    /// The card whose "run from here" box is open in the settings panel.
    var runFromCardID: String?
    @ObservationIgnored private var currentRun: (id: String, started: Date, command: String)?
    /// How many runs are kept, and for how many of them what links carried. How much of each message is kept is
    /// `CarriedMessages`'s to say.
    private static let keptRuns = 20, runsWithMessages = 3
    /// The whole text of the messages in `messages` that are kept there cut short, by message id: what Retry and
    /// "run from here" give a card again.
    @ObservationIgnored private var wholeMessages: [UUID: String] = [:]
    /// Lets the Flow cards that run this flow take turns: a flow has one run at a time.
    @ObservationIgnored let subflowTurns = RunTurns()
    /// The flows the run that is going is inside, by id, when a Flow card began it. Empty for a run begun here.
    @ObservationIgnored private var runInside: Set<String> = []
    /// Flow cards waiting for a run of this flow to end, by run id.
    @ObservationIgnored private var endWaiters: [String: [CheckedContinuation<RunRecord?, Never>]] = [:]
    /// The run each agent's turn under way is working for, read off the hand-off that began the turn.
    @ObservationIgnored private var turnRun: [String: String] = [:]
    /// Set when the flow has been deleted, so nothing writes its history back.
    @ObservationIgnored private var isDeleted = false
    /// Every flow's history is written through this, so an older save never lands on top of a newer one.
    private static let historyWriter = LatestWins()
    /// Messages waiting at Approval and Script cards in the run that is going.
    private(set) var holds: [PendingHold] = []
    /// The work behind each hold that runs by itself: a script's command, or a Flow card's inner run.
    @ObservationIgnored private var holdTasks: [String: Task<Void, Never>] = [:]
    /// When each hold with a time limit began waiting, and the limit its clock was set for.
    @ObservationIgnored private var holdClocks: [String: (began: Date, wait: Duration)] = [:]
    /// The canvas's zoom, published by the canvas for the zoom pill.
    var zoom: Double = 1
    /// The part of the canvas the window is showing, published by the canvas for the minimap.
    var viewport = CGRect.zero

    @ObservationIgnored weak var canvas: CanvasView?
    @ObservationIgnored private(set) var sessions: [String: TerminalSession] = [:] {
        didSet { sessionsRevision += 1 }
    }
    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isOpen = false
    /// Set when the flow's sessions are shut down. Work still in flight then, such as a script
    /// finishing or a session's last hook, must not start writing again.
    @ObservationIgnored private var isClosed = false
    /// When the last run ended, so a file its agents changed on the way out doesn't start another.
    @ObservationIgnored private var lastRunEnded = Date.distantPast
    /// Agents whose plugin has reported a finished turn since their session started. Once a
    /// plugin has spoken it is loaded, and the app never routes that agent's replies itself.
    @ObservationIgnored private var pluginSpoke: Set<String> = []
    /// Agents whose last turn ended on a question they are still owed an answer to.
    private(set) var awaitingAnswer: Set<String> = []
    /// Waits to tell the person that the run hangs on an unanswered question.
    @ObservationIgnored private var stallNotice: Task<Void, Never>?
    /// How long a run may hang on an unanswered question before the person is told.
    private static let unansweredAfter: Duration = .seconds(90)
    /// Hand-offs given to a plugin to send, by the receiving session's id, until it says how they went.
    @ObservationIgnored private var inFlight: [String: Delivery] = [:]
    @ObservationIgnored private var runLogStart = 0
    /// Undo and redo for the graph, driven by the Edit menu.
    @ObservationIgnored let undoManager = UndoManager()
    /// Bumped whenever the undo stack changes, so the Edit menu's titles keep up.
    private(set) var undoRevision = 0
    /// The last change given an undo step, so a run of the same kind of change shares one.
    @ObservationIgnored private var lastUndo: (key: String, at: Date)?
    /// The flow as it was when a drag began. While set, the drag's steps don't each get an undo.
    @ObservationIgnored private var gestureStart: Flow?
    /// Where each card a paired device's drag has moved or resized was before the drag, and how big, by
    /// device id and then by card id. Only that is put back when the drag is undone.
    @ObservationIgnored private var deviceDrags: [String: [String: CGRect]] = [:]
    /// The agent cards a paired device added, copied or brought back while the flow was open. Their sessions
    /// are not started for them: each agent is a Claude Code process, and a device adds cards faster than
    /// a person reads them. They start when somebody asks: see `startSession(forCard:)` and `startAgents()`.
    @ObservationIgnored private var heldBack: Set<String> = []
    /// How many runs are being started and have not begun: starting can wait on a condition being judged.
    @ObservationIgnored private var runsStarting = 0
    /// True from the moment a run is asked for until it has begun or been turned down.
    var isStartingRun: Bool { runsStarting > 0 }
    /// True while a paired device's Undo or Redo is being done.
    @ObservationIgnored private var undoingForDevice = false
    /// Where the flow's agents, its orchestrator, its scripts and its saved answers work: the project folder,
    /// or a worktree of it. See `Workplace`.
    private(set) var workRoot: URL
    /// The project's repository as last read. Nil when the project isn't in one, or it hasn't been read yet.
    private(set) var git: Git.Info?
    /// The flow is asking where it should work, the first time it opens. Its agents wait for the answer.
    var asksForWorkplace = false
    /// The person said "Not now" to that question: it isn't asked again until the app is next opened.
    @ObservationIgnored private var workplaceDeferred = false
    /// The folder each session was started in, by card id, with the orchestrator under its key.
    @ObservationIgnored private var launchedIn: [String: String] = [:]
    /// Getting the flow's place ready, while that is under way: one at a time.
    @ObservationIgnored private var preparing: Task<String?, Never>?
    /// The banner the last refusal to get the place ready put up, so that it comes down once the place is
    /// ready, and no other banner does.
    @ObservationIgnored private var workplaceRefusal: String?

    private var services: AppServices { AppServices.shared }
    var warnings: [String: String] { QueenBeeCore.warnings(for: flow) }
    var liveLinkIDs: Set<String> { liveLinks.values.reduce(into: Set<String>()) { $0.formUnion($1) } }

    /// Agent cards whose session is waiting on the person, in canvas order.
    var cardsNeedingYou: [Card] {
        let waiting = Set(holds.filter { $0.kind == .approval || $0.needsAllow }.map(\.cardID))
        return flow.cards.filter { ($0.kind == .agent && sessions[$0.id]?.state == .needsYou) || waiting.contains($0.id) }
    }

    var activity: FlowActivity {
        if !cardsNeedingYou.isEmpty { return .needsYou }
        if isRunning { return .running }
        if marks.values.contains(where: \.failed) { return .failed }
        return .quiet
    }

    /// True for a flow nobody has built anything in yet: just its Start card, with no command.
    var isBlank: Bool {
        // A new sub-flow has its Input and its Output and nothing between them yet.
        flow.links.isEmpty && flow.cards.allSatisfy {
            ($0.kind == .start && ($0.command ?? "").isEmpty) || ($0.kind == .end && flow.isSubflow == true)
        }
    }

    init(flow: Flow, fileURL: URL, project: ProjectModel) {
        self.flow = flow
        self.fileURL = fileURL
        self.project = project
        self.workRoot = project.root
        undoManager.groupsByEvent = false
        loadHistory()
        reschedule()
    }

    /// What a remembered permission belongs to: this flow, in this project's folder. A flow's id
    /// comes from its file, so on its own it could be made to match another project's flow and
    /// borrow what was allowed there.
    private var allowScope: String { project.root.standardizedFileURL.path + "|" + flow.id }

    // MARK: Schedules

    /// When the clock next starts a run from each Start card whose schedule is on, by card id.
    private(set) var nextFires: [String: Date] = [:]
    /// Bumped whenever the schedules are worked out again. Which of them are on is kept in the app's settings,
    /// which nothing watches, so this is how a paired device's copy of the flow learns that one went on or off.
    private(set) var schedulesRevision = 0
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    /// The schedule each due time in `nextFires` was worked out from.
    @ObservationIgnored private var scheduledFor: [String: Trigger] = [:]
    @ObservationIgnored private var watchers: [String: (path: String, watcher: FileWatcher)] = [:]
    @ObservationIgnored private var lastFileFire = Date.distantPast

    /// Whether a Start card's schedule is one the person turned on in this app.
    func isArmed(_ card: Card) -> Bool {
        card.trigger.map { ScheduleArming.isArmed($0, command: card.command ?? "", scope: allowScope, cardID: card.id) } ?? false
    }

    /// Turns a Start card's schedule off and leaves it set, so that it does nothing until it is turned on again.
    func turnScheduleOff(onCard id: String) {
        guard let card = flow.card(id), card.kind == .start, isArmed(card) else { return }
        ScheduleArming.arm(nil, command: "", scope: allowScope, cardID: id)
        reschedule()
    }

    /// Sets what starts runs from a Start card, and turns it on: the person chose it, at this Mac or, with
    /// the schedule it already has, from a paired device the person lets control this Mac.
    func setTrigger(_ trigger: Trigger?, onCard id: String) {
        guard let card = flow.card(id), card.kind == .start else { return }
        ScheduleArming.arm(trigger, command: card.command ?? "", scope: allowScope, cardID: id)
        let changed = perform("Change Schedule", key: "trigger:\(id)") {
            guard let index = $0.cards.firstIndex(where: { $0.id == id && $0.kind == .start }) else { return }
            $0.cards[index].trigger = trigger
        }
        // Turning on a schedule that came with the flow changes nothing in the flow itself.
        if changed { reschedule() }
    }

    /// Works out what fires next and waits for it. Called whenever a schedule changes.
    private func reschedule() {
        schedulesRevision += 1
        scheduleTask?.cancel()
        let armed = flow.cards.filter { $0.kind == .start && isArmed($0) }
        var fires: [String: Date] = [:]
        var kept: [String: Trigger] = [:]
        for card in armed {
            guard let trigger = card.trigger else { continue }
            // A card whose schedule hasn't changed keeps the time it was due. Working it out
            // afresh on every edit to the flow would keep pushing an interval back.
            if scheduledFor[card.id] == trigger, let due = nextFires[card.id] {
                fires[card.id] = due
            } else if let next = trigger.nextFire(after: Date()) {
                fires[card.id] = next
            }
            kept[card.id] = trigger
        }
        scheduledFor = kept
        if nextFires != fires { nextFires = fires }
        watchFiles(for: armed.filter { $0.trigger?.kind == .file })
        guard let when = fires.values.min() else { return }
        scheduleTask = Task {
            try? await Task.sleep(for: .seconds(max(0, when.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            // Everything that has fallen due goes now, then each is given its next time.
            let due = self.nextFires.filter { $0.value <= Date().addingTimeInterval(0.5) }.keys.sorted()
            for cardID in due {
                self.fire(cardID, because: "on schedule")
                self.scheduledFor[cardID] = nil
            }
            self.reschedule()
        }
    }

    private func watchFiles(for cards: [Card]) {
        let root = project.root.resolvingSymlinksInPath()
        var wanted: [String: String] = [:]
        for card in cards {
            let relative = (card.trigger?.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !relative.isEmpty else { continue }
            // Only inside the project, with links followed first, as an End card's save path is checked.
            let url = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            if url.path == root.path || url.path.hasPrefix(root.path + "/") { wanted[card.id] = url.path }
        }
        for (id, watching) in watchers where wanted[id] != watching.path {
            watching.watcher.stop()
            watchers[id] = nil
        }
        for (id, path) in wanted where watchers[id] == nil {
            let watcher = FileWatcher(url: URL(fileURLWithPath: path)) { [weak self] changed in
                Task { @MainActor in self?.filesChanged(id, paths: changed) }
            }
            if let watcher { watchers[id] = (path, watcher) }
        }
    }

    private func filesChanged(_ cardID: String, paths: [String]) {
        // The flow's own agents change files too. A change during a run, or straight after
        // one this started, isn't a reason to start another. Nor is the app saving a flow,
        // or git doing its own housekeeping, which often land in the same batch as a real change.
        guard !isRunning, Date().timeIntervalSince(lastFileFire) > 5, Date().timeIntervalSince(lastRunEnded) > 10,
              let path = paths.first(where: { !$0.contains("/.queenbee/") && !$0.contains("/.git/") }) else { return }
        lastFileFire = Date()
        // The watcher reports paths with links followed, so the project's folder is compared the same way.
        let root = project.root.resolvingSymlinksInPath().path
        let name = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        fire(cardID, because: "\(name) changed", changed: name)
    }

    private func fire(_ cardID: String, because reason: String, changed: String? = nil) {
        guard let card = flow.card(cardID), card.kind == .start, isArmed(card) else { return }
        guard !(card.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            append("Skipped a run of \(card.name) (\(reason)): it has nothing to start with")
            return
        }
        guard services.environment != nil else {
            append("Skipped a run of \(card.name) (\(reason)): Claude Code wasn't ready yet")
            return
        }
        if isRunning {
            append("Skipped a run of \(card.name) (\(reason)): a run was already going")
            return
        }
        append("Starting \(card.name): \(reason)")
        let command = changed.map { "\(card.command ?? "")\n\nThe file that changed: \($0)" }
        Task { await self.run(command: command, startCardID: cardID) }
    }

    // MARK: History

    /// Kept in the app's own folder, not the project's, so a run leaves nothing to commit.
    /// A flow's id comes from its file, which may have been written by someone else, so it is
    /// never used as a file name as it stands: anything but a plain id is replaced by its hash.
    /// The name is a hash of the project's folder and the id, so two projects holding flows
    /// with the same id each keep their own history.
    private var historyURL: URL {
        let name = Data(allowScope.utf8).sha256Hex
        return services.supportDirectory.appendingPathComponent("history", isDirectory: true).appendingPathComponent("\(name).json")
    }

    /// Where 0.2.0 kept a flow's history: under its id alone. Moved to the new name the first time it is read.
    private var oldHistoryURL: URL? {
        let id = flow.id
        let plain = !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
        return plain ? services.supportDirectory.appendingPathComponent("history", isDirectory: true).appendingPathComponent("\(id).json") : nil
    }

    private func loadHistory() {
        var data = try? Data(contentsOf: historyURL)
        if data == nil, let old = oldHistoryURL, let found = try? Data(contentsOf: old) {
            // Moved to its new name, so another project's flow with this id never reads it.
            try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? found.write(to: historyURL, options: .atomic)) != nil { try? FileManager.default.removeItem(at: old) }
            data = found
        }
        guard let data, let history = try? JSONDecoder().decode(RunHistory.self, from: data) else { return }
        log = history.log
        results = history.results.filter { flow.card($0.key) != nil }
        marks = history.marks.filter { flow.card($0.key) != nil }
        linkPasses = history.linkPasses
        handOffs = history.handOffs
        messages = history.messages ?? [:]
        for (id, text) in history.wholeMessages ?? [:] { if let id = UUID(uuidString: id) { wholeMessages[id] = text } }
        wholeMessages = CarriedMessages.kept(wholeMessages, for: messages)
        runs = history.runs ?? []
        // What was loaded is earlier runs; the orchestrator is only told about new ones.
        runLogStart = log.count
    }

    private func scheduleHistorySave() {
        historyTask?.cancel()
        historyTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self.saveHistory()
        }
    }

    /// `evenIfClosed` is for work that finishes after the flow was closed and still belongs in its history, such as
    /// the last run's cost. Nothing is written for a flow that has been deleted.
    private func saveHistory(evenIfClosed: Bool = false) {
        historyTask?.cancel()
        historyTask = nil
        guard !isDeleted, evenIfClosed || !isClosed else { return }
        // What is saved as "now" is always the latest run, even while an earlier one is on show.
        let latest = viewedRunID == nil ? nil : runs.last
        let latestMessages = latest?.messages ?? messages
        var whole: [String: String] = [:]
        for (id, text) in CarriedMessages.kept(wholeMessages, for: latestMessages) { whole[id.uuidString] = text }
        let history = RunHistory(log: log, results: latest?.results ?? results, marks: latest?.marks ?? marks,
                                 linkPasses: latest?.linkPasses ?? linkPasses, handOffs: latest?.handOffs ?? handOffs,
                                 messages: latestMessages, runs: runs, wholeMessages: whole.isEmpty ? nil : whole)
        // Encoding and writing can take a while for a long log, so neither holds up the canvas. The writes can
        // finish in any order, so each takes a ticket now and one never lands on top of a newer one.
        let url = historyURL
        let ticket = Self.historyWriter.ticket()
        Task.detached(priority: .utility) {
            await FlowController.historyWriter.write({ try JSONEncoder().encode(history) }, ticket: ticket, to: url)
        }
    }

    // MARK: Cost

    /// Everything this flow's own sessions have used, the orchestrator included.
    var totalUsage: Usage { usage.values.reduce(Usage(), +) }

    /// The flows this one's Flow cards run, each once, in canvas order.
    var innerFlows: [FlowController] { nesting.innerFlows(of: flow.id).compactMap(project.controller) }

    /// Every flow below this one, outermost first, each once, with how deep it sits.
    func subflows() -> [(controller: FlowController, depth: Int)] {
        nesting.subflows(of: flow.id).compactMap { entry in project.controller(entry.id).map { ($0, entry.depth) } }
    }

    /// What this flow has used together with every sub-flow below it.
    var usageWithSubflows: Usage {
        subflows().reduce(totalUsage) { $0 + $1.controller.totalUsage }
    }

    /// Reads usage again for this flow and every sub-flow below it.
    func refreshUsageWithSubflows() async {
        await refreshUsage()
        for inner in subflows() { await inner.controller.refreshUsage() }
    }

    /// What a card used in the run on show: the recorded figure for a finished run, or the
    /// running difference while one is going.
    func runUsage(forCard id: String) -> Usage? {
        if isRunning || currentRun != nil { return usage[id].map { $0.since(usageAtRunStart[id] ?? Usage()) } }
        let record = viewedRunID.flatMap { id in runs.first { $0.id == id } } ?? runs.last
        return record?.usage?[id]
    }

    /// Reads usage again from the sessions' transcripts: one session's, or all of them.
    func refreshUsage(_ only: String? = nil) async {
        var ids: [String: String] = [:]
        if only == nil || only == Self.orchestratorKey { ids[Self.orchestratorKey] = flow.orchestratorSessionID }
        for card in flow.cards where card.kind == .agent && (only == nil || only == card.id) { ids[card.id] = card.sessionID }
        let read = await Task.detached { ids.compactMapValues { UsageReader.usage(sessionID: $0) } }.value
        for (key, value) in read where usage[key] != value { usage[key] = value }
        stopIfPastSpendingLimit()
    }

    /// Stops the run once its agents have spent more than the flow allows one run, the way Stop does: its agents
    /// are interrupted, and the log and a notice say why. The orchestrator's use is not the run's.
    private func stopIfPastSpendingLimit() {
        guard isRunning, currentRun != nil, flow.spendingLimit != nil, let engine else { return }
        let spent = usage.filter { $0.key != Self.orchestratorKey }
            .reduce(Usage()) { $0 + $1.value.since(usageAtRunStart[$1.key] ?? Usage()) }
        guard let line = SpendingLimit.passed(limit: flow.spendingLimit, spent: spent) else { return }
        Task { self.absorb(await engine.stop(ending: .spentLimit, line: line), sender: nil) }
    }

    /// A moment after a run ends, once Claude Code has written its totals, the run is given its share. That is
    /// still done when the flow has been closed meanwhile, as it often is straight after a run.
    private func recordUsage(forRun id: String) {
        let before = usageAtRunStart
        Task {
            // Long enough for a sub-flow that ended just before this run to have costed its own.
            try? await Task.sleep(for: .seconds(4))
            await self.refreshUsage()
            guard !self.isDeleted, let index = self.runs.firstIndex(where: { $0.id == id }) else { return }
            var shares: [String: Usage] = [:]
            for (key, now) in self.usage where key != Self.orchestratorKey {
                let share = now.since(before[key] ?? Usage())
                if !share.isZero { shares[key] = share }
            }
            // A Flow card's share is what the flow it ran used while this run was going.
            let run = self.runs[index]
            for card in self.flow.cards where card.kind == .flow {
                guard let inner = self.innerFlow(of: card) else { continue }
                let during = inner.runs.filter { $0.started >= run.started.addingTimeInterval(-1) && $0.started <= run.ended }
                let share = during.reduce(Usage()) { $0 + $1.cost }
                if !share.isZero { shares[card.id] = share }
            }
            self.runs[index].usage = shares
            self.saveHistory(evenIfClosed: true)
        }
    }

    // MARK: Looking at earlier runs

    /// The log on show: an earlier run's when one is being looked at, else everything.
    var shownLog: [LogLine] {
        viewedRunID.flatMap { id in runs.first { $0.id == id }?.log } ?? log
    }

    /// Puts an earlier run's marks, messages and answers on the canvas, or the latest with nil.
    func view(run id: String?) {
        guard !isRunning else { return }
        let record = id.flatMap { id in runs.first { $0.id == id } } ?? runs.last
        guard let record else { return }
        results = record.results.filter { flow.card($0.key) != nil }
        marks = record.marks.filter { flow.card($0.key) != nil }
        linkPasses = record.linkPasses
        messages = record.messages
        handOffs = record.handOffs
        viewedRunID = record.id == runs.last?.id ? nil : record.id
    }

    /// A run is about to begin: the canvas is cleared of the last one.
    private func clearForRun() {
        results.removeAll()
        marks.removeAll()
        linkPasses.removeAll()
        liveLinks.removeAll()
        messages.removeAll()
        wholeMessages.removeAll()
        handOffs = 0
        viewedRunID = nil
        runLogStart = log.count
        usageAtRunStart = usage
        watchSpending()
    }

    /// How often a run's use is read while it goes on.
    private static let spendingCheckEvery: Duration = .seconds(5)

    /// A turn's use is read when it ends, but a long turn can spend a lot before then, and the reply it ends with is
    /// passed on at once. So while a run goes on, its agents' use is read every few seconds as well, and a run past
    /// its spending limit is stopped part-way through such a turn. The limit can be set while the run goes on.
    private func watchSpending() {
        spendingWatch?.cancel()
        spendingWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.spendingCheckEvery)
                guard let self, !Task.isCancelled, self.isRunning, self.currentRun != nil else { return }
                if self.flow.spendingLimit != nil { await self.refreshUsage() }
            }
        }
    }

    private func finishRecord(_ output: RunOutput) {
        guard let run = currentRun else { return }
        currentRun = nil
        let ending = output.ending
        let outcome: RunRecord.Outcome = marks.values.contains(where: \.failed) ? .failed : ending?.outcome ?? .finished
        let record = RunRecord(id: run.id, started: run.started, ended: Date(), outcome: outcome, command: run.command,
                               log: Array(log.dropFirst(runLogStart)), results: results, marks: marks, linkPasses: linkPasses,
                               messages: messages, handOffs: handOffs, ending: ending)
        runs.append(record)
        if runs.count > Self.keptRuns { runs.removeFirst(runs.count - Self.keptRuns) }
        // The messages a link carried are kept for the newest few runs only; older runs keep their path and answers.
        for index in runs.indices.dropLast(Self.runsWithMessages) where !runs[index].messages.isEmpty { runs[index].messages = [:] }
        recordUsage(forRun: run.id)
        endWaiters.removeValue(forKey: run.id)?.forEach { $0.resume(returning: record) }
    }

    /// The last message that reached a card in the run on show, whole: what "run from here" and Retry start with.
    func lastMessage(into cardID: String) -> LinkMessage? {
        flow.links(into: cardID).compactMap { messages[$0.id]?.last }.max { $0.date < $1.date }
            .map { CarriedMessages.whole($0, from: wholeMessages) }
    }

    /// A paired device's Clear: the log and the earlier runs go, but for the lines that say what a device did or that
    /// a schedule went on or off, which stay, followed by one saying which device cleared it.
    func clearLog(fromDevice device: String) {
        let kept = LogLine.leftByDeviceClear(log: log, runs: runs)
        clearLog()
        log = kept
        runLogStart = log.count
        noteFromDevice("\(device) cleared the log")
    }

    /// Empties the log. Answers and run marks stay until the next run replaces them.
    func clearLog() {
        log.removeAll()
        runs.removeAll()
        viewedRunID = nil
        runLogStart = 0
        saveHistory()
    }

    /// The flow is being deleted: its history goes with it.
    func forgetHistory() {
        isDeleted = true
        historyTask?.cancel()
        historyTask = nil
        try? FileManager.default.removeItem(at: historyURL)
    }

    // MARK: Opening and closing

    /// The flow came on screen: start its sessions, once `claude` has been found.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        isClosed = false
        // Opened by somebody: every agent in it starts, whoever added the card.
        heldBack.removeAll()
        Task {
            while services.environment == nil { try? await Task.sleep(for: .milliseconds(100)) }
            // The first time a flow opens in a repository, it asks where it works before any agent starts.
            git = await Git.info(at: project.root)
            if shouldAskForWorkplace {
                asksForWorkplace = true
                return
            }
            await prepareWorkplace()
            startMissingSessions()
            await refreshUsage()
        }
        reschedule()
    }

    /// A paired device's "Start its agents": what choosing the flow in the sidebar does to its sessions, and
    /// for a flow that is already open, the start of the agents that were waiting to be asked for.
    func startAgents() {
        guard isOpen else { return open() }
        heldBack.removeAll()
        // Not before the person has said where the flow works.
        if services.environment != nil, !asksForWorkplace { startMissingSessions() }
    }

    /// True when the flow is open and has an agent whose session is waiting to be asked for.
    var hasAgentsHeldBack: Bool { isOpen && !heldBack.isEmpty }

    /// `saving: false` is for a flow whose file has just gone to the Trash: saving would write it back.
    func shutDown(saving: Bool = true) {
        // The run, if there is one, ends here: nothing is waited on and nothing more is routed.
        holdTasks.values.forEach { $0.cancel() }
        holdTasks.removeAll()
        holdClocks.removeAll()
        holds.removeAll()
        awaitingAnswer.removeAll()
        stallNotice?.cancel()
        spendingWatch?.cancel()
        currentRun = nil
        isRunning = false
        // A Flow card waiting on this flow's run hears that it ended with nothing to pass on.
        endWaiters.values.joined().forEach { $0.resume(returning: nil) }
        endWaiters.removeAll()
        subflowTurns.somethingEnded()
        if let engine { Task { _ = await engine.stop() } }
        scheduleTask?.cancel()
        watchers.values.forEach { $0.watcher.stop() }
        watchers.removeAll()
        nextFires = [:]
        scheduledFor = [:]
        if saving { saveNow() } else { saveTask?.cancel() }
        if historyTask != nil { saveHistory() }
        sessions.values.forEach { $0.terminate() }
        sessions.removeAll()
        browserCards.forEach { project.browser.release("\(flow.id)/\($0)") }
        browserCards.removeAll()
        isOpen = false
        isClosed = true
    }

    // MARK: Editing

    /// Applies a change to a copy of the flow and keeps it only if it is valid. `name` is what
    /// the Edit menu calls it. Changes with the same `key` made close together undo as one.
    @discardableResult
    private func perform(_ name: String, key: String? = nil, undoable: Bool = true, _ body: (inout Flow) throws -> Void) -> Bool {
        var copy = flow
        do {
            try body(&copy)
        } catch {
            banner = String(describing: error)
            return false
        }
        banner = nil
        let old = flow
        cutLooseFlowCardsThatCannotNest(in: &copy)
        flow = copy
        if undoable { registerUndo(from: old, name, key: key) }
        reconcile()
        return true
    }

    /// A pasted, copied or restored Flow card that would make a circle, or go too deep, is kept but no longer runs anything.
    private func cutLooseFlowCardsThatCannotNest(in copy: inout Flow) {
        let nesting = Nesting(flows: project.controllers.map { $0 === self ? copy : $0.flow })
        for index in copy.cards.indices where copy.cards[index].kind == .flow && copy.cards[index].flowRef != flow.card(copy.cards[index].id)?.flowRef {
            if let inner = Nesting.resolve(copy.cards[index].flowRef, in: project.controllers.map(\.flow), excluding: flow.id),
               nesting.problem(placing: inner, in: flow.id) != nil { copy.cards[index].flowRef = nil }
        }
    }

    // MARK: Undo

    /// Makes the change from `old` to the flow as it is now undoable.
    private func registerUndo(from old: Flow, _ name: String, key: String? = nil, within window: TimeInterval = 1.5) {
        guard gestureStart == nil, old != flow else { return }
        if let key, let last = lastUndo, last.key == key, Date().timeIntervalSince(last.at) < window {
            // The step already on the stack goes back to before the first of these changes.
            lastUndo = (key, Date())
            return
        }
        lastUndo = key.map { ($0, Date()) }
        // Each step is its own group. Left to group by event, changes that arrive from the
        // orchestrator's tools rather than from a click all landed in one step.
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { $0.restore(old, name) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        undoRevision += 1
    }

    /// The Edit menu's Undo and Redo. Text being typed keeps its own: with the cursor in a
    /// text box that has something to take back, the command goes there. Everywhere else,
    /// wherever the keyboard happens to be, it works on the flow.
    func undo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
            text.undoManager?.undo()
        } else if undoManager.canUndo {
            asking { undoManager.undo() } putBack: { undoManager.redo() }
        }
    }

    func redo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true {
            text.undoManager?.redo()
        } else if undoManager.canRedo {
            asking { undoManager.redo() } putBack: { undoManager.undo() }
        }
    }

    /// Whether the keyboard is in an agent's terminal or a card's browser. Command-Z typed there is meant for
    /// what is being typed into, never for the canvas, which may be out of sight behind it.
    static var keyboardIsInTerminalOrBrowser: Bool {
        var view = NSApp.keyWindow?.firstResponder as? NSView
        while let v = view {
            if v is SessionTerminalView || v is BrowserPageView { return true }
            view = v.superview
        }
        return false
    }

    /// Set while the person's own Undo or Redo is being done, so a step that would stop a busy agent asks first.
    @ObservationIgnored private var asksBeforeStopping = false
    /// The step just tried was turned down. It has been put on the other stack, and has to go back.
    @ObservationIgnored private var stepTurnedDown = false

    /// Does an undo or redo step, asking first if it would remove an agent that is at work. If the person
    /// says no, `putBack` returns the step to the stack it came from, and the flow is left as it was.
    private func asking(_ step: () -> Void, putBack: () -> Void) {
        asksBeforeStopping = true
        stepTurnedDown = false
        step()
        asksBeforeStopping = false
        if stepTurnedDown {
            stepTurnedDown = false
            putBack()
        }
    }

    /// Puts a step that was turned down back on the stack it was taken from. Run by `putBack`, which files what
    /// it registers on the stack opposite to the one it is undoing or redoing from, which is that one.
    private func refile(_ old: Flow, _ name: String) {
        undoManager.registerUndo(withTarget: self) { $0.restore(old, name) }
        undoManager.setActionName(name)
    }

    /// The agents going from `current` to `next` would delete whose sessions are working or waiting on the person.
    private func busyAgents(removedGoingFrom current: Flow, to next: Flow) -> [Card] {
        current.cards.filter { next.card($0.id) == nil && isBusy($0) }
    }

    /// An agent card whose session is in the middle of a turn or waiting on the person.
    private func isBusy(_ card: Card) -> Bool {
        card.kind == .agent && [.working, .needsYou].contains(sessions[card.id]?.state ?? .notStarted)
    }

    /// Asks before something stops agents in the middle of their work. True to go ahead.
    private func mayStop(_ agents: [Card], doing action: String) -> Bool {
        guard !agents.isEmpty, !TestHarness.isEnabled else { return true }
        let names = agents.map(\.name)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(action) and stop \(list)?"
        alert.informativeText = (agents.count == 1 ? "\(list) is" : "They are")
            + " in the middle of a task or waiting for your answer. Removing the card stops its Claude Code session, and the work it was doing is cut short."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var undoTitle: String { _ = undoRevision; return undoManager.canUndo ? undoManager.undoMenuItemTitle : "Undo" }
    var redoTitle: String { _ = undoRevision; return undoManager.canRedo ? undoManager.redoMenuItemTitle : "Redo" }

    /// Puts the graph back to `old`, and makes that undoable in turn. Sessions are not part
    /// of the graph: a card that is still there keeps the session it has now.
    private func restore(_ old: Flow, _ name: String) {
        let current = flow
        if asksBeforeStopping, !mayStop(busyAgents(removedGoingFrom: current, to: old), doing: undoManager.isRedoing ? "Redo \(name)" : "Undo \(name)") {
            // Nothing changes. The step is filed on the other stack for now, from where `asking` puts it back.
            undoManager.registerUndo(withTarget: self) { $0.refile(old, name) }
            undoManager.setActionName(name)
            stepTurnedDown = true
            return
        }
        var back = old
        back.orchestratorSessionID = current.orchestratorSessionID
        // Where the flow works isn't part of the graph either: Undo never moves it.
        back.workplace = current.workplace
        for i in back.cards.indices {
            guard let now = current.card(back.cards[i].id) else { continue }
            back.cards[i].sessionID = now.sessionID
            // An agent's folder is never changed from a device, by Undo either: it stays as it is now.
            if undoingForDevice { back.cards[i].cwd = now.cwd }
        }
        // An agent a device's Undo brings back is not started for it, any more than one it adds.
        if undoingForDevice { holdBackAgents(in: back, newSince: current) }
        lastUndo = nil
        flow = back
        undoManager.registerUndo(withTarget: self) { $0.restore(current, name) }
        undoManager.setActionName(name)
        undoRevision += 1
        reconcile()
    }

    /// A drag is starting: everything until `endGesture` is one undo step.
    func beginGesture() {
        if gestureStart == nil { gestureStart = flow }
    }

    func endGesture(_ name: String) {
        guard let start = gestureStart else { return }
        gestureStart = nil
        registerUndo(from: start, name)
    }

    /// After the graph changes: drop sessions of deleted cards, start sessions of new ones,
    /// and clear a selection that points at something gone.
    private func reconcile() {
        let agentIDs = Set(flow.cards.filter { $0.kind == .agent }.map(\.id))
        for (id, session) in sessions where id != Self.orchestratorKey && !agentIDs.contains(id) {
            let name = session.launched?.name
            session.terminate()
            sessions[id] = nil
            agentStopped(id, name: name, reason: "its card was deleted")
        }
        heldBack.formIntersection(agentIDs)
        // A card that was deleted, or had its Browser switch turned off, gives its tab back.
        for id in browserCards where flow.card(id)?.browser != true {
            browserCards.remove(id)
            project.browser.release("\(flow.id)/\(id)")
        }
        switch selection {
        case .card(let id) where flow.card(id) == nil: selection = .none
        case .link(let id) where !flow.links.contains(where: { $0.id == id }): selection = .none
        case .cards(let ids):
            let left = ids.filter { flow.card($0) != nil }
            if left != ids { selection = .of(left) }
        default: break
        }
        // A Flow card the orchestrator pointed at a flow by name is tied to that flow's id, so
        // renaming the flow later doesn't cut it loose.
        for index in flow.cards.indices where flow.cards[index].kind == .flow {
            if let inner = innerFlow(of: flow.cards[index]), flow.cards[index].flowRef != inner.flow.id {
                flow.cards[index].flowRef = inner.flow.id
            }
        }
        // A message waiting at a card that has been deleted has nowhere to be answered from.
        for hold in holds where flow.card(hold.cardID) == nil {
            holdTasks[hold.id]?.cancel()
            holdTasks[hold.id] = nil
            resolve(hold.id, port: hold.kind == .approval ? "rejected" : "fail", text: nil)
        }
        if isOpen, services.environment != nil { startMissingSessions() }
    }

    func select(_ new: Selection) {
        if new != .none { showsFlowSettings = false }
        if selection != new { selection = new }
    }

    /// Shift-click: adds a card to what is selected, or takes it out.
    func toggleSelection(_ id: String) {
        var ids = selection.cardIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        selection = .of(ids)
    }

    func selectAll() {
        selection = .of(Set(flow.cards.map(\.id)))
    }

    /// Where each card a drag of `id` moves is now. Dragging one of several selected cards
    /// moves them all; dragging any other card selects it and moves it alone.
    func dragOrigins(for id: String) -> [String: CGPoint] {
        // Dragging is for moving. It doesn't select, so a card's settings don't open under the
        // pointer on the way: those open on a click, which is a press and release with no drag.
        let moving = selection.cardIDs.contains(id) ? selection.cardIDs : [id]
        var origins: [String: CGPoint] = [:]
        for card in flow.cards where moving.contains(card.id) { origins[card.id] = CGPoint(x: card.x, y: card.y) }
        return origins
    }

    /// Puts each card at its origin plus `offset`. Part of a drag, so it is undone with the drag.
    func moveCards(from origins: [String: CGPoint], by offset: CGSize) {
        // The whole group stops at the canvas's edge together, so it keeps its shape.
        guard let left = origins.values.map(\.x).min(), let top = origins.values.map(\.y).min() else { return }
        let dx = max(offset.width, CardView.farLeft - left), dy = max(offset.height, CardView.farLeft - top)
        var copy = flow
        for i in copy.cards.indices {
            guard let origin = origins[copy.cards[i].id] else { continue }
            copy.cards[i].x = origin.x + dx
            copy.cards[i].y = origin.y + dy
        }
        if copy != flow { flow = copy }
    }

    /// The arrow keys: moves what is selected by a step.
    func nudgeSelection(dx: Double, dy: Double) {
        let ids = selection.cardIDs
        guard !ids.isEmpty else { return }
        let old = flow
        let moving = flow.cards.filter { ids.contains($0.id) }
        guard let left = moving.map(\.x).min(), let top = moving.map(\.y).min() else { return }
        // Stopped at the canvas's edge as a group, so it keeps its shape.
        let stepX = max(dx, CardView.farLeft - left), stepY = max(dy, CardView.farLeft - top)
        for i in flow.cards.indices where ids.contains(flow.cards[i].id) {
            flow.cards[i].x += stepX
            flow.cards[i].y += stepY
        }
        registerUndo(from: old, "Move", key: "nudge")
    }

    func resizeCard(_ id: String, width: Double, height: Double) {
        var patch = CardPatch()
        patch.width = width
        patch.height = height
        perform("Resize") { try $0.updateCard(id, patch: patch) }
    }

    func update(_ id: String, _ patch: CardPatch) {
        // A text box undoing its own typing writes the old text back through here. That is
        // the undo, not a new change, so it doesn't get a step of its own.
        let textManager = (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager
        let isTextUndo = textManager?.isUndoing == true || textManager?.isRedoing == true
        // The person changing what a scheduled Start card starts with is still the person's
        // schedule, so it stays on. The same change from anywhere else switches it off.
        let keepsArmed = patch.command != nil && flow.card(id).map { $0.kind == .start && isArmed($0) } == true
        perform("Change \(flow.card(id)?.name ?? "Card")", key: "edit:\(id)", undoable: !isTextUndo) { try $0.updateCard(id, patch: patch) }
        if keepsArmed, let card = flow.card(id), let trigger = card.trigger {
            ScheduleArming.arm(trigger, command: card.command ?? "", scope: allowScope, cardID: id)
            reschedule()
        }
    }

    // MARK: Roles

    /// The saved role an agent card was made from, if it still exists.
    func role(of card: Card) -> AgentRole? {
        card.role.flatMap { id in services.roles.first { $0.id == id } }
    }

    /// Saves a card's settings as a role under the card's name, and ties the card to it.
    func saveRole(fromCard id: String) {
        guard let card = flow.card(id), card.kind == .agent else { return }
        var role = AgentRole(from: card)
        // Saving from a card that already has a role updates that role.
        if let existing = self.role(of: card) {
            role.id = existing.id
            role.name = existing.name
        }
        let saved = services.save(role)
        setRole(saved.id, onCard: id, name: "Save Role")
    }

    /// Gives a card a role's settings and ties it to the role, or cuts the tie with nil.
    /// A role a paired device saved or changed is asked about first, once, and applied only if agreed to:
    /// see `AppServices.whenAgreed`.
    func applyRole(_ role: AgentRole?, toCard id: String) {
        guard let role else { return setRole(nil, onCard: id, name: "Remove Role") }
        // What is applied is the role as the person agreed to it, not as it was when it was picked.
        services.whenAgreed(toUse: role) { [weak self] role in
            guard let self else { return }
            perform("Apply \(role.name)") {
                try $0.updateCard(id, patch: role.patch)
                if let index = $0.cards.firstIndex(where: { $0.id == id }) { $0.cards[index].role = role.id }
            }
        }
    }

    private func setRole(_ roleID: String?, onCard id: String, name: String) {
        perform(name) {
            guard let index = $0.cards.firstIndex(where: { $0.id == id }) else { return }
            $0.cards[index].role = roleID
        }
    }

    // MARK: Copying

    /// What Copy puts on the pasteboard and Paste reads back: only this app writes or reads it.
    static let fragmentType = NSPasteboard.PasteboardType("dev.queenbee.flow-fragment")

    func duplicateSelection() {
        let ids = selection.cardIDs
        guard !ids.isEmpty else { return }
        var made: [Card] = []
        perform(ids.count == 1 ? "Duplicate Card" : "Duplicate Cards") { made = $0.insert($0.fragment(of: ids), dx: 48, dy: 48) }
        if !made.isEmpty { selection = .of(Set(made.map(\.id))) }
    }

    func copySelection() {
        let ids = selection.cardIDs
        guard !ids.isEmpty, let data = try? JSONEncoder().encode(flow.fragment(of: ids)) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: Self.fragmentType)
    }

    var canPaste: Bool { NSPasteboard.general.data(forType: Self.fragmentType) != nil }

    /// Pastes what was copied. With a point, as from the canvas's menu, its top-left card
    /// lands there; without, it lands a step away from where it was copied.
    func paste(at point: CGPoint? = nil) {
        guard let data = NSPasteboard.general.data(forType: Self.fragmentType),
              let fragment = try? JSONDecoder().decode(FlowFragment.self, from: data), !fragment.cards.isEmpty else { return }
        let offset = Self.pasteOffset(of: fragment, at: point)
        var made: [Card] = []
        perform("Paste") { made = $0.insert(fragment, dx: offset.dx, dy: offset.dy) }
        if !made.isEmpty { selection = .of(Set(made.map(\.id))) }
    }

    /// How far pasted cards are moved from where they were copied: so the top-left one lands at the point,
    /// or without one a step down and right.
    static func pasteOffset(of fragment: FlowFragment, at point: CGPoint?) -> (dx: Double, dy: Double) {
        guard let point, let left = fragment.cards.map(\.x).min(), let top = fragment.cards.map(\.y).min() else { return (48, 48) }
        return (point.x - left, point.y - top)
    }

    /// Adds an agent made from a saved role: the role's settings, its name unless another card has it, and
    /// the card tied to the role.
    @discardableResult
    static func addAgent(from role: AgentRole, to flow: inout Flow, x: Double, y: Double) throws -> Card {
        let made = try flow.addCard(kind: .agent, name: flow.uniqueName(role.name), x: x, y: y, patch: role.patch)
        if let index = flow.cards.firstIndex(where: { $0.id == made.id }) { flow.cards[index].role = role.id }
        return flow.cards.first { $0.id == made.id } ?? made
    }

    /// Adds a card. With a point, as when one is dropped from the palette, the card is centred
    /// there. Without, it goes to the middle of what is on screen, stepped clear of other cards.
    func addCard(_ kind: CardKind, at point: CGPoint? = nil, role: AgentRole? = nil) {
        // A role a paired device saved or changed is asked about first, once, and the card added only if agreed
        // to. The point is kept for then.
        guard let role else { return placeCard(kind, at: point, role: nil) }
        services.whenAgreed(toUse: role) { [weak self] agreed in self?.placeCard(kind, at: point, role: agreed) }
    }

    private func placeCard(_ kind: CardKind, at point: CGPoint?, role: AgentRole?) {
        var made: Card?
        let size = Card.make(kind: kind, name: "x", x: 0, y: 0)
        var spot: CGRect
        if let point {
            spot = CGRect(origin: Self.dropSpot(for: kind, at: point), size: CGSize(width: size.width, height: size.height))
        } else {
            let center = canvas?.visibleCenter ?? CGPoint(x: 400, y: 300)
            spot = CGRect(x: max(20, center.x - size.width / 2), y: max(20, center.y - size.height / 2),
                          width: size.width, height: size.height)
            let taken = flow.cards.map(CanvasGeometry.frame(of:))
            var tries = 0
            while tries < 30, taken.contains(where: { $0.insetBy(dx: -16, dy: -16).intersects(spot) }) {
                spot.origin.x += 48
                spot.origin.y += 48
                tries += 1
            }
        }
        perform("Add \(role?.name ?? kind.label)") {
            if let role {
                made = try Self.addAgent(from: role, to: &$0, x: spot.minX, y: spot.minY)
            } else {
                made = try $0.addCard(kind: kind, x: spot.minX, y: spot.minY, patch: Self.newCardPatch(for: kind))
            }
        }
        if let made { selection = .card(made.id) }
    }

    /// Where a new card's corner goes when the card is dropped at a point: the middle of its title bar lands there.
    static func dropSpot(for kind: CardKind, at point: CGPoint) -> CGPoint {
        let size = Card.make(kind: kind, name: "x", x: 0, y: 0)
        return CGPoint(x: max(20, point.x - size.width / 2), y: max(20, point.y - CanvasGeometry.titleHeight / 2))
    }

    /// What a new card of this kind starts with besides its kind's own defaults: an agent gets the model chosen in Settings.
    static func newCardPatch(for kind: CardKind) -> CardPatch {
        var patch = CardPatch()
        if kind == .agent, let model = UserDefaults.standard.string(forKey: "defaultModel"), !model.isEmpty { patch.model = model }
        return patch
    }

    func link(from: String, port: String, to: String) {
        var made: Link?
        perform("Link") { made = try $0.addLink(from: from, port: port, to: to) }
        if let made { selection = .link(made.id) }
    }

    func setMaxPasses(_ id: String, _ value: Int) {
        perform("Change Link", key: "link:\(id)") { try $0.updateLink(id, maxPasses: value) }
    }

    func deleteSelection() {
        let doomed = flow.cards.filter { selection.cardIDs.contains($0.id) }
        guard mayStop(doomed.filter(isBusy), doing: doomed.count > 1 ? "Delete Cards" : "Delete Card") else { return }
        switch selection {
        case .card(let id): perform("Delete Card") { try $0.removeCard(id) }
        case .link(let id): perform("Delete Link") { try $0.removeLink(id) }
        case .cards(let ids): perform("Delete Cards") { for id in ids { try $0.removeCard(id) } }
        case .none: break
        }
    }

    func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let old = flow
        flow.name = trimmed
        registerUndo(from: old, "Rename Flow")
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try project.store.save(flow, to: fileURL)
        } catch {
            banner = "Couldn't save the flow: \(error.localizedDescription)"
        }
    }

    // MARK: Browsers

    /// The cards of this flow that have been given a tab in the project's browser. The canvas asks for tabs
    /// while it draws, so this is kept out of what it watches: noting a tab here must not make it draw again.
    @ObservationIgnored private var browserCards: Set<String> = []

    /// The browser tab of an agent card whose Browser switch is on, or nil for any other card.
    func browserTab(forCard id: String) -> BrowserTab? {
        guard !isClosed, let card = flow.card(id), card.kind == .agent, card.browser == true else { return nil }
        browserCards.insert(id)
        return project.browser.tab(for: "\(flow.id)/\(id)")
    }

    // MARK: Sessions

    /// The session behind an agent card, or behind the orchestrator for `orchestratorKey`.
    func session(forCard id: String) -> TerminalSession {
        _ = sessionGeneration
        if let existing = sessions[id] { return existing }
        let session = TerminalSession(key: "\(flow.id)/\(id)")
        session.onExit = { [weak self] _ in self?.sessionExited(id) }
        sessions[id] = session
        return session
    }

    var orchestrator: TerminalSession { session(forCard: Self.orchestratorKey) }

    /// The settings changed on a card since its session started, which the running session
    /// doesn't have yet. Empty when the session isn't running or is up to date.
    func settingsAwaitingRestart(forCard id: String) -> [String] {
        guard let card = flow.card(id), let session = sessions[id], session.isLive, let launched = session.launched else { return [] }
        return AgentSettings(card).differences(from: launched)
    }

    /// Puts a card's settings back to what its running session was started with, undoing
    /// whatever has been changed since.
    func revertSettings(forCard id: String) {
        guard let patch = revertPatch(forCard: id) else { return }
        update(id, patch)
    }

    /// The change that puts a card's settings back to what its running session was started with, or nil when
    /// its session isn't running. A paired device's Undo makes it without the folder.
    func revertPatch(forCard id: String) -> CardPatch? {
        guard let session = sessions[id], session.isLive, let launched = session.launched else { return nil }
        var patch = CardPatch()
        patch.name = launched.name
        patch.instructions = launched.instructions
        // An empty string clears these back to "your default".
        patch.model = launched.model
        patch.effort = launched.effort
        patch.permissionMode = launched.permissionMode
        patch.cwd = launched.folder
        patch.browser = launched.browser
        return patch
    }

    private func startMissingSessions() {
        for card in flow.cards where card.kind == .agent && !heldBack.contains(card.id) && session(forCard: card.id).state == .notStarted {
            startSession(forCard: card.id)
        }
        if orchestrator.state == .notStarted { startOrchestrator() }
    }

    /// Starts, or after an exit restarts, the session of one agent card.
    func startSession(forCard id: String) {
        guard let environment = services.environment else { return }
        guard let index = flow.cards.firstIndex(where: { $0.id == id }), flow.cards[index].kind == .agent else { return }
        // Asked for by name, so it is no longer waiting to be.
        heldBack.remove(id)
        // The id ends up on the command line and in a file name, so one from a flow file has to be a real id.
        if flow.cards[index].sessionID.flatMap(UUID.init(uuidString:)) == nil { flow.cards[index].sessionID = UUID().uuidString.lowercased() }
        let folder = ClaudeLauncher.folder(for: flow.cards[index], projectRoot: project.root, workRoot: workRoot)
        let start = ClaudeLauncher.transcriptStart(for: flow.cards[index].sessionID!, in: folder)
        if start == .freshWithNewID {
            // Its conversation was had in another folder, and Claude Code only carries one on in the folder it began in.
            flow.cards[index].sessionID = UUID().uuidString.lowercased()
            append("\(flow.cards[index].name) now works in a different folder, so it starts a new conversation there")
        }
        let card = flow.cards[index]
        // A session with no transcript yet starts with today's instructions, and keeps them for good.
        if start != .resume {
            services.noteBorn(session: card.sessionID!, instructions: ClaudeLauncher.agentPrompt(flow: flow, card: card))
        }
        guard let spec = ClaudeLauncher.agent(flow: flow, card: card, sessionID: card.sessionID!, projectRoot: project.root,
                                              workRoot: workRoot, services: services, environment: environment) else {
            banner = services.problem
            return
        }
        freshSession(for: id).start(spec, settings: AgentSettings(card))
        launchedIn[id] = spec.workingDirectory
    }

    func startOrchestrator() {
        guard let environment = services.environment else { return }
        if flow.orchestratorSessionID.flatMap(UUID.init(uuidString:)) == nil { flow.orchestratorSessionID = UUID().uuidString.lowercased() }
        let start = ClaudeLauncher.transcriptStart(for: flow.orchestratorSessionID!, in: workRoot.path)
        if start == .freshWithNewID {
            // The project folder moved since the orchestrator's conversation began, so it begins a new one here.
            flow.orchestratorSessionID = UUID().uuidString.lowercased()
            append("The orchestrator's earlier conversation was in another folder, so it starts a new one")
        }
        if start != .resume {
            services.noteBorn(session: flow.orchestratorSessionID!, instructions: ClaudeLauncher.orchestratorPrompt(flow: flow))
        }
        guard let spec = ClaudeLauncher.orchestrator(flow: flow, sessionID: flow.orchestratorSessionID!, projectRoot: project.root,
                                                     workRoot: workRoot, services: services, environment: environment) else {
            banner = services.problem
            return
        }
        freshSession(for: Self.orchestratorKey).start(spec, instructions: ClaudeLauncher.orchestratorPrompt(flow: flow))
        launchedIn[Self.orchestratorKey] = spec.workingDirectory
    }

    /// The orchestrator is running with instructions that are no longer the flow's, because the flow was renamed
    /// or became a sub-flow since it started.
    var orchestratorNeedsRestart: Bool {
        guard let session = sessions[Self.orchestratorKey], session.isLive, let launched = session.launchedInstructions else { return false }
        return launched != ClaudeLauncher.orchestratorPrompt(flow: flow)
    }

    /// A terminal that has run a process doesn't take a second one, so a restart gets a new terminal.
    private func freshSession(for id: String) -> TerminalSession {
        if let old = sessions[id], old.state != .notStarted {
            let wasLive = old.isLive
            old.terminate()
            sessions[id] = nil
            sessionGeneration += 1
            // A run waiting on this agent will never hear the reply its old session owed.
            if wasLive, id != Self.orchestratorKey { agentStopped(id, reason: "it was restarted") }
        }
        return session(forCard: id)
    }

    private func sessionExited(_ id: String) {
        guard id != Self.orchestratorKey else { return }
        agentStopped(id, reason: "its session ended")
    }

    /// An agent's session ended, was ended, or its turn failed. That stops the run only if the run is waiting on the
    /// agent: the engine decides. `name` is for a card that has just been deleted.
    private func agentStopped(_ id: String, name: String? = nil, reason: String) {
        guard isRunning, let engine else { return }
        turnRun[id] = nil
        Task {
            let output = await engine.agentFailed(flow: self.flow, cardID: id, name: name, reason: reason)
            if output.finished { self.markFailed(id) }
            self.absorb(output, sender: nil)
        }
    }

    private func readyEngine() -> Engine? {
        if let engine { return engine }
        guard let environment = services.environment, let claude = environment.claude else { return nil }
        let made = Engine(judge: ClaudeJudge(claude: claude, environment: environment.variables()))
        engine = made
        return made
    }

    // MARK: Requests from sessions

    /// A Claude Code hook fired in one of this flow's sessions.
    /// Returns what Claude Code should put in front of the session, if anything.
    @discardableResult
    func handleHook(from who: String, payload: JSONValue) -> JSONValue {
        guard let session = sessions[who] else { return [:] }
        let context = payload["hook_event_name"]?.stringValue == "SessionStart" ? startContext(for: who, session: session, payload: payload) : [:]
        applyHook(from: who, session: session, payload: payload)
        return context
    }

    /// What a session that has just started needs telling. Claude Code keeps a resumed session's first
    /// instructions and ignores the ones it is restarted with, so newer ones are handed over here. The
    /// orchestrator is also pointed at the capabilities reference, which the app has just written out.
    private func startContext(for who: String, session: TerminalSession, payload: JSONValue) -> JSONValue {
        guard let id = session.claudeSessionID else { return [:] }
        let source = payload["source"]?.stringValue ?? ""
        let afresh = source == "clear" || source == "compact"
        var parts: [String] = []
        let instructions = who == Self.orchestratorKey ? ClaudeLauncher.orchestratorPrompt(flow: flow)
            : flow.card(who).map { ClaudeLauncher.agentPrompt(flow: flow, card: $0) }
        if let instructions, services.needsInstructions(session: id, instructions: instructions, afresh: afresh) {
            parts.append("[Queen Bee] Your instructions have changed since this conversation began. These are the current ones. They replace the earlier ones wherever the two differ.\n\n\(instructions)")
        }
        if who == Self.orchestratorKey {
            // The orchestrator reads it in the folder it works in, which may be a worktree.
            let file = workRoot.appendingPathComponent(Capabilities.projectFile)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ignore = file.deletingLastPathComponent().appendingPathComponent(".gitignore")
            if !FileManager.default.fileExists(atPath: ignore.path) { try? Data("*\n".utf8).write(to: ignore) }
            try? Data(Capabilities.file.utf8).write(to: file, options: .atomic)
            if services.referenceChanged(forSession: id, afresh: afresh) {
                parts.append("[Queen Bee] The app's capabilities reference is the file \(Capabilities.projectFile) in this folder. The app has just written it from its own code, and you have not read this version. Read the whole file with the Read tool before you answer or build anything. It replaces what you remember about the app's cards, settings, tools and limits, and anything said about them earlier in this conversation.")
            }
        }
        guard !parts.isEmpty else { return [:] }
        return ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": .string(parts.joined(separator: "\n\n"))]]
    }

    private func applyHook(from who: String, session: TerminalSession, payload: JSONValue) {
        let event = payload["hook_event_name"]?.stringValue ?? ""
        let type = payload["notification_type"]?.stringValue
            ?? ((payload["message"]?.stringValue ?? "").localizedCaseInsensitiveContains("permission") ? "permission_prompt" : nil)
        let wasWaiting = session.state == .needsYou
        session.apply(hook: event, notificationType: type, source: payload["source"]?.stringValue, trigger: payload["trigger"]?.stringValue)
        if session.state == .needsYou, !wasWaiting {
            let name = who == Self.orchestratorKey ? "The orchestrator" : flow.card(who)?.name ?? "An agent"
            Notifier.post(title: "\(name) needs you", body: "In \(flow.name). It is waiting for your answer or your go-ahead.",
                          flowID: flow.id, cardID: who)
        }
        if event == "Stop", let reply = payload["last_assistant_message"]?.stringValue { session.lastReply = reply }
        if event == "Stop" || event == "StopFailure" {
            // The turn's cost reaches the transcript a moment after the hook fires.
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                await self.refreshUsage(who)
            }
        }
        guard who != Self.orchestratorKey else { return }
        switch event {
        case "SessionStart":
            // A summary made mid-conversation keeps the same process, and the plugin it had loaded.
            if payload["source"]?.stringValue != "compact" { pluginSpoke.remove(who) }
        case "UserPromptSubmit":
            // A turn begun by a hand-off works for the run the hand-off came from, which may have ended by the
            // time the turn does.
            turnRun[who] = Engine.runID(inHandOff: payload["prompt"]?.stringValue ?? "")
        case "Stop":
            let reply = payload["last_assistant_message"]?.stringValue ?? ""
            session.lastReply = reply
            routeIfPluginIsSilent(who, reply: reply)
        case "StopFailure":
            agentStopped(who, reason: "its turn ended with an API error")
        default:
            break
        }
    }

    /// The plugin normally reports a finished turn within milliseconds. If it hasn't after a
    /// few seconds it isn't loaded, so the app routes the reply itself and types the hand-offs in.
    private func routeIfPluginIsSilent(_ who: String, reply: String) {
        guard isRunning, !pluginSpoke.contains(who), let engine else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard self.isRunning, !self.pluginSpoke.contains(who) else { return }
            self.append("\(self.flow.card(who)?.name ?? who)'s reply didn't come through the usual way, so Queen Bee passed it on itself")
            let forRun = self.turnRun.removeValue(forKey: who)
            self.absorb(await engine.agentReplied(flow: self.flow, cardID: who, text: reply, forRun: forRun), sender: nil)
        }
    }

    /// An agent's turn ended and its plugin asks where the reply goes. The answer is the
    /// hand-offs for that plugin to send as session messages. `asked` is the plugin saying the
    /// turn got a message through to another session of the flow: the answer to it arrives as
    /// a new turn, so this turn's last words aren't the reply.
    func handleRoute(from who: String, answer: String, asked: Bool = false) async -> [(to: String, text: String)] {
        guard who != Self.orchestratorKey, flow.card(who) != nil else { return [] }
        pluginSpoke.insert(who)
        sessions[who]?.lastReply = answer
        guard let engine = readyEngine() else { return [] }
        // Each turn is routed once, so what is known of the run it worked for goes with it.
        let forRun = turnRun.removeValue(forKey: who)
        return absorb(await engine.agentReplied(flow: flow, cardID: who, text: answer, waitingOnAnswer: asked, forRun: forRun), sender: who)
    }

    /// The plugin reports how its sends went. A hand-off that didn't arrive is typed in.
    func handleSent(from who: String, results: [JSONValue]) {
        for result in results {
            guard let to = result["to"]?.stringValue, let delivery = inFlight.removeValue(forKey: to) else { continue }
            if result["isDelivered"]?.boolValue == false {
                let name = flow.card(delivery.toCardID)?.name ?? delivery.toCardID
                append("Couldn't message \(name) directly (\(result["reason"]?.stringValue ?? "no reason given")), so the message was typed into its terminal")
                session(forCard: delivery.toCardID).send(delivery.text)
            }
        }
    }

    /// What to do with a SendMessage from one of this flow's sessions.
    struct SendVerdict {
        var refusal: String?
        /// Whether the recipient is the orchestrator or an agent of this flow.
        var inFlow = false
        /// The exact session to deliver to, when the recipient is part of this flow.
        var sessionID: String?
    }

    /// Decides a SendMessage a session's model is making. A recipient named like one of this
    /// flow's cards is that card, whatever other sessions on the machine share the name, so
    /// the answer carries the card's session id. An agent may only message agents its card is
    /// linked to, and the orchestrator. The orchestrator may message any agent.
    func judgeSend(from who: String, to: String) -> SendVerdict {
        let address = to.lowercased()
        if who != Self.orchestratorKey, address.hasPrefix(ClaudeLauncher.orchestratorName(for: flow).lowercased()) {
            return SendVerdict(inFlow: true, sessionID: flow.orchestratorSessionID)
        }
        let target = flow.cards
            .filter { card in
                guard card.kind == .agent, card.id != who else { return false }
                if let sid = card.sessionID, address.contains(sid) { return true }
                let name = card.name.lowercased()
                return address == name || address.hasPrefix(name + "-") || address.hasPrefix(name + " ")
            }
            .max { $0.name.count < $1.name.count }
        // Not one of this flow's sessions: Claude Code decides.
        guard let target else { return SendVerdict() }
        if who != Self.orchestratorKey, let sender = flow.card(who), !linkedAgents(of: who).contains(target.id) {
            return SendVerdict(refusal: "\(sender.name) isn't linked to \(target.name) in the flow \"\(flow.name)\". Ask the person or the orchestrator to link the two cards first.")
        }
        return SendVerdict(inFlow: who != Self.orchestratorKey, sessionID: target.sessionID)
    }

    /// The run hangs on agents that asked a question and have had no answer. The log says so at
    /// once. If it is still so after a while, the person and the orchestrator are told.
    private func noteStalled(on cards: [String]) {
        let names = cards.compactMap { flow.card($0)?.name }.joined(separator: ", ")
        guard !names.isEmpty else { return }
        append("The run is waiting on \(names): a question it asked hasn't been answered, and nothing else is under way")
        stallNotice?.cancel()
        stallNotice = Task {
            try? await Task.sleep(for: Self.unansweredAfter)
            // Cancelled as soon as the run moves again or ends.
            guard !Task.isCancelled, self.isRunning else { return }
            Notifier.post(title: "\(self.flow.name) is waiting on \(names)", body: "It asked a question and hasn't had an answer. Answer it in its terminal, or stop the run.",
                          flowID: self.flow.id, cardID: cards.first)
            // An orchestrator in the middle of a turn is most likely writing the answer.
            guard self.flow.notifyOrchestrator, self.orchestrator.isLive, self.orchestrator.state == .idle else { return }
            self.orchestrator.send("[Queen Bee · notice] The run is stalled. \(names) asked a question, has had no answer, and nothing else is under way. Answer with SendMessage, or stop the run. This is information from the app, not a new request.")
        }
    }

    /// The agents a card reaches, or is reached by, through logic cards alone.
    private func linkedAgents(of id: String) -> Set<String> {
        var found = Set<String>()
        for forward in [true, false] {
            var seen: Set<String> = [id]
            var stack = [id]
            while let at = stack.popLast() {
                let next = flow.links.filter { forward ? $0.from == at : $0.to == at }.map { forward ? $0.to : $0.from }
                for n in next where !seen.contains(n) {
                    seen.insert(n)
                    guard let card = flow.card(n) else { continue }
                    if card.kind == .agent { found.insert(n) } else { stack.append(n) }
                }
            }
        }
        return found
    }

    // MARK: Runs

    /// What asking for a run came to: whether one began, and the line that says so or says why not.
    struct RunStart {
        var began: Bool
        var status: String
        /// The run that began.
        var runID: String?
    }

    @discardableResult
    func run(command: String? = nil, startCardID: String? = nil, levelsLeft given: Int? = nil) async -> String {
        await start(command: command, startCardID: startCardID, levelsLeft: given).status
    }

    /// `note` is a line for the run's log saying who started it, when that wasn't the person at this Mac.
    /// `inside` is the flows a Flow card's run of this one is inside.
    func start(command: String? = nil, startCardID: String? = nil, levelsLeft given: Int? = nil, inside: Set<String> = [],
               note: String? = nil) async -> RunStart {
        guard let engine = readyEngine() else { return RunStart(began: false, status: services.problem ?? "Claude Code isn't ready yet.") }
        runsStarting += 1
        defer {
            runsStarting -= 1
            subflowTurns.somethingEnded()
        }
        // A run only begins where the flow is set to work. The branch or worktree can have changed since it opened.
        if !isRunning, let refusal = await prepareWorkplace() { return RunStart(began: false, status: refusal) }
        isClosed = false
        // Run directly, a flow goes by its own place under the flow at the top. Run by a Flow
        // card, it is handed what is left of the run's allowance.
        if !isRunning {
            runLevelsLeft = given ?? levelsLeft
            runInside = inside
        }
        // With several Start cards, the one that is selected is the one meant.
        var startCardID = startCardID
        if startCardID == nil, case .card(let id) = selection, flow.card(id)?.kind == .start { startCardID = id }
        let output = await engine.start(flow: flow, startCardID: startCardID, command: command)
        // Only a run that actually began clears the last one off the canvas.
        var began = false
        if let id = output.runID, !isRunning {
            began = true
            clearForRun()
            let first = command ?? (startCardID.flatMap { flow.card($0) } ?? flow.cards.first { $0.kind == .start })?.command ?? ""
            currentRun = (id, Date(), String(first.prefix(200)))
            if let note { append(note, kept: true) }
        }
        absorb(output, sender: nil)
        return RunStart(began: began, status: output.log.last ?? (output.runID.map { "Run \($0) started" } ?? "Nothing to run"),
                        runID: began ? output.runID : nil)
    }

    /// Starts a run part-way through: `message` arrives at the card as if a link had brought it.
    @discardableResult
    func run(from cardID: String, message: String, sender: String = "You") async -> String {
        await start(from: cardID, message: message, sender: sender).status
    }

    func start(from cardID: String, message: String, sender: String = "You", note: String? = nil) async -> RunStart {
        guard let engine = readyEngine() else { return RunStart(began: false, status: services.problem ?? "Claude Code isn't ready yet.") }
        guard !isRunning else {
            banner = "A run is already going. Stop it before starting another."
            return RunStart(began: false, status: banner ?? "")
        }
        runsStarting += 1
        defer {
            runsStarting -= 1
            subflowTurns.somethingEnded()
        }
        if let refusal = await prepareWorkplace() { return RunStart(began: false, status: refusal) }
        guard !isRunning else {
            banner = "A run is already going. Stop it before starting another."
            return RunStart(began: false, status: banner ?? "")
        }
        isClosed = false
        runLevelsLeft = levelsLeft
        runInside = []
        let output = await engine.start(flow: flow, at: cardID, message: message, fromName: sender)
        if let id = output.runID {
            clearForRun()
            currentRun = (id, Date(), "From \(flow.card(cardID)?.name ?? "a card"): \(message.prefix(160))")
            if let note { append(note, kept: true) }
        }
        absorb(output, sender: nil)
        return RunStart(began: output.runID != nil, status: output.log.last ?? "Nothing to run", runID: output.runID)
    }

    /// Whether Retry is offered on a card: the last run stopped there, and a message reached it.
    func canRetry(_ cardID: String) -> Bool {
        marks[cardID]?.failed == true && !isRunning && lastMessage(into: cardID) != nil
    }

    /// Tries the card a run stopped at again, with the message it was given.
    func retry(_ cardID: String) {
        guard let last = lastMessage(into: cardID) else {
            banner = "There is no message to give this card again."
            return
        }
        Task { await run(from: cardID, message: last.text, sender: last.from) }
    }

    func stop() async {
        guard let engine else { return }
        absorb(await engine.stop(), sender: nil)
    }

    /// Takes in what the engine decided: logs it, shows End results, and delivers hand-offs.
    /// With `sender` set, that agent's plugin sends the hand-offs as session messages and they
    /// are returned for it; hand-offs it can't send that way are typed into the target's terminal.
    @discardableResult
    private func absorb(_ output: RunOutput, sender: String?) -> [(to: String, text: String)] {
        guard !isClosed else { return [] }
        output.log.forEach { append($0) }
        record(output.visits, sender: sender)
        handOffs += output.deliveries.count
        for result in output.results {
            results[result.cardID] = result.text
            if let file = result.saveTo, !file.isEmpty { save(result.text, to: file, card: result.cardName) }
        }
        var forPlugin: [(to: String, text: String)] = []
        // A run that has ended hands nothing more to anyone.
        for delivery in output.finished ? [] : output.deliveries {
            let target = session(forCard: delivery.toCardID)
            if !target.isLive { startSession(forCard: delivery.toCardID) }
            let live = session(forCard: delivery.toCardID)
            let settled = live.state == .idle || live.state == .working || live.state == .needsYou
            // A session can't message itself, so a hand-off that loops straight back to the
            // agent that just replied is typed in.
            if let sender, sender != delivery.toCardID, settled, let sid = live.claudeSessionID {
                forPlugin.append((sid, delivery.text))
                inFlight[sid] = delivery
            } else {
                live.send(delivery.text)
            }
        }
        for travel in output.travels {
            CarriedMessages.add(travel.text, from: travel.fromName, at: Date(), link: travel.linkID, to: &messages, whole: &wholeMessages)
        }
        // Agents still working on a run that has ended stop, so they spend nothing more on it.
        for id in output.leftWaiting {
            sessions[id]?.interrupt()
            turnRun[id] = nil
        }
        output.holds.forEach(take)
        if let asking = output.asking {
            awaitingAnswer = Set(asking)
            if !output.isStalled { stallNotice?.cancel() }
        }
        if !output.stalledOn.isEmpty { noteStalled(on: output.stalledOn) }
        scheduleHistorySave()
        if output.finished {
            awaitingAnswer.removeAll()
            stallNotice?.cancel()
            isRunning = false
            liveLinks.removeAll()
            // Whatever was waiting belonged to the run that has ended.
            holdTasks.values.forEach { $0.cancel() }
            holdTasks.removeAll()
            holdClocks.removeAll()
            holds.removeAll()
            lastRunEnded = Date()
            finishRecord(output)
            subflowTurns.somethingEnded()
            notifyOrchestrator(of: output)
            let stopped = marks.values.contains(where: \.failed)
            Notifier.post(title: "\(flow.name) \(stopped ? "stopped" : (output.ending ?? .finishedWithAnswer).label)",
                          body: log.last?.text ?? "", flowID: flow.id, cardID: nil)
        } else if output.runID != nil {
            isRunning = true
        }
        return forPlugin
    }

    // MARK: Approval, Script and Flow cards

    /// A message has stopped at an Approval or a Script card.
    private func take(_ hold: Hold) {
        guard let card = flow.card(hold.cardID) else {
            // The card went while the message was on its way. Tell the engine, or the run never ends.
            if let engine { Task { self.absorb(await engine.holdResolved(flow: self.flow, holdID: hold.id, port: "fail", text: nil), sender: nil) } }
            return
        }
        var pending = PendingHold(id: hold.id, cardID: hold.cardID, kind: hold.kind, text: hold.text, from: hold.fromName)
        if hold.kind == .script {
            pending.command = card.command ?? ""
            pending.needsAllow = !ScriptRunner.isAllowed(pending.command, scope: allowScope, cardID: card.id)
            if pending.needsAllow, isFromDevice(pending.command, cardID: card.id) { pending.allowOnMac = true }
        }
        if hold.kind == .flow {
            let inner = innerFlow(of: card)
            pending.command = inner?.flow.name ?? ""
            holds.append(pending)
            return runInnerFlow(pending, inner)
        }
        if let wait = HoldTimeLimit.wait(for: card), pending.kind == .approval || pending.needsAllow {
            let lasts = TestHarness.holdWait(wait)
            pending.deadline = Date().addingTimeInterval(Self.seconds(lasts))
            holdClocks[pending.id] = (Date(), wait)
            answerIfUnanswered(pending.id, after: wait, lasting: lasts)
        }
        holds.append(pending)
        if pending.kind == .approval {
            Notifier.post(title: "\(card.name) needs your approval", body: String(hold.text.prefix(200)), flowID: flow.id, cardID: card.id)
        } else if pending.needsAllow {
            append("\(card.name) is waiting for you to let its command run")
            Notifier.post(title: "\(card.name) needs you", body: "It wants to run a command you haven't seen: \(pending.command.prefix(160))", flowID: flow.id, cardID: card.id)
        } else {
            runScript(pending)
        }
    }

    /// A card with a time limit answers for the person once it is up, through the same path as their own answer. The
    /// timer goes when the hold is answered or the run ends; a device showing the hold changes nothing. The clock keeps
    /// counting while the Mac sleeps, so a deadline that passed then is met when it wakes. `lasts` is how long it
    /// really waits, which is `wait` everywhere but a test copy told to count minutes as seconds.
    private func answerIfUnanswered(_ id: String, after wait: Duration, lasting lasts: Duration) {
        holdTasks[id] = Task {
            try? await Task.sleep(for: lasts, clock: .continuous)
            guard !Task.isCancelled, let hold = self.holds.first(where: { $0.id == id }),
                  hold.kind == .approval || hold.needsAllow, var card = self.flow.card(hold.cardID) else { return }
            self.holdTasks[id] = nil
            self.holdClocks[id] = nil
            // The person may have taken the limit off while it waited. Otherwise the answer is the one the card gives
            // now, after as long as it was given.
            guard HoldTimeLimit.wait(for: card) != nil else {
                if let index = self.holds.firstIndex(where: { $0.id == id }) { self.holds[index].deadline = nil }
                return
            }
            card.waitMinutes = Int(wait.components.seconds / 60)
            self.append("\(card.name): \(HoldTimeLimit.line(for: card))")
            let port = HoldTimeLimit.port(for: card)
            self.resolve(id, port: port, text: port == "fail" ? "Nobody let the command run in time, so it was skipped." : nil)
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// A waiting card's time limit was changed: its clock now runs to the new limit, counted from when it began
    /// waiting, and one past it already answers. A limit taken off stops the clock, and one put on starts it now.
    private func retimeHolds() {
        for hold in holds where hold.kind == .approval || hold.needsAllow {
            guard let card = flow.card(hold.cardID) else { continue }
            let wait = HoldTimeLimit.wait(for: card)
            let clock = holdClocks[hold.id]
            guard wait != clock?.wait else { continue }
            holdTasks.removeValue(forKey: hold.id)?.cancel()
            guard let index = holds.firstIndex(where: { $0.id == hold.id }) else { continue }
            guard let wait else {
                holdClocks[hold.id] = nil
                holds[index].deadline = nil
                continue
            }
            let began = clock?.began ?? Date()
            let deadline = began.addingTimeInterval(Self.seconds(TestHarness.holdWait(wait)))
            holdClocks[hold.id] = (began, wait)
            holds[index].deadline = deadline
            answerIfUnanswered(hold.id, after: wait, lasting: .milliseconds(Int(max(deadline.timeIntervalSinceNow, 0) * 1000)))
        }
    }

    /// A Flow card: runs another flow of the project with the message as its command, and
    /// passes that flow's final answer on.
    private func runInnerFlow(_ hold: PendingHold, _ inner: FlowController?) {
        guard let inner, inner !== self else {
            return resolve(hold.id, port: "fail", text: "The flow this card runs is no longer in the project.")
        }
        // Whatever a flow's file says, a run never goes deeper than the flow at the top allows, and never into a
        // flow it is already inside, which would wait on itself for ever.
        let inside = runInside.union([flow.id])
        if let refusal = subflowRefusal(running: inner.flow.id, named: inner.flow.name, levelsLeft: runLevelsLeft, inside: inside) {
            return resolve(hold.id, port: "fail", text: refusal)
        }
        let levels = runLevelsLeft - 1
        if inner.isRunning || inner.isStartingRun || inner.subflowTurns.isTaken {
            append("\(inner.flow.name) is already running, so \(flow.card(hold.cardID)?.name ?? "the Flow card") waits for that run to end")
        }
        holdTasks[hold.id] = Task {
            // Cancelling this stops the inner run, if it has begun: see `runToEnd`.
            let answer = await inner.runToEnd(command: hold.text, levelsLeft: levels, inside: inside)
            guard !Task.isCancelled else { return }
            self.holdTasks[hold.id] = nil
            self.resolve(hold.id, port: answer.finished ? "done" : "fail", text: answer.text)
        }
    }

    // MARK: How deep sub-flows go

    /// The limit set on this flow, for when it is the flow at the top.
    var ownSubflowLimit: Int { Nesting.clamped(flow.subflowLimit) }

    /// Sets how many levels of sub-flow may sit below this flow.
    func setSubflowLimit(_ levels: Int) {
        let wanted = Nesting.clamped(levels)
        guard wanted != ownSubflowLimit else { return }
        let old = flow
        flow.subflowLimit = wanted == Nesting.usualLimit ? nil : wanted
        registerUndo(from: old, "Change Sub-flow Limit", key: "limit")
    }

    /// The most one run may spend, in dollars, or nil for no limit.
    func setSpendingLimit(_ dollars: Double?) {
        let wanted = SpendingLimit.clamped(dollars)
        guard wanted != flow.spendingLimit else { return }
        let old = flow
        flow.spendingLimit = wanted
        registerUndo(from: old, wanted == nil ? "Remove Spending Limit" : "Change Spending Limit", key: "spending")
    }

    func setNotifiesOrchestrator(_ on: Bool) {
        guard flow.notifyOrchestrator != on else { return }
        let old = flow
        flow.notifyOrchestrator = on
        registerUndo(from: old, on ? "Tell Orchestrator of Runs" : "Stop Telling Orchestrator of Runs")
    }

    // MARK: Where the flow works

    /// The setting the flow works by, and the flow at the top it comes from when it isn't its own: a flow that
    /// another flow runs works wherever that one does.
    var workplaceSetting: (workplace: Workplace?, from: FlowController?) {
        let found = Workplace.effective(for: flow.id, in: project.controllers.map(\.flow), nesting: nesting)
        return (found.workplace, found.from.flatMap(project.controller))
    }

    /// True for a flow another flow runs, which can't choose a place of its own.
    var inheritsWorkplace: Bool { !nesting.outerFlows(of: flow.id).isEmpty }

    /// The words of the title bar's chip, or nil outside a git repository: where the flow works now, which
    /// is not what it is set to while a switch is refused.
    var workplaceChip: String? {
        guard let git else { return nil }
        let setting = workplaceSetting.workplace
        return Workplace.chipText(workRoot: workRoot, projectRoot: project.root, current: git.current, worktrees: git.worktrees,
                                  expected: setting?.kind == .worktree ? setting?.branch : nil)
    }

    /// Asked once, when a flow at the top of its chain first opens in a repository with no place chosen.
    private var shouldAskForWorkplace: Bool {
        git != nil && flow.workplace == nil && !inheritsWorkplace && !workplaceDeferred && !TestHarness.isEnabled
    }

    /// Reads the repository again, for the chip's popover.
    func refreshGit() async {
        git = await Git.info(at: project.root)
    }

    /// The answer to the first-run question. Nil is "Not now": the flow works in the project folder as it is,
    /// and is asked again the next time the app opens.
    func answerWorkplaceQuestion(_ chosen: Workplace?) async {
        asksForWorkplace = false
        if let chosen {
            await setWorkplace(chosen)
        } else {
            workplaceDeferred = true
            await prepareWorkplace()
        }
        guard isOpen else { return }
        startMissingSessions()
        await refreshUsage()
    }

    /// Chooses where the whole flow works, and moves its sessions there. Not while it runs, and not for a
    /// flow another flow runs: that one goes by the flow at the top.
    func setWorkplace(_ wanted: Workplace) async {
        guard !inheritsWorkplace else {
            banner = "\(flow.name) works wherever the flow that runs it does. Change it there."
            return
        }
        guard !isRunning, !isStartingRun else {
            banner = "Stop the run before changing where the flow works."
            return
        }
        if let branch = wanted.branch, let problem = Workplace.problem(branchName: branch) {
            banner = problem
            return
        }
        let busy = flow.cards.filter(isBusy)
        if !busy.isEmpty, !TestHarness.isEnabled {
            let names = busy.map(\.name).joined(separator: ", ")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Move the flow and stop \(names)?"
            alert.informativeText = "Agents in the middle of a task are restarted in the new place, and the work they were doing is cut short."
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let old = flow.workplace
        flow.workplace = wanted
        if let refusal = await prepareWorkplace() {
            // Nothing moved, so the setting goes back to what it was.
            flow.workplace = old
            banner = refusal
            return
        }
        banner = nil
        append(wanted.summary(project: project.name, current: git?.current), kept: true)
        // The flows this one runs work where it does.
        for inner in nesting.subflows(of: flow.id).compactMap({ project.controller($0.id) }) where inner.isOpen && !inner.isRunning {
            await inner.prepareWorkplace()
        }
    }

    /// Gets the flow's place ready: the project folder switched to its branch, or its worktree found or made.
    /// Sessions started somewhere else are moved there. Nil when it is ready, else why not, which is also put
    /// in the banner and the log.
    @discardableResult
    func prepareWorkplace() async -> String? {
        if let preparing { return await preparing.value }
        let task = Task { await self.readyWorkplace() }
        preparing = task
        defer { preparing = nil }
        let refusal = await task.value
        if refusal == nil {
            if let workplaceRefusal, banner == workplaceRefusal { banner = nil }
            workplaceRefusal = nil
        }
        return refusal
    }

    private func readyWorkplace() async -> String? {
        let root = project.root
        guard let info = await Git.info(at: root) else {
            git = nil
            return move(to: root)
        }
        git = info
        let setting = workplaceSetting.workplace ?? .asItIs
        switch setting.kind {
        case .folder:
            guard let branch = setting.branch, branch != info.current else { return move(to: root) }
            if let problem = Workplace.problem(branchName: branch) { return refuse("The flow's branch can't be used: \(problem)") }
            guard info.branches.contains(branch) else {
                return refuse("\(branch) isn't a branch of \(project.name) any more. Choose another in the title bar.")
            }
            if let other = project.controllers.first(where: { $0 !== self && ($0.isRunning || $0.isStartingRun) && $0.workRoot == root }) {
                return refuse("\(project.name) can't be switched to \(branch) while \(other.flow.name) is running in it.")
            }
            if await Git.hasUncommittedChanges(at: root) {
                return refuse("\(project.name) has changes that aren't committed, so it isn't switched to \(branch). Commit or stash them, or have the flow work in a worktree.")
            }
            if let error = await Git.switchBranch(to: branch, at: root) { return refuse("\(project.name) couldn't be switched to \(branch): \(error)") }
            append("Switched \(project.name) to \(branch)", kept: true)
            git = await Git.info(at: root) ?? info
            return move(to: root)
        case .worktree:
            guard let branch = setting.branch, Workplace.problem(branchName: branch) == nil else {
                return refuse("The flow's worktree has no branch git allows. Choose one in the title bar.")
            }
            let base = setting.base ?? info.defaultBranch
            let plan = Workplace.worktreePlan(branch: branch, base: base, root: root, worktrees: info.worktrees, branches: info.branches)
            if case .create = plan {
                guard Workplace.problem(branchName: base) == nil, info.branches.contains(base) else {
                    return refuse("A worktree on \(branch) is made from \(base), which isn't a branch of \(project.name). Choose another in the title bar.")
                }
            }
            if let error = await Git.make(plan, at: root) { return refuse("The worktree on \(branch) couldn't be made: \(error)") }
            if plan.gitArguments != nil {
                append("Made a worktree on \(branch) for the flow", kept: true)
                git = await Git.info(at: root) ?? info
            }
            return move(to: URL(fileURLWithPath: plan.path, isDirectory: true))
        }
    }

    private func refuse(_ why: String) -> String {
        banner = why
        workplaceRefusal = why
        append(why, kept: true)
        return why
    }

    /// Makes `target` where the flow works, and restarts every live session that was started somewhere else.
    private func move(to target: URL) -> String? {
        workRoot = target
        guard services.environment != nil else { return nil }
        for (key, folder) in launchedIn where sessions[key]?.isLive == true {
            if key == Self.orchestratorKey {
                if folder != workRoot.path { startOrchestrator() }
            } else if let card = flow.card(key), ClaudeLauncher.folder(for: card, projectRoot: project.root, workRoot: workRoot) != folder {
                startSession(forCard: key)
            }
        }
        return nil
    }

    /// How the project's flows nest, as of now. Built on each call, so work that asks several
    /// questions at once should take one and keep it.
    var nesting: Nesting { project.nesting }

    /// How many levels of sub-flow sit below this one.
    var levelsBelow: Int { nesting.levelsBelow(flow.id) }

    /// How many more levels of sub-flow may sit below this flow. Below zero means this flow
    /// is itself past the limit of the flow at its top.
    var levelsLeft: Int { nesting.levelsLeft(flow.id) }

    /// The flows at the top of every chain that leads down to this one. A flow nothing runs is its own.
    var topFlows: [FlowController] { nesting.topFlows(of: flow.id).compactMap(project.controller) }

    /// Why a Flow card in this flow can't run `inner`, or nil if it can.
    func nestingProblem(placing inner: FlowController) -> String? {
        nesting.problem(placing: inner.flow.id, in: flow.id)
    }

    /// Why this flow can't be given another sub-flow of its own, or nil if it can.
    var newSubflowProblem: String? { nesting.problemAddingSubflow(to: flow.id) }

    /// The flow a Flow card runs: found by id, or by name when the orchestrator set it.
    func innerFlow(of card: Card) -> FlowController? {
        guard card.kind == .flow else { return nil }
        return Nesting.resolve(card.flowRef, in: project.controllers.map(\.flow), excluding: flow.id).flatMap(project.controller)
    }

    /// Goes into the flow a Flow card runs. A card with no flow yet gets a new sub-flow of its
    /// own, with an Input and an Output ready to build between.
    func openSubflow(forCard id: String) {
        guard let card = flow.card(id), card.kind == .flow else { return }
        if let inner = innerFlow(of: card) {
            services.enter(inner, from: self)
            return inner.showWholeFlowSoon()
        }
        if let problem = newSubflowProblem {
            banner = problem
            return
        }
        guard let made = project.newSubflow(named: card.name) else {
            banner = "Couldn't make a sub-flow for \(card.name)."
            return
        }
        var patch = CardPatch()
        patch.flowRef = made.flow.id
        update(id, patch)
        services.enter(made, from: self)
        made.showWholeFlowSoon()
    }

    /// Once the flow's canvas is on screen, brings all of it into view at no more than full size.
    func showWholeFlowSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            self.canvas?.zoomToFit(atMost: 1)
        }
    }

    /// Whether Run has anything to start: a Start card with a command and something linked from it.
    var canRun: Bool {
        flow.cards.contains { card in
            card.kind == .start && !(card.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !flow.links(from: card.id).isEmpty
        }
    }

    /// The Start cards a run could begin at, for choosing between them.
    var startCards: [Card] { flow.cards.filter { $0.kind == .start } }

    /// Runs the flow for a Flow card and waits for the run to end. The answer is what reached its End cards.
    /// A flow has one run at a time: this waits its turn behind other Flow cards running it, and behind a run
    /// started some other way. Cancelling it gives up its place, or stops the run it began.
    func runToEnd(command: String, levelsLeft: Int, inside: Set<String>) async -> (finished: Bool, text: String) {
        guard await subflowTurns.take(whenFree: { !self.isRunning && !self.isStartingRun }) else { return (false, "The run was stopped.") }
        defer { subflowTurns.release() }
        let started = await start(command: command, levelsLeft: levelsLeft, inside: inside)
        guard started.began, let id = started.runID else { return (false, started.status) }
        let ended = await withTaskCancellationHandler {
            await runEnded(id)
        } onCancel: {
            Task { @MainActor in if self.currentRun?.id == id { await self.stop() } }
        }
        if Task.isCancelled { return (false, "The run was stopped.") }
        guard let record = ended else { return (false, "\(flow.name) was closed before its run ended.") }
        let answers = flow.cards.filter { $0.kind == .end }.compactMap { record.results[$0.id] }
        // A run that ended without anything reaching an Output has no answer to hand back.
        guard record.outcome == .finished, !answers.isEmpty else {
            return (false, answers.isEmpty ? "\(flow.name) ended without an answer reaching its Output. \(record.log.last?.text ?? "")" : answers.joined(separator: "\n\n"))
        }
        return (true, answers.joined(separator: "\n\n"))
    }

    /// The record of a run of this flow, once it has ended. Nil if the flow is closed first.
    func runEnded(_ id: String) async -> RunRecord? {
        guard currentRun?.id == id else { return runs.last { $0.id == id } }
        return await withCheckedContinuation { endWaiters[id, default: []].append($0) }
    }

    /// What reached the flow's End cards in a run, in canvas order.
    func answers(in record: RunRecord) -> [String] {
        flow.cards.filter { $0.kind == .end }.compactMap { record.results[$0.id] }
    }

    /// Lays the flow out left to right in the order its links run, then shows all of it.
    func tidy() {
        let changed = perform("Tidy Up") { flow in
            for (id, point) in Tidy.layout(flow) {
                guard let index = flow.cards.firstIndex(where: { $0.id == id }) else { continue }
                flow.cards[index].x = point.x
                flow.cards[index].y = point.y
            }
        }
        if changed { canvas?.zoomToFit() }
    }

    // MARK: Groups

    /// The group whose cards are exactly what is selected.
    var selectedGroup: CardGroup? {
        let ids = selection.cardIDs
        return (flow.groups ?? []).first { Set($0.cardIDs) == ids }
    }

    func groupSelection() {
        let ids = selection.cardIDs
        guard ids.count >= 2 else { return }
        perform("Group") { try $0.addGroup(cardIDs: Array(ids)) }
    }

    func ungroupSelection() {
        guard let group = selectedGroup else { return }
        perform("Ungroup") { $0.removeGroup(group.id) }
    }

    func rename(group id: String, to name: String) {
        perform("Rename Group", key: "group:\(id)") { try $0.updateGroup(id, name: name) }
    }

    func setFolded(_ folded: Bool, group id: String) {
        perform(folded ? "Fold Group" : "Unfold Group") { try $0.updateGroup(id, isFolded: folded) }
    }

    /// Selects a group's cards and says where each is, for a drag that moves the group.
    func dragOrigins(forGroup id: String) -> [String: CGPoint] {
        guard let group = (flow.groups ?? []).first(where: { $0.id == id }) else { return [:] }
        var origins: [String: CGPoint] = [:]
        for card in flow.cards where group.cardIDs.contains(card.id) { origins[card.id] = CGPoint(x: card.x, y: card.y) }
        return origins
    }

    private func runScript(_ hold: PendingHold) {
        guard let environment = services.environment else { return resolve(hold.id, port: "fail", text: "Queen Bee was still starting up.") }
        let folder = workRoot
        holdTasks[hold.id] = Task {
            let result = await ScriptRunner.run(hold.command, message: hold.text, from: hold.from, in: folder, environment: environment)
            guard !Task.isCancelled else { return }
            self.holdTasks[hold.id] = nil
            self.resolve(hold.id, port: result.passed ? "pass" : "fail", text: result.output)
        }
    }

    /// Answers a hold and lets the run carry on from its card.
    /// `byPerson` is for an answer the person gave, which is timed so a slow one shows in the log.
    private func resolve(_ id: String, port: String, text: String?, byPerson: Bool = false) {
        guard holds.contains(where: { $0.id == id }), let engine else { return }
        holds.removeAll { $0.id == id }
        // An answer in time stops the clock on it.
        holdTasks.removeValue(forKey: id)?.cancel()
        holdClocks[id] = nil
        let answered = Date()
        Task {
            self.absorb(await engine.holdResolved(flow: self.flow, holdID: id, port: port, text: text), sender: nil)
            // Normally instant. It is slow when the engine was busy with another event, or a
            // condition on the way took a while to judge.
            let took = Date().timeIntervalSince(answered)
            if byPerson, took > 2 { self.append("Acting on that answer took \(Int(took.rounded())) seconds") }
        }
    }

    /// The person approved a held message, perhaps after editing it.
    func approve(_ id: String, text: String) {
        guard holds.first(where: { $0.id == id })?.kind == .approval else { return }
        resolve(id, port: "approved", text: text, byPerson: true)
    }

    /// The person turned a held message down. A note saying why goes out ahead of the message.
    func reject(_ id: String, note: String = "") {
        guard let hold = holds.first(where: { $0.id == id }), hold.kind == .approval else { return }
        resolve(id, port: "rejected", text: Hold.rejection(note: note, of: hold.text), byPerson: true)
    }

    /// The person read a script's command and let it run. It is remembered for this card.
    ///
    /// This is the Mac's own Allow. A paired device's goes through `allowScript(_:fromDevice:)`, which
    /// never gets this far for a command a device wrote.
    func allowScript(_ id: String) {
        guard let index = holds.firstIndex(where: { $0.id == id }), holds[index].kind == .script, holds[index].needsAllow else { return }
        ScriptRunner.allow(holds[index].command, scope: allowScope, cardID: holds[index].cardID)
        // Allowed at this Mac, so the command is the person's own from here on.
        if isFromDevice(holds[index].command, cardID: holds[index].cardID) {
            ConsentStore.scriptsFromDevices.grant(nil, scope: allowScope, cardID: holds[index].cardID)
        }
        holds[index].allowOnMac = nil
        holds[index].needsAllow = false
        // Allowed in time: the command runs, and nothing skips it now.
        holdTasks.removeValue(forKey: id)?.cancel()
        holdClocks[id] = nil
        holds[index].deadline = nil
        runScript(holds[index])
    }

    func refuseScript(_ id: String) {
        guard holds.first(where: { $0.id == id })?.kind == .script else { return }
        resolve(id, port: "fail", text: "You chose not to run the command.")
    }

    /// The person typed a Script card's command, which also allows it: they wrote it.
    func setScriptCommand(_ id: String, _ command: String) {
        var patch = CardPatch()
        patch.command = command
        update(id, patch)
        if flow.card(id)?.command == command {
            ScriptRunner.allow(command, scope: allowScope, cardID: id)
            // Typed here, so it is no longer a command a device wrote.
            ConsentStore.scriptsFromDevices.grant(nil, scope: allowScope, cardID: id)
        }
    }

    /// Whether this is the command a paired device last wrote into that Script card, or brought back to it.
    func isFromDevice(_ command: String, cardID: String) -> Bool {
        ConsentStore.scriptsFromDevices.isGranted(command, scope: allowScope, cardID: cardID)
    }

    /// A paired device's Allow. A command that came in a flow file, or that the orchestrator or the person
    /// at this Mac put there, can be allowed from a device the person has let control this Mac. A command a
    /// device wrote can't: the device would be agreeing to its own change, with nobody at the Mac having
    /// read it. Returns nil when the command was allowed, or why not, in words the device shows.
    func allowScript(_ id: String, fromDevice device: String) -> String? {
        guard let hold = holds.first(where: { $0.id == id }), hold.kind == .script else { return "That is no longer waiting for an answer." }
        guard hold.needsAllow else { return "That command has already been allowed." }
        // Asked of what is kept now, not of what the hold said when it was made.
        guard hold.allowOnMac != true, !isFromDevice(hold.command, cardID: hold.cardID) else { return Remote.allowOnMacRefusal }
        append("\(device) allowed \(flow.card(hold.cardID).map { Remote.logName($0.name, or: "a card") } ?? "a card")'s command", kept: true)
        allowScript(id)
        return nil
    }

    /// Adds what an event did to the per-card tallies. The links an event travelled stay live
    /// until the agents they led to have answered.
    private func record(_ visits: [CardVisit], sender: String?) {
        if let sender { liveLinks[sender] = nil }
        let travelled = Set(visits.compactMap(\.viaLinkID))
        for visit in visits {
            var mark = marks[visit.cardID] ?? RunMark()
            if let link = visit.viaLinkID {
                linkPasses[link, default: 0] += 1
                mark.arrivals += 1
            }
            // An agent's own reply: whatever was on its way to it has arrived and been dealt with.
            if visit.viaLinkID == nil { liveLinks[visit.cardID] = nil }
            if let port = visit.port {
                mark.passes += 1
                mark.ports[port, default: 0] += 1
                mark.lastPort = port
                mark.holding = 0
            } else if visit.viaLinkID != nil {
                mark.holding += 1
                if flow.card(visit.cardID)?.kind == .agent { liveLinks[visit.cardID, default: []].formUnion(travelled) }
            }
            marks[visit.cardID] = mark
        }
    }

    private func markFailed(_ cardID: String) {
        var mark = marks[cardID] ?? RunMark()
        mark.failed = true
        marks[cardID] = mark
    }

    private func save(_ text: String, to file: String, card: String) {
        // Symlinks are followed before the checks, so a link inside the project can't point the save somewhere else.
        let root = workRoot.resolvingSymlinksInPath()
        let url = Self.resolvingExistingPart(of: root.appendingPathComponent(file).standardizedFileURL)
        guard url.path.hasPrefix(root.path + "/") else {
            append("\(card) didn't save: \(file) is outside the project folder")
            return
        }
        guard !Checks.isProtectedSavePath(String(url.path.dropFirst(root.path.count))) else {
            append("\(card) didn't save: \(file) is in a folder Queen Bee doesn't write to")
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            append("\(card) saved the answer to \(file)")
        } catch {
            append("\(card) couldn't save to \(file): \(error.localizedDescription)")
        }
    }

    /// `url` with the symlinks in the part of it that exists followed. A file about to be made doesn't exist yet,
    /// and a path that doesn't exist is otherwise left as written, links and all.
    private static func resolvingExistingPart(of url: URL) -> URL {
        var existing = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    private func notifyOrchestrator(of output: RunOutput) {
        guard flow.notifyOrchestrator, orchestrator.isLive else { return }
        let lines = log.dropFirst(runLogStart).suffix(12).map { "- \($0.text)" }.joined(separator: "\n")
        let ended = runs.last.map { " It \($0.summary)." } ?? ""
        var text = "[Queen Bee · notice] The run\(output.runID.map { " \($0)" } ?? "") has ended.\(ended) This is information from the app, not a new request.\n\nWhat happened:\n\(lines)"
        for result in output.results {
            text += "\n\nFinal answer at \(result.cardName):\n\(result.text.prefix(4000))"
        }
        orchestrator.send(text)
    }

    /// Adds a line to the log about something a paired device did, so the Mac shows what was done from elsewhere.
    /// A device's Clear leaves these lines: see `clearLog(fromDevice:)`.
    func noteFromDevice(_ text: String) { append(text, kept: true) }

    private func append(_ text: String, kept: Bool = false) {
        log.append(LogLine(date: Date(), text: text, isKept: kept))
        scheduleHistorySave()
        if log.count > LogLine.mostKept {
            log.removeFirst(log.count - LogLine.mostKept)
            runLogStart = max(0, runLogStart - 1)
        }
    }

    // MARK: ToolHost, for the orchestrator's tools

    func snapshot() async -> FlowSnapshot {
        var agents: [String: AgentStatus] = [:]
        for card in flow.cards where card.kind == .agent {
            let session = sessions[card.id]
            agents[card.id] = AgentStatus(state: (session?.state ?? .notStarted).rawValue, lastReply: session?.lastReply)
        }
        var innerNames: [String: String] = [:]
        for card in flow.cards where card.kind == .flow { innerNames[card.id] = innerFlow(of: card)?.flow.name }
        return FlowSnapshot(flow: flow, agents: agents, isRunning: isRunning,
                            otherFlows: flowsOrchestratorMayRun.map(\.flow.name),
                            subflowLevelsLeft: levelsLeft,
                            subflows: subflows().map { (name: $0.controller.flow.name, depth: $0.depth) },
                            innerFlowNames: innerNames,
                            armedStartIDs: Set(flow.cards.filter { $0.kind == .start && isArmed($0) }.map(\.id)),
                            extraWarnings: nestingWarnings)
    }

    func mutate<T: Sendable>(_ body: @Sendable (inout Flow) throws -> T) async throws -> T {
        var copy = flow
        let value = try body(&copy)
        try checkNesting(of: copy)
        // The orchestrator builds a flow in a burst of calls. They undo together.
        takeUnseen(copy, from: nil, undo: "Orchestrator's Changes", key: "orchestrator", within: 8)
        return value
    }

    /// Takes a change to the flow that the person at this Mac was not seen to make: one from the orchestrator's
    /// tools, or from a paired device, which is named. Both go through here, so both are held to the same two
    /// rules. A Script card's command is only "typed on this Mac" when the settings panel wrote it, which
    /// this never is, so a run stops and asks before running one that came this way. And a change to what a
    /// scheduled flow does turns its schedules off.
    private func takeUnseen(_ copy: Flow, from device: String?, undo name: String, key: String?, within window: TimeInterval = 1.5) {
        let old = flow
        if device != nil { holdBackAgents(in: copy, newSince: old) }
        flow = copy
        withdrawConsents(changedFrom: old, by: device)
        registerUndo(from: old, name, key: key, within: window)
        reconcile()
    }

    private func holdBackAgents(in new: Flow, newSince old: Flow) {
        for card in new.cards where card.kind == .agent && old.card(card.id) == nil { heldBack.insert(card.id) }
    }

    private func withdrawConsents(changedFrom old: Flow, by device: String?) {
        if device != nil { forgetAllowedScripts(changedFrom: old) }
        disarmSchedules(changedFrom: old, by: device)
    }

    /// The orchestrator may work in the sub-flows below its own flow, and nowhere else.
    func subflowHost(named ref: String) async throws -> any ToolHost {
        let wanted = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted == flow.id || flow.name.caseInsensitiveCompare(wanted) == .orderedSame { return self }
        let below = subflows().map(\.controller)
        guard let found = Nesting.resolve(wanted, in: below.map(\.flow), excluding: flow.id).flatMap(project.controller) else {
            let names = below.map(\.flow.name)
            throw FlowError.notFound("No sub-flow below \(flow.name) is called \"\(wanted)\". "
                + (names.isEmpty ? "It has none yet." : "Below it are: \(names.joined(separator: ", ")).")
                + " You can only work in your own flow and the sub-flows below it, not the flows above or beside it.")
        }
        return found
    }

    /// Makes a sub-flow below this flow for the orchestrator: the flow, and the Flow card that runs it.
    func createSubflow(name: String?, card: String?) async throws -> String {
        if let problem = newSubflowProblem {
            throw FlowError.invalid(problem + " Tell the person that no more sub-flows can be added at this level unless they raise that limit.")
        }
        var existing: Card?
        if let card, !card.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let found = flow.resolveCard(card) else { throw FlowError.notFound("No card called \"\(card)\"") }
            guard found.kind == .flow else { throw FlowError.invalid("\"\(found.name)\" is a \(found.kind.label) card, not a Flow card") }
            guard innerFlow(of: found) == nil else { throw FlowError.invalid("\"\(found.name)\" already runs a flow") }
            existing = found
        }
        guard let made = project.newSubflow(named: name ?? existing?.name ?? "Sub-flow") else {
            throw FlowError.invalid("The sub-flow couldn't be saved")
        }
        let madeID = made.flow.id, madeName = made.flow.name, existingID = existing?.id
        do {
            let cardName = try await mutate { flow -> String in
                var patch = CardPatch()
                patch.flowRef = madeID
                if let existingID { return try flow.updateCard(existingID, patch: patch).name }
                return try flow.addCard(kind: .flow, name: flow.uniqueName(madeName), patch: patch, clearOfOthers: true).name
            }
            return "Made the sub-flow \"\(madeName)\" with an Input card and an Output card, and the Flow card \"\(cardName)\" here runs it. "
                + "Build it by passing in_flow: \"\(madeName)\" to the other tools. It may go \(max(0, made.levelsLeft)) more \(made.levelsLeft == 1 ? "level" : "levels") down."
        } catch {
            // Nothing points at the new flow, so it would only be clutter.
            project.delete(made)
            throw error
        }
    }

    /// An armed schedule runs with nobody watching, so it is tied to what the person agreed to.
    /// When the orchestrator changes a Start card's command, or an agent's brief, folder,
    /// permissions or browser, every schedule in the flow goes off until the person turns it on again.
    /// The orchestrator putting a command back as it was puts the schedule back on.
    ///
    /// A change from a paired device, which is named here, is held to more: see `disarmSchedules(changedFrom:byDevice:)`.
    private func disarmSchedules(changedFrom old: Flow, by device: String? = nil) {
        if let device { return disarmSchedules(changedFrom: old, byDevice: device) }
        let armed = flow.cards.filter { $0.kind == .start && isArmed($0) }
        guard !armed.isEmpty else { return }
        let agentsChanged = flow.cards.contains { card in
            guard card.kind == .agent, let was = old.card(card.id) else { return card.kind == .agent }
            return card.instructions != was.instructions || card.cwd != was.cwd || card.permissionMode != was.permissionMode
                || (card.browser == true) != (was.browser == true)
        }
        guard agentsChanged else { return }
        for card in armed { ScheduleArming.arm(nil, command: "", scope: allowScope, cardID: card.id) }
        append("The orchestrator changed what the flow does, so its schedule is off until you turn it on again", kept: true)
        banner = "The schedule is off: the orchestrator changed what the flow does. Turn it on again in the Start card's settings."
        reschedule()
    }

    /// A paired device changed the flow. If that changed anything the flow does when it runs, which is any
    /// link, any card added or taken away and any setting, and not where a card is, how big, what group it
    /// is in or what a note says, then every schedule of the flow goes off, and so does every schedule of a
    /// flow above it that runs it as a sub-flow. What was agreed to is forgotten, so nothing a device does
    /// afterwards, putting a command back included, turns one on again. And no change from a device leaves
    /// a schedule on that was off before it.
    private func disarmSchedules(changedFrom old: Flow, byDevice device: String) {
        let wereOn = Set(old.cards.filter { $0.kind == .start && isArmed($0) }.map(\.id))
        // Turned on by this very change: it was made to match something agreed to earlier.
        let turnedOn = flow.cards.filter { $0.kind == .start && !wereOn.contains($0.id) && isArmed($0) }.map(\.id)
        for id in turnedOn { ScheduleArming.arm(nil, command: "", scope: allowScope, cardID: id) }
        guard flow.changesWhatItDoes(from: old) else {
            // Nobody is shown a time for a schedule that is off.
            if !turnedOn.isEmpty { reschedule() }
            return
        }
        // A card that went with this change is forgotten too, so bringing it back doesn't bring its schedule back on.
        let mine = wereOn.union(flow.cards.filter { $0.kind == .start && isArmed($0) }.map(\.id))
        for id in mine { ScheduleArming.arm(nil, command: "", scope: allowScope, cardID: id) }
        if !mine.isEmpty {
            append("\(device) changed what the flow does, so its schedule is off until you turn it on again", kept: true)
            banner = "The schedule is off: \(device) changed what the flow does. Turn it on again in the Start card's settings."
        }
        if !mine.isEmpty || !turnedOn.isEmpty { reschedule() }
        let inner = Remote.logName(flow.name, or: "a flow")
        for outer in flowsAbove { outer.turnSchedulesOff(becauseOf: device, changing: inner) }
    }

    /// Every flow that runs this one as a sub-flow, however far up.
    var flowsAbove: [FlowController] {
        let nesting = project.nesting
        var above: Set<String> = [], climbing = [flow.id]
        while let next = climbing.popLast() {
            for outer in nesting.outerFlows(of: next) where above.insert(outer).inserted { climbing.append(outer) }
        }
        return above.sorted().compactMap(project.controller).filter { $0 !== self }
    }

    /// A paired device changed, or deleted, a flow this one runs as a sub-flow.
    func turnSchedulesOff(becauseOf device: String, changing inner: String) {
        let armed = flow.cards.filter { $0.kind == .start && isArmed($0) }
        guard !armed.isEmpty else { return }
        for card in armed { ScheduleArming.arm(nil, command: "", scope: allowScope, cardID: card.id) }
        append("\(device) changed \(inner), which this flow runs, so its schedule is off until you turn it on again", kept: true)
        banner = "The schedule is off: \(device) changed \(inner), which this flow runs. Turn it on again in the Start card's settings."
        reschedule()
    }

    /// One command is remembered as allowed for each Script card: the latest the person typed or allowed.
    /// A device changing the command, even back to that one, is not the person typing it at this Mac, so
    /// what was remembered is forgotten and the next run asks. So is a card a device made or brought back.
    private func forgetAllowedScripts(changedFrom old: Flow) {
        for card in flow.cards where card.kind == .script && old.card(card.id)?.command != card.command {
            ConsentStore.scripts.grant(nil, scope: allowScope, cardID: card.id)
            // And it is remembered as a device's, so that no device can then allow it: see `allowScript(_:fromDevice:)`.
            ConsentStore.scriptsFromDevices.grant(card.command ?? "", scope: allowScope, cardID: card.id)
        }
    }

    // MARK: Edits from a paired device

    /// Makes an edit a paired device asked for, by the rules every edit is held to, and then by the rules for
    /// a change the person at this Mac was not seen to make. `device` is the device's name, for the log.
    /// Returns nil when it was done, or why not, in words the device shows the person. Nothing on this Mac's
    /// own window is touched: what is selected stays selected, and no message is put up here for a refusal.
    func edit(from device: String, _ name: String, key: String? = nil, _ body: (inout Flow) throws -> Void) -> String? {
        var copy = flow
        do {
            try body(&copy)
        } catch {
            return String(describing: error)
        }
        // A flow that is already bigger, made on this Mac, may be changed from a device. It may not be grown.
        if copy.cards.count > max(flow.cards.count, Remote.cardLimit) {
            return "A flow can have \(Remote.cardLimit) cards at most when it is added to from a device. Add more on your Mac."
        }
        if copy.links.count > max(flow.links.count, Remote.linkLimit) {
            return "A flow can have \(Remote.linkLimit) links at most when it is added to from a device. Add more on your Mac."
        }
        // Each agent is a Claude Code session on this Mac.
        func agents(_ flow: Flow) -> Int { flow.cards.count { $0.kind == .agent } }
        if agents(copy) > max(agents(flow), Remote.agentLimit) {
            return "A flow can have \(Remote.agentLimit) agents at most when it is added to from a device. Add more on your Mac."
        }
        // Counted as the file it is saved in. Only asked when the flow could have grown past it.
        if copy != flow, let size = try? Remote.encode(copy).count, size > Remote.flowByteLimit, size > ((try? Remote.encode(flow).count) ?? 0) {
            return "This flow is as big as a device can make it. Make it bigger on your Mac."
        }
        cutLooseFlowCardsThatCannotNest(in: &copy)
        takeUnseen(copy, from: device, undo: name, key: key)
        return nil
    }

    /// The first step of a device's drag: everything it moves until `endDrag` is one undo step.
    func beginDrag(from deviceID: String) {
        if deviceDrags[deviceID] == nil { deviceDrags[deviceID] = [:] }
    }

    /// The drag is over. What it did becomes one step of Undo that puts back where the cards it touched
    /// were and how big, and nothing else: whatever else was changed meanwhile, here or from another
    /// device, is not that drag's to take back.
    func endDrag(from deviceID: String, _ name: String) {
        guard let before = deviceDrags.removeValue(forKey: deviceID) else { return }
        guard before.contains(where: { id, was in frame(of: id).map { $0 != was } ?? false }) else { return }
        lastUndo = nil
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { $0.restoreFrames(before, name) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        undoRevision += 1
    }

    private func frame(of id: String) -> CGRect? {
        flow.card(id).map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    /// Puts cards back where they were and how big, in the flow as it is now, and makes that undoable in
    /// turn. A card that has gone since is left out.
    private func restoreFrames(_ frames: [String: CGRect], _ name: String) {
        var now: [String: CGRect] = [:]
        var copy = flow
        for i in copy.cards.indices {
            guard let frame = frames[copy.cards[i].id] else { continue }
            now[copy.cards[i].id] = CGRect(x: copy.cards[i].x, y: copy.cards[i].y, width: copy.cards[i].width, height: copy.cards[i].height)
            copy.cards[i].x = frame.minX
            copy.cards[i].y = frame.minY
            copy.cards[i].width = frame.width
            copy.cards[i].height = frame.height
        }
        lastUndo = nil
        if copy != flow { flow = copy }
        undoManager.registerUndo(withTarget: self) { $0.restoreFrames(now, name) }
        undoManager.setActionName(name)
        undoRevision += 1
    }

    /// Remembers where the cards a step of a device's drag is about to touch are, the first time each is touched.
    private func noteDragged(_ ids: some Sequence<String>, by deviceID: String) {
        guard var before = deviceDrags[deviceID] else { return }
        for id in ids where before[id] == nil { before[id] = frame(of: id) }
        deviceDrags[deviceID] = before
    }

    /// A step of a device's drag: puts each card where it was dragged to. Part of a drag, so it is undone with the drag.
    func move(to places: [String: CGPoint], by deviceID: String) -> String? {
        guard places.keys.allSatisfy({ flow.card($0) != nil }) else { return "That card is no longer in the flow." }
        guard let left = places.values.map(\.x).min(), let top = places.values.map(\.y).min() else { return nil }
        noteDragged(places.keys, by: deviceID)
        // The whole set stops at the canvas's edge together, so it keeps its shape, as a drag on this Mac does.
        let dx = max(0, CardView.farLeft - left), dy = max(0, CardView.farLeft - top)
        var copy = flow
        for i in copy.cards.indices {
            guard let place = places[copy.cards[i].id] else { continue }
            copy.cards[i].x = place.x + dx
            copy.cards[i].y = place.y + dy
        }
        if copy != flow { flow = copy }
        return nil
    }

    /// A step of a device's drag of a card's corner. A card is never made smaller than its kind allows.
    func resize(_ id: String, to frame: CGRect, by deviceID: String) -> String? {
        var patch = CardPatch()
        patch.x = max(frame.minX, CardView.farLeft)
        patch.y = max(frame.minY, CardView.farLeft)
        patch.width = frame.width
        patch.height = frame.height
        var copy = flow
        guard copy.card(id) != nil, (try? copy.updateCard(id, patch: patch)) != nil else { return "That card is no longer in the flow." }
        noteDragged([id], by: deviceID)
        if copy != flow { flow = copy }
        return nil
    }

    /// Undo or Redo for a device: the flow's own, never that of a text box someone at this Mac is typing in.
    /// What it brings back was not chosen just now by the person at this Mac, so it is held to the rules for
    /// any other change from a device.
    func undo(from device: String, redo: Bool = false) -> String? {
        guard redo ? undoManager.canRedo : undoManager.canUndo else { return redo ? "There is nothing to redo." : "There is nothing to undo." }
        let old = flow
        undoingForDevice = true
        if redo { undoManager.redo() } else { undoManager.undo() }
        undoingForDevice = false
        withdrawConsents(changedFrom: old, by: device)
        return nil
    }

    /// Warnings about Flow cards that are past the limit, or point at a flow that would be.
    var nestingWarnings: [String: String] {
        let nesting = nesting
        var found: [String: String] = [:]
        for card in flow.cards where card.kind == .flow {
            if nesting.levelsLeft(flow.id) < 1 {
                found[card.id] = "Past the sub-flow limit"
            } else if let inner = innerFlow(of: card), nesting.problem(placing: inner.flow.id, in: flow.id) != nil {
                found[card.id] = "Its flow goes too deep"
            }
        }
        return found
    }

    /// Refuses an edit that would nest sub-flows deeper than the limit, or make a flow run itself.
    private func checkNesting(of edited: Flow) throws {
        for card in edited.cards where card.kind == .flow {
            let was = flow.card(card.id)
            guard was?.flowRef != card.flowRef || was == nil else { continue }
            let ref = (card.flowRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if ref.isEmpty {
                if let problem = newSubflowProblem, was == nil { throw FlowError.invalid(problem) }
                continue
            }
            guard let inner = Nesting.resolve(ref, in: project.controllers.map(\.flow), excluding: flow.id).flatMap(project.controller) else {
                throw FlowError.invalid("No flow in this project is called \"\(ref)\". The ones you may use are: \(flowsOrchestratorMayRun.map(\.flow.name).joined(separator: ", "))")
            }
            guard flowsOrchestratorMayRun.contains(where: { $0 === inner }) else {
                throw FlowError.invalid("\"\(inner.flow.name)\" isn't below this flow, so only the person can link it in. Ask them.")
            }
            if let problem = nestingProblem(placing: inner) { throw FlowError.invalid(problem) }
        }
    }

    /// The flows a Flow card here may be pointed at by the orchestrator: those already below
    /// this flow, and sub-flows nothing runs yet. Anything else is the person's to link, or the
    /// orchestrator could reach into a flow beside its own by pointing a card at it.
    var flowsOrchestratorMayRun: [FlowController] {
        let nesting = nesting
        let below = Set(nesting.subflows(of: flow.id).map(\.id))
        return project.controllers.filter { other in
            other !== self && nesting.problem(placing: other.flow.id, in: flow.id) == nil
                && (below.contains(other.flow.id) || (other.flow.isSubflow == true && nesting.outerFlows(of: other.flow.id).isEmpty))
        }
    }

    func runFlow(command: String?) async throws -> String {
        await run(command: command)
    }

    func stopFlow() async {
        await stop()
    }

    func runLog() async -> [String] {
        log.dropFirst(runLogStart).map(\.text)
    }
}
