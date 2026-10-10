import Foundation
import Observation
import QueenBeeCore
import QueenBeeLink

/// One connected device: what it is sent, and the flow it has open.
final class RemoteSession {
    let connection: LinkConnection
    let device: PairedDevice
    private let outbox: AsyncStream<HostMessage>.Continuation
    private var pump: Task<Void, Never>?

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
        let (stream, continuation) = AsyncStream.makeStream(of: HostMessage.self)
        outbox = continuation
        // One sender, so messages leave in the order they were queued.
        pump = Task { [weak self] in
            for await message in stream {
                do { try await connection.send(message) } catch { connection.close(); return }
                self?.sent(message)
            }
        }
    }

    func send(_ message: HostMessage) { outbox.yield(message) }

    /// Called after each message has gone.
    private func sent(_ message: HostMessage) {
        guard case .terminal(_, _, let chunk) = message, !chunk.reset else { return }
        queuedTerminalBytes -= chunk.data.count
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
            case .open(let flowID): open(flowID.flatMap { id in AppServices.shared.allFlows.first { $0.flow.id == id } })
            case .hello: break
            }
        }
        close()
    }

    func close() {
        open(nil)
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
        let snapshot = Self.snapshot(of: new)
        last = snapshot
        send(.opened(snapshot))
        followTerminals()
        watch()
    }

    private static func snapshot(of controller: FlowController) -> RemoteFlowSnapshot {
        // Read so that a session being replaced counts as a change.
        _ = controller.sessionGeneration
        let run = RemoteRunState(
            isRunning: controller.isRunning, marks: controller.marks, linkPasses: controller.linkPasses,
            liveLinkIDs: controller.liveLinkIDs.sorted(), handOffs: controller.handOffs, holds: controller.holds,
            results: controller.results, usage: controller.usage, sessions: controller.sessions.mapValues(\.state),
            awaitingAnswer: controller.awaitingAnswer.sorted(), banner: controller.banner)
        return RemoteFlowSnapshot(flow: controller.flow, run: run, log: controller.log, messages: controller.messages,
                                  runs: controller.runs)
    }

    /// Asks to be told the next time anything a snapshot reads changes. It tells once, so each flush asks again.
    private func watch() {
        guard let controller else { return }
        withObservationTracking { _ = Self.snapshot(of: controller) } onChange: { [weak self] in
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
        let new = Self.snapshot(of: controller)
        if new.flow != old.flow { revision += 1 }
        RemoteSnapshot.updates(from: old, to: new, revision: revision).forEach(send)
        last = new
        followTerminals()
        watch()
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
        send(.terminal(id: flowID, key: key, chunk: chunk))
    }
}
