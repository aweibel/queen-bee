import Foundation
import QueenBeeCore

/// A session's terminal as bytes a remote terminal can be fed.
protocol TerminalFeed: AnyObject {
    /// Bytes that take a blank terminal to what this one shows now. Always has `reset` set.
    func snapshot() -> TerminalChunk
    /// `handler` is called on the main actor with each further chunk, until the token is removed.
    func addListener(_ handler: @escaping (TerminalChunk) -> Void) -> UUID
    func removeListener(_ token: UUID)
}

/// What a session's process printed lately, kept so a second terminal can be brought up to
/// date by being fed the same bytes. Written on the thread that reads the process, read on
/// the main one.
nonisolated final class OutputLog: @unchecked Sendable {
    /// How far past the limit the log may grow before it is cut back, so the cut is rare.
    private static let slack = 64 * 1024

    private let lock = NSLock()
    /// About how much is kept. Older output is dropped, so a terminal that joins late can
    /// scroll back only as far as this reaches.
    private var limit = 512 * 1024
    private var kept = Data()
    /// False once the oldest output has been dropped, so what is kept no longer starts from a blank terminal.
    private var whole = true
    /// What has been printed since it was last taken. Nil while nobody is following.
    private var fresh: Data?
    private var wake: (@Sendable () -> Void)?
    private var woken = false

    /// Adds what the process just printed. While nobody is following, this is all that happens.
    func append(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        kept.append(contentsOf: bytes)
        if kept.count > limit + min(limit, Self.slack) { trim() }
        var call: (@Sendable () -> Void)?
        if fresh != nil {
            fresh?.append(contentsOf: bytes)
            if !woken {
                woken = true
                call = wake
            }
        }
        lock.unlock()
        call?()
    }

    /// Drops the oldest output. The cut lands on the start of an escape sequence where one is
    /// near, so what is left doesn't open with the tail end of one.
    private func trim() {
        var cut = kept.startIndex + (kept.count - limit)
        if let escape = kept[cut ..< min(cut + 4096, kept.endIndex)].firstIndex(of: 0x1b) { cut = escape }
        kept.removeSubrange(kept.startIndex ..< cut)
        whole = false
    }

    /// Drops everything kept. Used when the terminal gets narrower: output laid out for the
    /// wider terminal comes out scrambled when a narrower one is fed it.
    func forget() {
        lock.withLock {
            guard !kept.isEmpty else { return }
            kept = Data()
            whole = false
        }
    }

    /// Everything kept, whether that goes back to a blank terminal, and what was waiting to
    /// be taken. From here on new output is collected, and `wake` is called off the main
    /// thread when there is some to take.
    func follow(wake: @escaping @Sendable () -> Void) -> (all: Data, whole: Bool, fresh: Data) {
        lock.withLock {
            let waiting = fresh ?? Data()
            fresh = Data()
            woken = false
            self.wake = wake
            return (kept, whole, waiting)
        }
    }

    /// What was printed since the last take.
    func takeFresh() -> Data {
        lock.withLock {
            woken = false
            guard let waiting = fresh else { return Data() }
            fresh = Data()
            return waiting
        }
    }

    /// Stops collecting new output.
    func unfollow() {
        lock.withLock {
            fresh = nil
            wake = nil
            woken = false
        }
    }

    #if DEBUG
    /// How many bytes are kept.
    var count: Int { lock.withLock { kept.count } }

    /// Lets a check make the log small enough to overflow.
    func setLimit(_ bytes: Int) { lock.withLock { limit = bytes } }
    #endif
}

/// The feed of a session's terminal: the output kept so far as the first chunk, and each
/// further batch of output as it is printed.
final class OutputFeed: TerminalFeed {
    private let log: OutputLog
    private let size: () -> (cols: Int, rows: Int)
    private var listeners: [UUID: (TerminalChunk) -> Void] = [:]
    private var following = false
    private var settling: Task<Void, Never>?

    init(log: OutputLog, size: @escaping () -> (cols: Int, rows: Int)) {
        self.log = log
        self.size = size
    }

    /// Whoever takes a snapshot must add its listener before giving up the main actor, or
    /// output printed in between is missed.
    func snapshot() -> TerminalChunk {
        let (first, waiting) = follow()
        // Listeners already here are owed what was waiting. The snapshot holds it too, so
        // whoever asked for it starts exactly where these have got to.
        if !waiting.isEmpty, settling == nil { send(chunk(waiting, reset: false)) }
        return first
    }

    func addListener(_ handler: @escaping (TerminalChunk) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        return token
    }

    func removeListener(_ token: UUID) {
        listeners[token] = nil
        if listeners.isEmpty { stop() }
    }

    /// The terminal has a new size. Output from before was laid out for the old one, so
    /// listeners start again from the top at the new size, once a drag has stopped moving.
    func sizeChanged() {
        guard !listeners.isEmpty else { return }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.settling = nil
            guard !self.listeners.isEmpty else { return }
            self.send(self.follow().first)
        }
    }

    /// Starts collecting new output. Returns the chunk that brings a blank terminal up to
    /// date, and the output that was waiting for the listeners already here.
    private func follow() -> (first: TerminalChunk, waiting: Data) {
        following = true
        let (all, whole, waiting) = log.follow { [weak self] in
            // A short wait gathers a burst of output into one chunk.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(16))
                self?.drain()
            }
        }
        var first = chunk(all, reset: true)
        // The program draws upwards from where it left the cursor. When the oldest output has
        // gone that is no longer the top of a blank terminal, and the bottom is the better guess.
        if !whole { first.data = Data("\u{1b}[\(first.rows);1H".utf8) + all }
        return (first, waiting)
    }

    private func drain() {
        guard following else { return }
        guard !listeners.isEmpty else { return stop() }
        // While a resize settles, output stays in the log: the fresh start will carry it.
        guard settling == nil else { return }
        let data = log.takeFresh()
        if !data.isEmpty { send(chunk(data, reset: false)) }
    }

    private func stop() {
        following = false
        settling?.cancel()
        settling = nil
        log.unfollow()
    }

    private func chunk(_ data: Data, reset: Bool) -> TerminalChunk {
        let size = size()
        return TerminalChunk(reset: reset, cols: size.cols, rows: size.rows, data: data)
    }

    private func send(_ chunk: TerminalChunk) {
        for handler in listeners.values { handler(chunk) }
    }
}
