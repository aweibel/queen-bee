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
}

/// One open flow: the graph, its sessions, and its runs. Every change to the graph goes
/// through here, whether it comes from the canvas, the settings panel or the orchestrator's
/// tools, so all three always see the same thing.
// Named as main-actor here because conforming to a Sendable protocol would otherwise opt the class out of the app's default.
@MainActor @Observable
final class FlowController: ToolHost {
    static let orchestratorKey = "orchestrator"

    var flow: Flow {
        didSet {
            guard flow != oldValue else { return }
            scheduleSave()
            if flow.cards.map(\.trigger) != oldValue.cards.map(\.trigger) || flow.cards.count != oldValue.cards.count { reschedule() }
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
    /// The cost breakdown is open over the canvas.
    var showsCost = false
    /// How many more levels of sub-flow the run that is going may still enter.
    @ObservationIgnored private var runLevelsLeft = Nesting.usualLimit
    /// The flow's own settings are open over the canvas.
    var showsFlowSettings = false
    /// The card whose "run from here" box is open in the settings panel.
    var runFromCardID: String?
    @ObservationIgnored private var currentRun: (id: String, started: Date, command: String)?
    /// How many runs are kept, and how much of each message.
    private static let keptRuns = 20, runsWithMessages = 3, keptMessageLength = 8_000, keptMessagesPerLink = 10
    /// Messages waiting at Approval and Script cards in the run that is going.
    private(set) var holds: [PendingHold] = []
    /// The work behind each hold that runs by itself: a script's command, or a Flow card's inner run.
    @ObservationIgnored private var holdTasks: [String: Task<Void, Never>] = [:]
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
    @ObservationIgnored private var isOpen = false
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
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    /// The schedule each due time in `nextFires` was worked out from.
    @ObservationIgnored private var scheduledFor: [String: Trigger] = [:]
    @ObservationIgnored private var watchers: [String: (path: String, watcher: FileWatcher)] = [:]
    @ObservationIgnored private var lastFileFire = Date.distantPast

    /// Whether a Start card's schedule is one the person turned on in this app.
    func isArmed(_ card: Card) -> Bool {
        card.trigger.map { ScheduleArming.isArmed($0, command: card.command ?? "", scope: allowScope, cardID: card.id) } ?? false
    }

    /// Sets what starts runs from a Start card, and turns it on: the person chose it.
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

    private func saveHistory() {
        historyTask?.cancel()
        historyTask = nil
        guard !isClosed else { return }
        // What is saved as "now" is always the latest run, even while an earlier one is on show.
        let latest = viewedRunID == nil ? nil : runs.last
        let history = RunHistory(log: log, results: latest?.results ?? results, marks: latest?.marks ?? marks,
                                 linkPasses: latest?.linkPasses ?? linkPasses, handOffs: latest?.handOffs ?? handOffs,
                                 messages: latest?.messages ?? messages, runs: runs)
        // Encoding and writing can take a while for a long log, so neither holds up the canvas.
        let url = historyURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(history) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
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
    }

    /// A moment after a run ends, once Claude Code has written its totals, the run is given its share.
    private func recordUsage(forRun id: String) {
        let before = usageAtRunStart
        Task {
            // Long enough for a sub-flow that ended just before this run to have costed its own.
            try? await Task.sleep(for: .seconds(4))
            await self.refreshUsage()
            guard !self.isClosed, let index = self.runs.firstIndex(where: { $0.id == id }) else { return }
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
            self.saveHistory()
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
        handOffs = 0
        viewedRunID = nil
        runLogStart = log.count
        usageAtRunStart = usage
    }

    private func finishRecord(_ output: RunOutput) {
        guard let run = currentRun else { return }
        currentRun = nil
        let outcome: RunRecord.Outcome = marks.values.contains(where: \.failed) ? .failed
            : output.log.contains { $0.hasPrefix("Run stopped") } ? .stopped : .finished
        runs.append(RunRecord(id: run.id, started: run.started, ended: Date(), outcome: outcome, command: run.command,
                              log: Array(log.dropFirst(runLogStart)), results: results, marks: marks, linkPasses: linkPasses,
                              messages: messages, handOffs: handOffs))
        if runs.count > Self.keptRuns { runs.removeFirst(runs.count - Self.keptRuns) }
        // The messages a link carried are kept for the newest few runs only; older runs keep their path and answers.
        for index in runs.indices.dropLast(Self.runsWithMessages) where !runs[index].messages.isEmpty { runs[index].messages = [:] }
        recordUsage(forRun: run.id)
    }

    /// The last message that reached a card in the run on show: what "run from here" starts with.
    func lastMessage(into cardID: String) -> LinkMessage? {
        flow.links(into: cardID).compactMap { messages[$0.id]?.last }.max { $0.date < $1.date }
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
        Task {
            while services.environment == nil { try? await Task.sleep(for: .milliseconds(100)) }
            startMissingSessions()
            await refreshUsage()
        }
        reschedule()
    }

    func shutDown() {
        // The run, if there is one, ends here: nothing is waited on and nothing more is routed.
        holdTasks.values.forEach { $0.cancel() }
        holdTasks.removeAll()
        holds.removeAll()
        awaitingAnswer.removeAll()
        stallNotice?.cancel()
        currentRun = nil
        isRunning = false
        if let engine { Task { _ = await engine.stop() } }
        scheduleTask?.cancel()
        watchers.values.forEach { $0.watcher.stop() }
        watchers.removeAll()
        nextFires = [:]
        scheduledFor = [:]
        saveNow()
        if historyTask != nil { saveHistory() }
        sessions.values.forEach { $0.terminate() }
        sessions.removeAll()
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
        // A pasted or restored Flow card that would make a circle, or go too deep, is kept but no longer runs anything.
        let nesting = Nesting(flows: project.controllers.map { $0 === self ? copy : $0.flow })
        for index in copy.cards.indices where copy.cards[index].kind == .flow && copy.cards[index].flowRef != old.card(copy.cards[index].id)?.flowRef {
            if let inner = Nesting.resolve(copy.cards[index].flowRef, in: project.controllers.map(\.flow), excluding: flow.id),
               nesting.problem(placing: inner, in: flow.id) != nil { copy.cards[index].flowRef = nil }
        }
        flow = copy
        if undoable { registerUndo(from: old, name, key: key) }
        reconcile()
        return true
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
            undoManager.undo()
        }
    }

    func redo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true {
            text.undoManager?.redo()
        } else if undoManager.canRedo {
            undoManager.redo()
        }
    }

    var undoTitle: String { _ = undoRevision; return undoManager.canUndo ? undoManager.undoMenuItemTitle : "Undo" }
    var redoTitle: String { _ = undoRevision; return undoManager.canRedo ? undoManager.redoMenuItemTitle : "Redo" }

    /// Puts the graph back to `old`, and makes that undoable in turn. Sessions are not part
    /// of the graph: a card that is still there keeps the session it has now.
    private func restore(_ old: Flow, _ name: String) {
        let current = flow
        var back = old
        back.orchestratorSessionID = current.orchestratorSessionID
        for i in back.cards.indices {
            if let now = current.card(back.cards[i].id) { back.cards[i].sessionID = now.sessionID }
        }
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
            session.terminate()
            sessions[id] = nil
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
    func applyRole(_ role: AgentRole?, toCard id: String) {
        guard let role else { return setRole(nil, onCard: id, name: "Remove Role") }
        perform("Apply \(role.name)") {
            try $0.updateCard(id, patch: role.patch)
            if let index = $0.cards.firstIndex(where: { $0.id == id }) { $0.cards[index].role = role.id }
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
        var dx = 48.0, dy = 48.0
        if let point, let left = fragment.cards.map(\.x).min(), let top = fragment.cards.map(\.y).min() {
            dx = point.x - left
            dy = point.y - top
        }
        var made: [Card] = []
        perform("Paste") { made = $0.insert(fragment, dx: dx, dy: dy) }
        if !made.isEmpty { selection = .of(Set(made.map(\.id))) }
    }

    /// Adds a card. With a point, as when one is dropped from the palette, the card is centred
    /// there. Without, it goes to the middle of what is on screen, stepped clear of other cards.
    func addCard(_ kind: CardKind, at point: CGPoint? = nil, role: AgentRole? = nil) {
        var made: Card?
        let size = Card.make(kind: kind, name: "x", x: 0, y: 0)
        var spot: CGRect
        if let point {
            spot = CGRect(x: max(20, point.x - size.width / 2), y: max(20, point.y - CanvasGeometry.titleHeight / 2),
                          width: size.width, height: size.height)
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
        var patch = CardPatch()
        if kind == .agent, let model = UserDefaults.standard.string(forKey: "defaultModel"), !model.isEmpty { patch.model = model }
        if let role { patch = role.patch }
        perform("Add \(role?.name ?? kind.label)") {
            made = try $0.addCard(kind: kind, name: role.map { [flow] in flow.uniqueName($0.name) }, x: spot.minX, y: spot.minY, patch: patch)
            if let role, let made, let index = $0.cards.firstIndex(where: { $0.id == made.id }) { $0.cards[index].role = role.id }
        }
        if let made { selection = .card(made.id) }
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

    private func saveNow() {
        saveTask?.cancel()
        do {
            try project.store.save(flow, to: fileURL)
        } catch {
            banner = "Couldn't save the flow: \(error.localizedDescription)"
        }
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
        guard let session = sessions[id], session.isLive, let launched = session.launched else { return }
        var patch = CardPatch()
        patch.name = launched.name
        patch.instructions = launched.instructions
        // An empty string clears these back to "your default".
        patch.model = launched.model
        patch.effort = launched.effort
        patch.permissionMode = launched.permissionMode
        patch.cwd = launched.folder
        update(id, patch)
    }

    private func startMissingSessions() {
        for card in flow.cards where card.kind == .agent && session(forCard: card.id).state == .notStarted {
            startSession(forCard: card.id)
        }
        if orchestrator.state == .notStarted { startOrchestrator() }
    }

    /// Starts, or after an exit restarts, the session of one agent card.
    func startSession(forCard id: String) {
        guard let environment = services.environment else { return }
        guard let index = flow.cards.firstIndex(where: { $0.id == id }), flow.cards[index].kind == .agent else { return }
        // The id ends up on the command line and in a file name, so one from a flow file has to be a real id.
        if flow.cards[index].sessionID.flatMap(UUID.init(uuidString:)) == nil { flow.cards[index].sessionID = UUID().uuidString.lowercased() }
        let card = flow.cards[index]
        guard let spec = ClaudeLauncher.agent(flow: flow, card: card, sessionID: card.sessionID!, projectRoot: project.root,
                                              services: services, environment: environment) else {
            banner = services.problem
            return
        }
        freshSession(for: id).start(spec, settings: AgentSettings(card))
    }

    func startOrchestrator() {
        guard let environment = services.environment else { return }
        if flow.orchestratorSessionID.flatMap(UUID.init(uuidString:)) == nil { flow.orchestratorSessionID = UUID().uuidString.lowercased() }
        guard let spec = ClaudeLauncher.orchestrator(flow: flow, sessionID: flow.orchestratorSessionID!, projectRoot: project.root,
                                                     services: services, environment: environment) else {
            banner = services.problem
            return
        }
        freshSession(for: Self.orchestratorKey).start(spec)
    }

    /// A terminal that has run a process doesn't take a second one, so a restart gets a new terminal.
    private func freshSession(for id: String) -> TerminalSession {
        if let old = sessions[id], old.state != .notStarted {
            old.terminate()
            sessions[id] = nil
            sessionGeneration += 1
        }
        return session(forCard: id)
    }

    private func sessionExited(_ id: String) {
        guard id != Self.orchestratorKey, isRunning, let engine else { return }
        let name = flow.card(id)?.name ?? id
        markFailed(id)
        Task { self.absorb(await engine.agentFailed(flow: self.flow, cardID: id, reason: "\(name)'s session exited"), sender: nil) }
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
    func handleHook(from who: String, payload: JSONValue) {
        guard let session = sessions[who] else { return }
        let event = payload["hook_event_name"]?.stringValue ?? ""
        let type = payload["notification_type"]?.stringValue
            ?? ((payload["message"]?.stringValue ?? "").localizedCaseInsensitiveContains("permission") ? "permission_prompt" : nil)
        let wasWaiting = session.state == .needsYou
        session.apply(hook: event, notificationType: type)
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
            pluginSpoke.remove(who)
        case "Stop":
            let reply = payload["last_assistant_message"]?.stringValue ?? ""
            session.lastReply = reply
            routeIfPluginIsSilent(who, reply: reply)
        case "StopFailure":
            guard isRunning, let engine else { return }
            let name = flow.card(who)?.name ?? who
            markFailed(who)
            Task { self.absorb(await engine.agentFailed(flow: self.flow, cardID: who, reason: "\(name)'s turn ended with an API error"), sender: nil) }
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
            self.absorb(await engine.agentReplied(flow: self.flow, cardID: who, text: reply), sender: nil)
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
        return absorb(await engine.agentReplied(flow: flow, cardID: who, text: answer, waitingOnAnswer: asked), sender: who)
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
    }

    @discardableResult
    func run(command: String? = nil, startCardID: String? = nil, levelsLeft given: Int? = nil) async -> String {
        await start(command: command, startCardID: startCardID, levelsLeft: given).status
    }

    /// `note` is a line for the run's log saying who started it, when that wasn't the person at this Mac.
    func start(command: String? = nil, startCardID: String? = nil, levelsLeft given: Int? = nil, note: String? = nil) async -> RunStart {
        guard let engine = readyEngine() else { return RunStart(began: false, status: services.problem ?? "Claude Code isn't ready yet.") }
        isClosed = false
        // Run directly, a flow goes by its own place under the flow at the top. Run by a Flow
        // card, it is handed what is left of the run's allowance.
        if !isRunning { runLevelsLeft = given ?? levelsLeft }
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
            if let note { append(note) }
        }
        absorb(output, sender: nil)
        return RunStart(began: began, status: output.log.last ?? (output.runID.map { "Run \($0) started" } ?? "Nothing to run"))
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
        isClosed = false
        runLevelsLeft = levelsLeft
        let output = await engine.start(flow: flow, at: cardID, message: message, fromName: sender)
        if let id = output.runID {
            clearForRun()
            currentRun = (id, Date(), "From \(flow.card(cardID)?.name ?? "a card"): \(message.prefix(160))")
            if let note { append(note) }
        }
        absorb(output, sender: nil)
        return RunStart(began: output.runID != nil, status: output.log.last ?? "Nothing to run")
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
        output.log.forEach(append)
        record(output.visits, sender: sender)
        handOffs += output.deliveries.count
        for result in output.results {
            results[result.cardID] = result.text
            if let file = result.saveTo, !file.isEmpty { save(result.text, to: file, card: result.cardName) }
        }
        var forPlugin: [(to: String, text: String)] = []
        for delivery in output.deliveries {
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
            var carried = messages[travel.linkID] ?? []
            carried.append(LinkMessage(date: Date(), from: travel.fromName, text: String(travel.text.prefix(Self.keptMessageLength))))
            messages[travel.linkID] = Array(carried.suffix(Self.keptMessagesPerLink))
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
            holds.removeAll()
            lastRunEnded = Date()
            finishRecord(output)
            notifyOrchestrator(of: output)
            let stopped = marks.values.contains(where: \.failed)
            Notifier.post(title: stopped ? "\(flow.name) stopped" : "\(flow.name) finished",
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
        }
        if hold.kind == .flow {
            let inner = innerFlow(of: card)
            pending.command = inner?.flow.name ?? ""
            holds.append(pending)
            return runInnerFlow(pending, inner)
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

    /// A Flow card: runs another flow of the project with the message as its command, and
    /// passes that flow's final answer on.
    private func runInnerFlow(_ hold: PendingHold, _ inner: FlowController?) {
        guard let inner, inner !== self else {
            return resolve(hold.id, port: "fail", text: "The flow this card runs is no longer in the project.")
        }
        // Whatever a flow's file says, a run never goes deeper than the flow at the top allows.
        guard runLevelsLeft >= 1 else {
            return resolve(hold.id, port: "fail", text: "\(inner.flow.name) wasn't run: it is deeper than the sub-flow limit of the flow this run started from.")
        }
        // This also stops two flows that run each other from going round for ever.
        guard !inner.isRunning else {
            return resolve(hold.id, port: "fail", text: "\(inner.flow.name) was already running.")
        }
        holdTasks[hold.id] = Task {
            let answer = await withTaskCancellationHandler {
                await inner.runToEnd(command: hold.text, levelsLeft: self.runLevelsLeft - 1)
            } onCancel: {
                Task { @MainActor in await inner.stop() }
            }
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

    func setNotifiesOrchestrator(_ on: Bool) {
        guard flow.notifyOrchestrator != on else { return }
        let old = flow
        flow.notifyOrchestrator = on
        registerUndo(from: old, on ? "Tell Orchestrator of Runs" : "Stop Telling Orchestrator of Runs")
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

    /// Runs the flow and waits for the run to end. The answer is what reached its End cards.
    func runToEnd(command: String, levelsLeft: Int) async -> (finished: Bool, text: String) {
        let before = runs.last?.id
        let status = await run(command: command, levelsLeft: levelsLeft)
        while isRunning, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
        if Task.isCancelled { return (false, "The run was stopped.") }
        guard let record = runs.last, record.id != before else { return (false, status) }
        let answers = flow.cards.filter { $0.kind == .end }.compactMap { record.results[$0.id] }
        // A run that ended without anything reaching an Output has no answer to hand back.
        guard record.outcome == .finished, !answers.isEmpty else {
            return (false, answers.isEmpty ? "\(flow.name) ended without an answer reaching its Output. \(record.log.last?.text ?? "")" : answers.joined(separator: "\n\n"))
        }
        return (true, answers.joined(separator: "\n\n"))
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
        let folder = project.root
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
    func allowScript(_ id: String) {
        guard let index = holds.firstIndex(where: { $0.id == id }), holds[index].kind == .script, holds[index].needsAllow else { return }
        ScriptRunner.allow(holds[index].command, scope: allowScope, cardID: holds[index].cardID)
        holds[index].needsAllow = false
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
        if flow.card(id)?.command == command { ScriptRunner.allow(command, scope: allowScope, cardID: id) }
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
        let root = project.root.resolvingSymlinksInPath()
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
        var text = "[Queen Bee · notice] The run\(output.runID.map { " \($0)" } ?? "") has ended. This is information from the app, not a new request.\n\nWhat happened:\n\(lines)"
        for result in output.results {
            text += "\n\nFinal answer at \(result.cardName):\n\(result.text.prefix(4000))"
        }
        orchestrator.send(text)
    }

    /// Adds a line to the log about something a paired device did, so the Mac shows what was done from elsewhere.
    func noteFromDevice(_ text: String) { append(text) }

    private func append(_ text: String) {
        log.append(LogLine(date: Date(), text: text))
        scheduleHistorySave()
        if log.count > 600 {
            log.removeFirst(log.count - 600)
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
        let old = flow
        flow = copy
        disarmSchedules(changedFrom: old)
        // The orchestrator builds a flow in a burst of calls. They undo together.
        registerUndo(from: old, "Orchestrator's Changes", key: "orchestrator", within: 8)
        reconcile()
        return value
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
    /// When the orchestrator changes a Start card's command, or an agent's brief, folder or
    /// permissions, every schedule in the flow goes off until the person turns it on again.
    private func disarmSchedules(changedFrom old: Flow) {
        let armed = flow.cards.filter { $0.kind == .start && isArmed($0) }
        guard !armed.isEmpty else { return }
        let agentsChanged = flow.cards.contains { card in
            guard card.kind == .agent, let was = old.card(card.id) else { return card.kind == .agent }
            return card.instructions != was.instructions || card.cwd != was.cwd || card.permissionMode != was.permissionMode
        }
        guard agentsChanged else { return }
        for card in armed { ScheduleArming.arm(nil, command: "", scope: allowScope, cardID: card.id) }
        append("The orchestrator changed what the flow does, so its schedule is off until you turn it on again")
        banner = "The schedule is off: the orchestrator changed what the flow does. Turn it on again in the Start card's settings."
        reschedule()
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
