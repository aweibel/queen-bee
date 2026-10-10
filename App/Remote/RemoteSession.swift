import Foundation
import Observation
import QueenBeeCore
import QueenBeeLink

/// One connected device: what it is sent, and the flow it has open.
final class RemoteSession {
    let connection: LinkConnection
    let device: PairedDevice
    /// One message, already encoded, with how much terminal output it carries that counts towards the flood limit.
    private typealias Queued = (frame: Data, terminalBytes: Int)
    private let outbox: AsyncStream<Queued>.Continuation
    private var pump: Task<Void, Never>?
    /// Bytes of every kind queued and not yet sent.
    private var queuedBytes = 0
    /// A device this far behind is dropped. It connects again and starts from what is true then, which
    /// costs less than the Mac holding everything it missed.
    private static let backlogLimit = 32 * 1024 * 1024
    private var isClosed = false

    /// The flow the device is looking at, what it was last told about it, and how many times the graph has changed.
    private var controller: FlowController?
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
        }
    }

    func send(_ message: HostMessage) { queue(message, terminalBytes: 0) }

    /// Encoded here, once, so what is waiting can be counted as it is queued.
    private func queue(_ message: HostMessage, terminalBytes: Int) {
        guard !isClosed, let frame = try? Remote.encode(message) else { return }
        queuedBytes += frame.count
        guard queuedBytes <= Self.backlogLimit else {
            // Closing the connection ends `run`, and that tidies up. Doing it here would pull the flow out
            // from under whoever is part-way through queueing its terminals.
            isClosed = true
            outbox.finish()
            connection.close()
            return
        }
        outbox.yield((frame, terminalBytes))
    }

    /// Called after each message has gone.
    private func sent(_ queued: Queued) {
        queuedBytes -= queued.frame.count
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
            switch message {
            // Asking again for the flow already open would send the whole of it and every screen again.
            case .open(let flowID) where flowID == controller?.flow.id: break
            case .open(let flowID): open(flowID.flatMap { id in AppServices.shared.allFlows.first { $0.flow.id == id } })
            case .hello: break
            }
        }
        close()
    }

    func close() {
        open(nil)
        isClosed = true
        outbox.finish()
        connection.close()
    }

    // MARK: The open flow

    private func open(_ new: FlowController?) {
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
        let run = RemoteRunState(
            isRunning: controller.isRunning, marks: controller.marks, linkPasses: controller.linkPasses,
            liveLinkIDs: controller.liveLinkIDs.sorted(), handOffs: controller.handOffs, holds: controller.holds,
            results: controller.results, usage: controller.usage, sessions: controller.sessions.mapValues(\.state),
            awaitingAnswer: controller.awaitingAnswer.sorted(), banner: controller.banner)
        return RemoteFlowSnapshot(flow: controller.flow, run: run, log: controller.log, messages: controller.messages,
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
