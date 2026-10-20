import Foundation
import ImageIO
import Observation
import OSLog
import UniformTypeIdentifiers
import QueenBeeCore
import QueenBeeLink

/// One connected device: what it is sent, and the flow it has open.
final class RemoteSession {
    let connection: LinkConnection
    /// The device as it was when it connected, kept up to date for what the Mac shows of it. Whether it may
    /// control the Mac is never taken from here: each command asks the list of devices afresh.
    private(set) var device: PairedDevice
    /// One message, already encoded, with how much terminal output it carries that counts towards the flood
    /// limit, and the card whose page it is a picture of, if it is one.
    private typealias Queued = (frame: Data, terminalBytes: Int, pictureOf: String?)
    private let outbox: AsyncStream<Queued>.Continuation
    private var pump: Task<Void, Never>?
    /// Bytes of every kind queued and not yet sent.
    private var queuedBytes = 0
    /// A device this far behind is dropped. It connects again and starts from what is true then, which
    /// costs less than the Mac holding everything it missed.
    private static let backlogLimit = 32 * 1024 * 1024
    private var isClosed = false
    /// True once this connection has been closed from here, and the drag it may have left going ended.
    private var hasGone = false

    /// The flow the device is looking at, what it was last told about it, and how many times the graph has changed.
    private var controller: FlowController?
    /// The name of the flow the device has open, for a test to check.
    var openFlowName: String? { controller?.flow.name }
    /// How many messages the device has sent since it was let in, for a test to check that a device
    /// watching terminals sends nothing because of them.
    private(set) var received = 0
    private var last: RemoteFlowSnapshot?
    private var revision = 0
    private var flushTask: Task<Void, Never>?
    /// At most this many updates a second, however fast a card is being dragged on the Mac.
    private static let flushEvery: Duration = .milliseconds(50)

    /// The terminals being followed, by session key, with the session each belongs to.
    private var feeds: [String: (session: TerminalSession, token: UUID)] = [:]
    /// Bytes of terminal output queued and not yet sent. Only output that follows on is counted. A chunk with
    /// `reset` is a whole screen with its history, up to about 576 KB a session, and a flow with eight
    /// sessions queues eight of them at once when it is opened: counted, they alone would pass the limit, and
    /// the fresh start that follows would pass it again, for ever. They come only when a flow is opened, a
    /// session starts or a card is resized, so a slow device can't make them pile up the way output can.
    private var queuedTerminalBytes = 0
    /// True while a device has fallen too far behind. Nothing more is queued for its terminals until what is
    /// already queued has gone, and then each terminal starts afresh.
    private var isFlooded = false
    private static let terminalBacklogLimit = 2_000_000

    /// The commands that can take time and haven't finished, by flow: the last one of each, which the next waits for.
    private var slow: [String: (turn: Int, task: Task<Void, Never>)] = [:]

    /// The browser cards of the open flow the device has on screen and is sent pictures of, by card id. See `watchBrowsers`.
    private var browsers: [String: BrowserWatch] = [:]
    /// The cards the device last said it has on screen, and in which flow. Only a device with "Can control" is sent
    /// anything of them, so this is kept while it has none, for the moment it is given it.
    private var wantedBrowsers: (flowID: String, cardIDs: [String])?
    /// Cards the device let go of a moment ago, with the pace their pictures and bar went at, until when they are
    /// kept. A card taken off the screen and put straight back is held to the pace it had.
    private var lettingGo: [String: (watch: BrowserWatch, until: Date)] = [:]
    /// How fast the device may say which cards it has on screen: each time can start pictures of up to sixteen pages.
    private var watchPace = TokenBucket(capacity: Remote.watchBurst, refill: Remote.watchesASecond)
    /// Waits for the pace to allow the newest of what the device said, when it said it too fast.
    private var watchLater: Task<Void, Never>?
    /// Pictures of pages sent, and dropped for newer ones, and the bytes sent, for a test and for measuring.
    private(set) var framesSent = 0
    fileprivate(set) var framesDropped = 0
    private(set) var pictureBytes = 0
    /// How many times the device was told a card's bar, and how many times what it said it has on screen was taken up.
    private(set) var pagesTold = 0
    private(set) var watchesTaken = 0
    #if DEBUG
    /// The most that has been queued for the device at once, for a test to see that pictures don't pile up.
    private(set) var mostQueued = 0
    var queuedNow: Int { queuedBytes }
    var watchedBrowsers: [String] { browsers.keys.sorted() }
    var picturesDropped: Int { framesDropped + (Array(browsers.values) + lettingGo.values.map(\.watch)).reduce(0) { $0 + $1.pacer.dropped } }
    /// How many changes to cards' bars were let go for newer ones.
    var pagesDropped: Int { (Array(browsers.values) + lettingGo.values.map(\.watch)).reduce(0) { $0 + $1.pages.dropped } }
    func resetMostQueued() { mostQueued = queuedBytes }
    #endif
    private var turn = 0
    /// The device's epoch, when it sends commands again after a drop and the Mac is to remember their answers.
    /// See `CommandMemory`.
    private let epoch: String?
    /// Whether the device takes the earlier runs as changes: see `RemoteFeature.historyChanges`.
    private let historyChanges: Bool
    /// True while a fresh copy of the open flow is being sent in place of a message that couldn't be.
    private var isResending = false

    init(connection: LinkConnection, device: PairedDevice, hello: RemoteHello) {
        self.connection = connection
        self.device = device
        epoch = hello.epoch.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        historyChanges = hello.has(RemoteFeature.historyChanges)
        let (stream, continuation) = AsyncStream.makeStream(of: Queued.self)
        outbox = continuation
        // One sender, so messages leave in the order they were queued.
        pump = Task { [weak self] in
            for await queued in stream {
                do { try await connection.send(queued.frame) } catch { connection.close(); return }
                self?.sent(queued)
            }
            // Everything queued has gone and nothing more will be. Closing a connection that is already closed does nothing.
            connection.close()
        }
    }

    func send(_ message: HostMessage) { queue(message, terminalBytes: 0) }

    /// Encoded here, once, so what is waiting can be counted as it is queued. False if it wasn't queued.
    @discardableResult
    private func queue(_ message: HostMessage, terminalBytes: Int, pictureOf card: String? = nil) -> Bool {
        guard !isClosed else { return false }
        let frame: Data
        do {
            frame = try Remote.encode(message)
        } catch {
            couldNotSend(message, error)
            return false
        }
        queuedBytes += frame.count
        guard queuedBytes <= Self.backlogLimit else {
            // Closing the connection ends `run`, and that tidies up. Doing it here would pull the flow out
            // from under whoever is part-way through queueing its terminals.
            isClosed = true
            outbox.finish()
            connection.close()
            return false
        }
        outbox.yield((frame, terminalBytes, card))
        #if DEBUG
        mostQueued = max(mostQueued, queuedBytes)
        #endif
        return true
    }

    /// A message couldn't be put into words for the device, as when a number in it isn't one JSON can hold. It is
    /// noted in the system log. A change to the open flow that is left out would leave the device showing a flow
    /// that is no longer the Mac's, so the whole flow is sent afresh in its place, as when the device opened it.
    private func couldNotSend(_ message: HostMessage, _ error: Error) {
        Self.log.error("Couldn't send \(Self.kind(of: message), privacy: .public) to a device: \(String(describing: error), privacy: .public)")
        switch message {
        case .opened, .flow, .run, .edit, .log, .messages, .history, .historyChanged:
            guard !isResending, let controller else { return }
            isResending = true
            defer { isResending = false }
            let fresh = watchedSnapshot(of: controller)
            last = fresh
            // If even that can't be sent, the device keeps what it had until the next change that can.
            queue(.opened(fresh), terminalBytes: 0)
        default:
            break
        }
    }

    private static let log = Logger(subsystem: "dev.queenbee.app", category: "remote")

    /// The name a message goes by, for the log. Never what it holds.
    private static func kind(of message: HostMessage) -> String { Mirror(reflecting: message).children.first?.label ?? "a message" }

    /// Called after each message has gone.
    private func sent(_ queued: Queued) {
        queuedBytes -= queued.frame.count
        if let card = queued.pictureOf { pictureSent(of: card, bytes: queued.frame.count) }
        guard queued.terminalBytes > 0 else { return }
        queuedTerminalBytes -= queued.terminalBytes
        if isFlooded, queuedTerminalBytes <= 0 {
            isFlooded = false
            queuedTerminalBytes = 0
            followTerminals()
        }
    }

    /// Reads what the device sends until the connection ends.
    func run() async {
        while let frame = try? await connection.receive() {
            received += 1
            guard let message = try? Remote.decode(DeviceMessage.self, from: frame) else {
                // From a newer device, as like as not. One message the Mac can't read is no reason to drop the
                // connection, and a command among them is told so, so its button doesn't wait for ever.
                if let id = Self.commandID(in: frame) { send(.answer(id: id, refusal: Self.unreadableRefusal)) }
                continue
            }
            if case .command(let id, let command) = message, command.isAnswered, let epoch {
                switch RemoteHost.shared.arrived(id, command, from: self, epoch: epoch) {
                case .new: break
                // Sent again after a drop while the first is still being done: told when it has been.
                case .running: continue
                // Done already: told what became of it, and not done again.
                case .done(let refusal):
                    send(.answer(id: id, refusal: refusal))
                    continue
                }
            }
            switch message {
            // Asking again for the flow already open would send the whole of it and every screen again.
            case .open(let flowID) where flowID == controller?.flow.id: break
            // A flow whose id another open project's flow has too is opened for neither: the device can't say which
            // it means. Its list marks such a flow and says why.
            case .open(let flowID): open(flowID.flatMap(AppServices.shared.deviceFlow))
            case .hello: break
            case .watchBrowsers(let flowID, let cardIDs): watchBrowsers(flowID, cardIDs)
            // Copy asks the page, which can take a while or never answer. It is given a few seconds of its own, and
            // what the device sends meanwhile is read and obeyed in the order it was sent.
            case .command(let id, let command) where Self.isCopy(command):
                let door = browserDoor, deviceID = device.id, epoch = epoch
                Task { [weak self] in
                    let refusal = await RemoteCommands.obey(command, from: deviceID, browser: door)
                    if let self { self.answer(id, command, refusal) } else { Self.remember(id, command, device: deviceID, epoch: epoch, refusal) }
                }
            // A card's browser is used only while this device has it on screen, and Copy's text comes back here.
            case .command(let id, let command) where Self.isBrowser(command):
                answer(id, command, await RemoteCommands.obey(command, from: device.id, browser: browserDoor))
            case .command(let id, let command) where command.canTakeTime: obeyInTurn(id, command)
            // An edit sent after a Run that hasn't begun yet waits its turn behind it, so the run starts with
            // the flow as it was when Run was pressed. Keys and answers don't wait: a run can be starting for a while.
            // Nor does turning a schedule on or off overtake an edit sent before it.
            case .command(let id, let command) where command.waitsWithEdits && command.flowID.map({ slow[$0] != nil }) == true: obeyInTurn(id, command)
            // Done before the next message is read, so edits are made, and what is typed arrives, in the order sent.
            case .command(let id, let command): answer(id, command, await RemoteCommands.obey(command, from: device.id))
            }
        }
        close()
    }

    /// Tells the device what became of a command. A step of a drag that isn't the last is never answered:
    /// there are twenty a second, and the last one says how the drag went.
    private func answer(_ id: Int, _ command: RemoteCommand, _ refusal: String?) {
        if command.isAnswered { send(.answer(id: id, refusal: refusal)) }
        Self.remember(id, command, device: device.id, epoch: epoch, refusal)
    }

    /// Keeps what became of a command for when the device sends it again, and tells any connection already
    /// waiting on it. Done even when the connection it came on has gone: that is when it is sent again.
    private static func remember(_ id: Int, _ command: RemoteCommand, device: String, epoch: String?, _ refusal: String?) {
        guard command.isAnswered, let epoch else { return }
        RemoteHost.shared.finished(id, device: device, epoch: epoch, refusal: refusal)
    }

    /// Tells the device what became of a command it sent again while the first was being done.
    func answerAgain(_ id: Int, _ command: RemoteCommand, _ refusal: String?) {
        if command.isAnswered { send(.answer(id: id, refusal: refusal)) }
    }

    /// What the Mac answers a command it couldn't read.
    static let unreadableRefusal = "Your Mac couldn't read this. Update Queen Bee on your Mac and on this device, so both are on the newest version."

    /// The id of a command the Mac couldn't otherwise read, so that it can still be answered.
    private static func commandID(in frame: Data) -> Int? {
        let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any]
        return ((object?["command"] as? [String: Any])?["id"] as? NSNumber)?.intValue
    }

    /// Starts or stops a run without making the device wait to be heard: starting can take as long as judging
    /// a condition does, and Stop, keys and everything else it sends meanwhile are still read and obeyed.
    /// Those for one flow are done in the order they came, so a Stop sent after a Run stops that run, and so
    /// are the edits to that flow that arrive while any of them is still waiting.
    /// Whether the device may control the Mac is asked when each one's turn comes, not when it arrived.
    ///
    /// Each is held to the pace it arrived at, counted as it arrives: counted when its turn came, every edit
    /// made while a run was slow to start would be counted at once and most of them refused. And no more than
    /// `waitingLimit` wait for one flow: past that they are refused at once, as coming too fast.
    private func obeyInTurn(_ id: Int, _ command: RemoteCommand) {
        guard let flowID = command.flowID else { return }
        let deviceID = device.id
        guard waiting[flowID, default: 0] < Self.waitingLimit else {
            // A step of a drag that isn't the last goes unanswered, so it is dropped. A drag whose last step is
            // refused here ends when the Mac hears no more of it, behind the steps still waiting.
            return answer(id, command, Remote.tooFastRefusal)
        }
        let paced = RemoteCommands.pace(command, from: deviceID)
        waiting[flowID, default: 0] += 1
        turn += 1
        let mine = turn
        slow[flowID] = (mine, Task { [weak self, earlier = slow[flowID]?.task, epoch] in
            await earlier?.value
            let refusal = await RemoteCommands.obey(command, from: deviceID, paced: paced)
            guard let self else { return Self.remember(id, command, device: deviceID, epoch: epoch, refusal) }
            self.waiting[flowID, default: 1] -= 1
            if self.waiting[flowID] == 0 { self.waiting[flowID] = nil }
            if self.slow[flowID]?.turn == mine { self.slow[flowID] = nil }
            // A connection that has closed since is told nothing: `send` drops it.
            self.answer(id, command, refusal)
        })
    }

    /// How many commands are waiting their turn for each flow, and the most that may.
    private var waiting: [String: Int] = [:]
    private static let waitingLimit = 200

    /// "Can control" was changed in Settings while the device was connected.
    func controlChanged(_ on: Bool) {
        // A drag it had going ends here, not at whatever it sends next.
        if !on { RemoteCommands.endDrag(of: device.id) }
        device.canControl = on
        send(.control(canControl: on))
        // Pictures of pages, their addresses and titles go only to a device with control: they stop at once without
        // it, and start again, for the cards the device has on screen, with it.
        applyWatch()
    }

    func close() {
        open(nil)
        stopWatchingBrowsers()
        watchLater?.cancel()
        lettingGo.removeAll()
        hasGone = true
        isClosed = true
        outbox.finish()
        connection.close()
    }

    /// Closes after telling the device why, in words it shows the person. Whatever was already queued goes
    /// first, then the reason, then the connection closes.
    func turnAway(_ reason: String) {
        guard !isClosed else { return }
        open(nil)
        hasGone = true
        send(.refused(reason))
        isClosed = true
        outbox.finish()
        // A device that has stopped reading would hold the connection open for ever.
        Task { [connection] in
            try? await Task.sleep(for: .seconds(2))
            connection.close()
        }
    }

    // MARK: The open flow

    private func open(_ new: FlowController?) {
        // Looking at another flow, or at none, or going altogether, ends a drag the device left going. A
        // connection that has already closed has none: the device may be dragging again on its next one.
        if !hasGone { RemoteCommands.endDrag(of: device.id) }
        // The cards it was watching are in the flow it left. The device says which it has on screen in the next.
        stopWatchingBrowsers()
        flushTask?.cancel()
        flushTask = nil
        unfollowTerminals()
        controller = new
        last = nil
        guard let new else { return }
        let snapshot = watchedSnapshot(of: new)
        last = snapshot
        send(.opened(snapshot))
        followTerminals()
    }

    /// Lets go of the open flow if it has been deleted on the Mac, or its project taken out of the sidebar.
    /// Holding on would keep the flow alive, and its terminals followed, with nobody able to see it.
    func dropFlowIfGone() {
        guard let controller, !AppServices.shared.allFlows.contains(where: { $0 === controller }) else { return }
        open(nil)
    }

    private static func snapshot(of controller: FlowController) -> RemoteFlowSnapshot {
        // Read so that a session being added, replaced or dropped counts as a change.
        _ = controller.sessionsRevision
        // What the Mac's "Not in use yet" line lists for each agent card, and its "Restart to apply" for the orchestrator.
        var awaiting: [String: [String]] = [:]
        for card in controller.flow.cards where card.kind == .agent {
            let pending = controller.settingsAwaitingRestart(forCard: card.id)
            if !pending.isEmpty { awaiting[card.id] = pending }
        }
        var runUsage: [String: Usage] = [:]
        for key in controller.usage.keys {
            if let used = controller.runUsage(forCard: key), !used.isZero { runUsage[key] = used }
        }
        let run = RemoteRunState(
            isRunning: controller.isRunning, marks: controller.marks, linkPasses: controller.linkPasses,
            liveLinkIDs: controller.liveLinkIDs.sorted(), handOffs: controller.handOffs, holds: controller.holds,
            results: controller.results, usage: controller.usage, sessions: controller.sessions.mapValues(\.state),
            awaitingAnswer: controller.awaitingAnswer.sorted(), banner: controller.banner, awaitingRestart: awaiting,
            orchestratorNeedsRestart: controller.orchestratorNeedsRestart, runUsage: runUsage)
        // Read so that a schedule turned on or off at the Mac counts as a change: which are on is not in the flow.
        _ = controller.schedulesRevision
        let armed = controller.flow.cards.filter { $0.kind == .start && controller.isArmed($0) }.map(\.id)
        let manager = controller.undoManager
        // The titles read the count that goes up whenever the undo stack changes, so that counts as a change too.
        let edit = RemoteEditState(undo: manager.canUndo ? controller.undoTitle : nil, redo: manager.canRedo ? controller.redoTitle : nil,
                                   armed: armed, nextFires: controller.nextFires.filter { armed.contains($0.key) })
        return RemoteFlowSnapshot(flow: controller.flow, run: run, edit: edit, log: controller.log, messages: controller.messages,
                                  runs: controller.runs)
    }

    /// The flow as it is now, and a request to be told the next time anything in it changes. It tells once,
    /// so each flush asks again by building its snapshot here.
    private func watchedSnapshot(of controller: FlowController) -> RemoteFlowSnapshot {
        withObservationTracking { Self.snapshot(of: controller) } onChange: { [weak self] in
            Task { @MainActor in self?.flushSoon() }
        }
    }

    private func flushSoon() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushEvery)
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flush()
        }
    }

    private func flush() {
        guard let controller, let old = last else { return }
        let new = watchedSnapshot(of: controller)
        if new.flow != old.flow { revision += 1 }
        RemoteSnapshot.updates(from: old, to: new, revision: revision, historyChanges: historyChanges).forEach(send)
        last = new
        followTerminals()
        // A card watched may have lost its browser, or gone, or gained one.
        if wantedBrowsers != nil { applyWatch() }
    }

    // MARK: Terminals

    /// Follows every terminal of the open flow that isn't followed yet: its screen as it is now, then
    /// everything after. A session that has gone or been replaced stops being followed. The ones already
    /// followed are left alone, so one session starting doesn't send every other screen again.
    private func followTerminals() {
        // A device that is behind gets nothing more until it has caught up. `sent` calls this again then.
        guard !isFlooded, let controller else { return }
        let flowID = controller.flow.id
        for (key, held) in feeds where controller.sessions[key] !== held.session {
            held.session.feed.removeListener(held.token)
            feeds[key] = nil
        }
        for (key, session) in controller.sessions where feeds[key] == nil {
            // The screen and the listener are taken together, with nothing awaited between, so no output is missed.
            queueTerminal(flowID, key, session.feed.snapshot())
            let token = session.feed.addListener { [weak self] chunk in self?.queueTerminal(flowID, key, chunk) }
            feeds[key] = (session, token)
        }
    }

    private func unfollowTerminals() {
        feeds.values.forEach { $0.session.feed.removeListener($0.token) }
        feeds.removeAll()
    }

    private func queueTerminal(_ flowID: String, _ key: String, _ chunk: TerminalChunk) {
        guard !isFlooded else { return }
        if !chunk.reset {
            // A device that can't keep up gets each screen afresh once the queue drains, not an ever-longer
            // backlog. The chunk that would pass the limit is left out of the count, because it is never
            // sent. With nothing queued there is no backlog to wait out, so a chunk always goes then.
            if queuedTerminalBytes > 0, queuedTerminalBytes + chunk.data.count > Self.terminalBacklogLimit {
                isFlooded = true
                unfollowTerminals()
                return
            }
            queuedTerminalBytes += chunk.data.count
        }
        queue(.terminal(id: flowID, key: key, chunk: chunk), terminalBytes: chunk.reset ? 0 : chunk.data.count)
    }
}

// MARK: Browsers

extension RemoteSession {
    /// One agent card's browser this device has on screen: its tab, the tab's note of it, and the pace its
    /// pictures and its bar go at.
    final class BrowserWatch {
        let cardID: String
        let tab: BrowserTab
        var token: UUID?
        var pacer = FramePacer<StreamFrame>()
        /// What the device was last told of the card's bar and notice, which is told at most four times a second.
        var told: RemoteBrowserPage?
        var pages = LatestThrottle<RemoteBrowserPage>(perSecond: Remote.browserPagesASecond)
        /// Waits for the time the held picture, or the held bar, may go.
        var wait: Task<Void, Never>?
        var pageWait: Task<Void, Never>?

        init(cardID: String, tab: BrowserTab) { self.cardID = cardID; self.tab = tab }
    }

    private static func isBrowser(_ command: RemoteCommand) -> Bool {
        if case .browser = command { return true }
        return false
    }

    private static func isCopy(_ command: RemoteCommand) -> Bool {
        if case .browser(_, _, .copy) = command { return true }
        return false
    }

    /// What a card's browser commands need of this connection: the flow it has open, which cards it is watching,
    /// and a way back for Copy.
    private var browserDoor: RemoteCommands.BrowserDoor {
        RemoteCommands.BrowserDoor(flowID: controller?.flow.id, isWatching: { [weak self] in self?.browsers[$0] != nil },
                                   send: { [weak self] in self?.send($0) })
    }

    /// Whether this device may be sent pictures of pages, and their addresses and titles: only with "Can control",
    /// asked of the list of devices as it is now. A page in a card can be one the person is signed in to.
    private var maySeePages: Bool {
        let host = RemoteHost.shared
        return host.isOn && host.devices.canControl(device.id)
    }

    /// The device said which browser cards of its open flow are on its screen. Only those are sent pictures, and
    /// only to a device with control. Said faster than its pace allows, the newest is taken up a moment later.
    func watchBrowsers(_ flowID: String, _ cardIDs: [String]) {
        wantedBrowsers = (flowID, Array(cardIDs.prefix(Remote.browserWatchLimit)))
        guard watchLater == nil else { return }
        guard watchPace.take() else {
            watchLater = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1 / Remote.watchesASecond))
                guard let self, !Task.isCancelled else { return }
                self.watchLater = nil
                if let wanted = self.wantedBrowsers { self.watchBrowsers(wanted.flowID, wanted.cardIDs) }
            }
            return
        }
        watchesTaken += 1
        applyWatch()
    }

    /// Watches the cards the device last said it has on screen, as far as it may now. Anything for a flow it
    /// doesn't have open is let go: it has just opened another.
    private func applyWatch() {
        let now = Date()
        for (id, kept) in lettingGo where kept.until <= now {
            framesDropped += kept.watch.pacer.dropped
            lettingGo[id] = nil
        }
        guard maySeePages, let controller, let wanted = wantedBrowsers, controller.flow.id == wanted.flowID else { return stopWatchingBrowsers() }
        let cards = Set(wanted.cardIDs)
        for (id, watch) in browsers where !cards.contains(id) || controller.browserTab(forCard: id) !== watch.tab {
            stopWatching(watch)
        }
        for id in wanted.cardIDs where browsers[id] == nil {
            // A card with its Browser switch off has no tab, and nothing to watch.
            guard let tab = controller.browserTab(forCard: id) else { continue }
            // One let go of a moment ago keeps its pace, so putting it back on screen sends nothing sooner.
            let kept = lettingGo.removeValue(forKey: id).flatMap { $0.watch.tab === tab ? $0.watch : nil }
            let watch = kept ?? BrowserWatch(cardID: id, tab: tab)
            // The device forgot the card's bar when it let go of it.
            watch.told = nil
            browsers[id] = watch
            watch.token = tab.addWatcher(frame: { [weak self, weak watch] frame in
                guard let self, let watch else { return }
                self.offer(frame, to: watch)
            }, change: { [weak self, weak watch] in
                guard let self, let watch else { return }
                self.tell(watch)
            })
            tell(watch)
            // The page may not change again for a long time, and the device has nothing to show until it does.
            if let last = tab.lastStream { offer(last, to: watch) }
        }
    }

    func stopWatchingBrowsers() {
        browsers.values.forEach(stopWatching)
    }

    private func stopWatching(_ watch: BrowserWatch) {
        watch.token.map(watch.tab.removeWatcher)
        watch.token = nil
        watch.wait?.cancel()
        watch.wait = nil
        watch.pageWait?.cancel()
        watch.pageWait = nil
        watch.pages.drop()
        if browsers[watch.cardID] === watch {
            browsers[watch.cardID] = nil
            lettingGo[watch.cardID] = (watch, Date().addingTimeInterval(Remote.watchKeep))
        }
    }

    /// Sends the card's bar and notice, if they have changed since the device was last told: at most four times a
    /// second, the newest, and with the address and title cut short.
    private func tell(_ watch: BrowserWatch) {
        guard browsers[watch.cardID] === watch else { return }
        let page = watch.tab.remotePage.capped
        guard page != watch.told else { return watch.pages.drop() }
        if let now = watch.pages.offer(page) { tellNow(now, watch) } else { tellLater(watch) }
    }

    private func tellNow(_ page: RemoteBrowserPage, _ watch: BrowserWatch) {
        guard let flowID = controller?.flow.id, page != watch.told else { return }
        watch.told = page
        pagesTold += 1
        send(.browserPage(id: flowID, card: watch.cardID, page: page))
    }

    private func tellLater(_ watch: BrowserWatch) {
        guard watch.pageWait == nil, let at = watch.pages.nextTry else { return }
        watch.pageWait = Task { [weak self, weak watch] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            guard let self, let watch, !Task.isCancelled else { return }
            watch.pageWait = nil
            guard self.browsers[watch.cardID] === watch else { return }
            if let page = watch.pages.due() { self.tellNow(page, watch) } else { self.tellLater(watch) }
        }
    }

    /// A new picture of a watched card's page. It goes now, or is held until it may, in place of any held before it.
    private func offer(_ frame: StreamFrame, to watch: BrowserWatch) {
        guard browsers[watch.cardID] === watch else { return }
        if let now = watch.pacer.offer(frame) { send(now, of: watch) } else { waitForTurn(watch) }
    }

    /// When the held picture is only waiting for the time to come, it is sent then.
    private func waitForTurn(_ watch: BrowserWatch) {
        guard watch.wait == nil, let at = watch.pacer.nextTry else { return }
        watch.wait = Task { [weak self, weak watch] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            guard let self, let watch, !Task.isCancelled else { return }
            watch.wait = nil
            if let frame = watch.pacer.due() { self.send(frame, of: watch) } else { self.waitForTurn(watch) }
        }
    }

    /// The picture on its way to the device has gone, so the newest held one may follow.
    fileprivate func pictureSent(of cardID: String, bytes: Int) {
        framesSent += 1
        pictureBytes += bytes
        // A card let go of while its picture was on the way keeps its pace for when it comes back.
        guard let watch = browsers[cardID] ?? lettingGo[cardID]?.watch else { return }
        watch.pacer.delivered()
        guard browsers[cardID] === watch else { return }
        if let frame = watch.pacer.due() { send(frame, of: watch) } else { waitForTurn(watch) }
    }

    /// Queues one picture, made smaller first if it is over the limit. That is done off the main thread.
    private func send(_ frame: StreamFrame, of watch: BrowserWatch) {
        let page = frame.pageSize.width > 0 ? frame.pageSize : watch.tab.pageSize
        let cardID = watch.cardID
        let fits = frame.jpeg.count <= Remote.browserFrameLimit
        Task { [weak self, weak watch] in
            let made: RemoteBrowserFrame? = fits
                ? RemoteBrowserFrame(jpeg: frame.jpeg, width: frame.image.width, height: frame.image.height, pageWidth: page.width, pageHeight: page.height)
                : await Task.detached(priority: .utility) { Self.shrunk(frame, page: page) }.value
            guard let self, let watch else { return }
            guard self.browsers[cardID] === watch, let flowID = self.controller?.flow.id, let made,
                  self.queue(.browserFrame(id: flowID, card: cardID, frame: made), terminalBytes: 0, pictureOf: cardID) else {
                watch.pacer.delivered()
                return
            }
        }
    }

    /// A picture made small enough to send: less fine first, then half the size.
    nonisolated private static func shrunk(_ frame: StreamFrame, page: CGSize) -> RemoteBrowserFrame? {
        let image = frame.image
        for (scale, quality) in [(1.0, 0.6), (1.0, 0.4), (0.5, 0.6), (0.5, 0.35)] {
            let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
            var source = image
            if scale != 1 {
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let small = context.makeImage() else { continue }
                source = small
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            if data.length <= Remote.browserFrameLimit {
                return RemoteBrowserFrame(jpeg: data as Data, width: width, height: height, pageWidth: page.width, pageHeight: page.height)
            }
        }
        return nil
    }
}
