import Foundation

/// What links carried in the run on show. Each message is kept cut short, which is what is shown, saved in
/// the history and sent to a paired device. The newest messages are also kept whole, beside it, because Retry
/// and "run from here" give a card its message again and must give all of it.
public enum CarriedMessages {
    /// How much of each message is shown and saved with a run.
    public static let shownLength = 8_000
    /// How many messages each link keeps.
    public static let perLink = 10

    /// Adds a message a link carried. `whole` holds the full text of every kept message that was cut short,
    /// by the message's id, and loses those that are no longer kept.
    public static func add(_ text: String, from: String, at date: Date, link: String,
                           to shown: inout [String: [LinkMessage]], whole: inout [UUID: String]) {
        let message = LinkMessage(date: date, from: from, text: String(text.prefix(shownLength)))
        if message.text.count < text.count { whole[message.id] = text }
        var carried = shown[link] ?? []
        carried.append(message)
        for dropped in carried.dropLast(perLink) { whole[dropped.id] = nil }
        shown[link] = Array(carried.suffix(perLink))
    }

    /// The message as it was carried, all of it when it was kept whole.
    public static func whole(_ message: LinkMessage, from whole: [UUID: String]) -> LinkMessage {
        guard let text = whole[message.id] else { return message }
        var full = LinkMessage(date: message.date, from: message.from, text: text)
        full.id = message.id
        return full
    }

    /// The whole texts that still belong to a message in `shown`.
    public static func kept(_ whole: [UUID: String], for shown: [String: [LinkMessage]]) -> [UUID: String] {
        let ids = Set(shown.values.joined().map(\.id))
        return whole.filter { ids.contains($0.key) }
    }
}

/// Lets the Flow cards that run one flow take turns, and makes each wait out a run of that flow that was
/// started some other way: by the person, a schedule or a paired device. A flow has one run at a time.
@MainActor
public final class RunTurns {
    private var taken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// True while a Flow card's run of the flow has its turn.
    public var isTaken: Bool { taken }

    /// Waits until no other Flow card has the turn and `isFree` holds, then takes the turn. Returns false,
    /// without the turn, when the task is cancelled first. Whoever owns the flow calls `somethingEnded` whenever
    /// `isFree` may have changed, so this looks again.
    public func take(whenFree isFree: () -> Bool) async -> Bool {
        while taken || !isFree() {
            if Task.isCancelled { return false }
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiting.append($0) }
            } onCancel: {
                Task { @MainActor in self.somethingEnded() }
            }
        }
        taken = true
        return true
    }

    /// The Flow card's run is over: the next in line may go.
    public func release() {
        taken = false
        somethingEnded()
    }

    /// Wakes everyone waiting, so each looks again whether it may go.
    public func somethingEnded() {
        let woken = waiting
        waiting.removeAll()
        woken.forEach { $0.resume() }
    }
}

/// Why a Flow card must not run a flow, or nil when it may. A run never goes deeper than the flow at its top
/// allows, and never into a flow it is already inside, which would wait on itself for ever.
public func subflowRefusal(running inner: String, named name: String, levelsLeft: Int, inside: Set<String>) -> String? {
    if levelsLeft < 1 { return "\(name) wasn't run: it is deeper than the sub-flow limit of the flow this run started from." }
    if inside.contains(inner) { return "\(name) wasn't run: this run is already inside it, and a flow can't run itself." }
    return nil
}

/// Writes one file at a time, and never an older version over a newer one. Saves are asked for from many
/// places and done in the background, where they can finish out of order.
public actor LatestWins {
    private var written: [URL: Int] = [:]

    public init() {}

    /// A number for a version about to be written, higher than any before it. Taken where the version is made,
    /// in the order the versions were made.
    public nonisolated func ticket() -> Int { counter.next() }
    private nonisolated let counter = Counter()

    /// Writes `data` to `url`, unless a version with a higher ticket has been written there already.
    /// Returns whether it was written.
    @discardableResult
    public func write(_ data: @Sendable () throws -> Data, ticket: Int, to url: URL) -> Bool {
        guard ticket > written[url, default: Int.min] else { return false }
        guard let bytes = try? data() else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? bytes.write(to: url, options: .atomic)) != nil else { return false }
        written[url] = ticket
        return true
    }

    /// Forgets what was written to `url`, for a file that has been deleted.
    public func forget(_ url: URL) { written[url] = nil }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

/// The most a run of a flow may spend. The app reckons what its agents have used since the run began, at API
/// prices, each time an agent's turn ends, and stops the run once that is past the flow's limit.
public enum SpendingLimit {
    /// The smallest and largest limit a flow may have, in dollars.
    public static let range = 0.01...10_000.0

    /// A limit as it is kept: within the range, to the cent, and nil for none or for nothing that is a number.
    public static func clamped(_ dollars: Double?) -> Double? {
        guard let dollars, dollars.isFinite, dollars > 0 else { return nil }
        return (min(max(dollars, range.lowerBound), range.upperBound) * 100).rounded() / 100
    }

    /// The line the log gives a run stopped for spending `spent` against `limit`, or nil while it may go on.
    public static func passed(limit: Double?, spent: Usage) -> String? {
        guard let limit = clamped(limit), spent.cost > limit else { return nil }
        return "Run stopped: its agents had spent about \(spent.price), more than this flow's limit of \(Usage(cost: limit).price) for one run"
    }
}

/// How long an Approval card waits for the person, and a Script card for its command to be allowed, before the
/// card answers for them.
public enum HoldTimeLimit {
    /// The longest a card may be set to wait: a week, in minutes.
    public static let longestMinutes = 7 * 24 * 60

    /// How long `card` waits before answering, or nil when it waits for good.
    public static func wait(for card: Card) -> Duration? {
        guard card.kind == .approval || card.kind == .script, let minutes = card.waitMinutes, minutes > 0 else { return nil }
        return .seconds(min(minutes, longestMinutes) * 60)
    }

    /// The output the card takes when nobody answered in time. A Script card never runs a command nobody allowed.
    public static func port(for card: Card) -> String {
        card.kind == .approval && card.whenNoAnswer == "approved" ? "approved" : card.kind == .approval ? "rejected" : "fail"
    }

    /// What the log says when the card answered for the person, such as "No answer after 8 hours, so it was rejected".
    public static func line(for card: Card) -> String {
        let after = "No answer after \(describe(minutes: min(card.waitMinutes ?? 0, longestMinutes)))"
        switch port(for: card) {
        case "approved": return "\(after), so it was approved"
        case "rejected": return "\(after), so it was rejected"
        default: return "\(after), so its command was not run"
        }
    }

    /// "45 minutes", "1 hour", "8 hours", "1 hour 30 minutes", "2 days".
    public static func describe(minutes: Int) -> String {
        func count(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        let days = minutes / (24 * 60), hours = minutes % (24 * 60) / 60, rest = minutes % 60
        let parts = [days > 0 ? count(days, "day") : nil, hours > 0 ? count(hours, "hour") : nil, rest > 0 ? count(rest, "minute") : nil]
        let said = parts.compactMap { $0 }.joined(separator: " ")
        return said.isEmpty ? count(0, "minute") : said
    }
}
