import QueenBeeCore

/// Where the bytes for each session's terminal go. For now it only counts them, so there is something to
/// check; the terminals themselves come later.
final class TerminalRegistry {
    /// How many bytes each session has been sent since its flow was opened, by session key.
    private(set) var received: [String: Int] = [:]

    func receive(_ event: TerminalEvent) {
        received[event.key, default: 0] += event.chunk.data.count
    }

    /// The flow on show has changed, or there is no Mac any more: every terminal is thrown away.
    func reset() {
        received.removeAll()
    }
}
