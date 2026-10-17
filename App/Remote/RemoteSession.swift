import Foundation
import ImageIO
import Observation
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

    /// The browser cards of the open flow the device has on screen, by card id. See `watchBrowsers`.
    private var browsers: [String: BrowserWatch] = [:]
    /// Pictures of pages sent, and dropped for newer ones, and the bytes sent, for a test and for measuring.
    private(set) var framesSent = 0
    fileprivate(set) var framesDropped = 0
    private(set) var pictureBytes = 0
    #if DEBUG
    /// The most that has been queued for the device at once, for a test to see that pictures don't pile up.
    private(set) var mostQueued = 0
    var queuedNow: Int { queuedBytes }
    var watchedBrowsers: [String] { browsers.keys.sorted() }
    var picturesDropped: Int { framesDropped + browsers.values.reduce(0) { $0 + $1.pacer.dropped } }
    func resetMostQueued() { mostQueued = queuedBytes }
    #endif
    private var turn = 0

    init(connection: LinkConnection, device: PairedDevice) {
        self.connection = connection
        self.device = device
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
        guard !isClosed, let frame = try? Remote.encode(message) else { return false }
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
        while let message = try? await connection.receive(DeviceMessage.self) {
            received += 1
            switch message {
            // Asking again for the flow already open would send the whole of it and every screen again.
            case .open(let flowID) where flowID == controller?.flow.id: break
            case .open(let flowID): open(flowID.flatMap { id in AppServices.shared.allFlows.first { $0.flow.id == id } })
            case .hello: break
            case .watchBrowsers(let flowID, let cardIDs): watchBrowsers(flowID, cardIDs)
            // A card's browser is used only while this device has it on screen, and Copy's text comes back here.
            case .command(let id, let command) where Self.isBrowser(command):
                answer(id, command, await RemoteCommands.obey(command, from: device.id, browser: browserDoor))
            case .command(let id, let command) where command.canTakeTime: obeyInTurn(id, command)
            // An edit sent after a Run that hasn't begun yet waits its turn behind it, so the run starts with
            // the flow as it was when Run was pressed. Keys and answers don't wait: a run can be starting for a while.
            case .command(let id, let command) where command.isEdit && command.flowID.map({ slow[$0] != nil }) == true: obeyInTurn(id, command)
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
    }

    /// Starts or stops a run without making the device wait to be heard: starting can take as long as judging
    /// a condition does, and Stop, keys and everything else it sends meanwhile are still read and obeyed.
    /// Those for one flow are done in the order they came, so a Stop sent after a Run stops that run, and so
    /// are the edits to that flow that arrive while any of them is still waiting.
    /// Whether the device may control the Mac is asked when each one's turn comes, not when it arrived.
    private func obeyInTurn(_ id: Int, _ command: RemoteCommand) {
        guard let flowID = command.flowID else { return }
        let deviceID = device.id
        turn += 1
        let mine = turn
        slow[flowID] = (mine, Task { [weak self, earlier = slow[flowID]?.task] in
            await earlier?.value
            let refusal = await RemoteCommands.obey(command, from: deviceID)
            guard let self else { return }
            if self.slow[flowID]?.turn == mine { self.slow[flowID] = nil }
            // A connection that has closed since is told nothing: `send` drops it.
            self.answer(id, command, refusal)
        })
    }

    /// "Can control" was changed in Settings while the device was connected.
    func controlChanged(_ on: Bool) {
        // A drag it had going ends here, not at whatever it sends next.
        if !on { RemoteCommands.endDrag(of: device.id) }
        device.canControl = on
        send(.control(canControl: on))
    }

    func close() {
        open(nil)
        stopWatchingBrowsers()
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
        RemoteSnapshot.updates(from: old, to: new, revision: revision).forEach(send)
        last = new
        followTerminals()
        // A card watched may have lost its browser, or gone.
        if !browsers.isEmpty { watchBrowsers(new.flow.id, Array(browsers.keys)) }
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
    /// pictures go at.
    final class BrowserWatch {
        let cardID: String
        let tab: BrowserTab
        var token: UUID?
        var pacer = FramePacer<StreamFrame>()
        /// What the device was last told of the card's bar and notice.
        var told: RemoteBrowserPage?
        /// Waits for the time the held picture may go.
        var wait: Task<Void, Never>?

        init(cardID: String, tab: BrowserTab) { self.cardID = cardID; self.tab = tab }
    }

    private static func isBrowser(_ command: RemoteCommand) -> Bool {
        if case .browser = command { return true }
        return false
    }

    /// What a card's browser commands need of this connection: which cards it is watching, and a way back for Copy.
    private var browserDoor: RemoteCommands.BrowserDoor {
        RemoteCommands.BrowserDoor(isWatching: { [weak self] in self?.browsers[$0] != nil }, send: { [weak self] in self?.send($0) })
    }

    /// The device said which browser cards of its open flow are on its screen. Only those are sent pictures.
    /// Anything for a flow it doesn't have open is let go: it has just opened another.
    func watchBrowsers(_ flowID: String, _ cardIDs: [String]) {
        guard let controller, controller.flow.id == flowID else { return stopWatchingBrowsers() }
        let wanted = Set(cardIDs.prefix(Remote.browserWatchLimit))
        for (id, watch) in browsers where !wanted.contains(id) || controller.browserTab(forCard: id) !== watch.tab {
            stopWatching(watch)
        }
        for id in wanted where browsers[id] == nil {
            // A card with its Browser switch off has no tab, and nothing to watch.
            guard let tab = controller.browserTab(forCard: id) else { continue }
            let watch = BrowserWatch(cardID: id, tab: tab)
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
        framesDropped += watch.pacer.dropped
        watch.pacer = FramePacer()
        if browsers[watch.cardID] === watch { browsers[watch.cardID] = nil }
    }

    /// Sends the card's bar and notice, if they have changed since the device was last told.
    private func tell(_ watch: BrowserWatch) {
        guard browsers[watch.cardID] === watch, let flowID = controller?.flow.id else { return }
        let page = watch.tab.remotePage
        guard page != watch.told else { return }
        watch.told = page
        send(.browserPage(id: flowID, card: watch.cardID, page: page))
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
        guard let watch = browsers[cardID] else { return }
        watch.pacer.delivered()
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
