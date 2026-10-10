import Foundation
import QueenBeeCore

/// What a model's tokens cost, in dollars per million, for pricing the turns Claude Code hasn't totalled yet.
nonisolated struct ModelPrice: Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double

    // Writing to the cache costs a multiple of the input price: 1.25 times for a five-minute
    // entry, twice for a one-hour one.
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2 }

    /// Anthropic's API prices as of October 2026, by the start of a model's id, most specific
    /// first. They were checked against the totals Claude Code itself recorded for Opus 5.5 and
    /// Haiku 5.5 sessions. A model that isn't listed is counted in tokens and priced at nothing.
    private static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-5", ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4", ModelPrice(input: 1, output: 5, cacheRead: 0.10)),
    ]

    static func of(_ model: String) -> ModelPrice? {
        table.first { model.hasPrefix($0.prefix) }?.price
    }
}

/// Reads a session's usage from the transcript Claude Code keeps. Claude Code works the cost
/// out itself and writes a running total there, but only when a session's process ends. So
/// the figure is that total, plus an estimate for the replies since, priced from `ModelPrice`.
enum UsageReader {
    /// How far into a transcript has been read, and what it added up to. A transcript only
    /// grows, so each read takes in what was written since the last one.
    private struct Progress {
        var path: String
        var offset: UInt64 = 0
        var banked = Usage()
        var latest = Usage()
        /// Replies written since Claude Code's last total, by message id. A reply is written
        /// in several lines as it streams, each with the usage so far, so the last one counts.
        var since: [String: Usage] = [:]
    }

    private nonisolated(unsafe) static var progress: [String: Progress] = [:]
    private nonisolated static let lock = NSLock()

    /// The session's usage so far, or nil when it has no transcript yet.
    nonisolated static func usage(sessionID: String) -> Usage? {
        lock.lock()
        defer { lock.unlock() }
        var state: Progress
        if let known = progress[sessionID], FileManager.default.fileExists(atPath: known.path) {
            state = known
        } else if let url = transcript(for: sessionID) {
            state = Progress(path: url.path)
        } else {
            return nil
        }
        guard let handle = FileHandle(forReadingAtPath: state.path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // A file shorter than what was read has been replaced: start again.
        if size < state.offset { state = Progress(path: state.path) }
        try? handle.seek(toOffset: state.offset)

        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            // Whole lines only. A line still being written is left for the next read.
            while let newline = carry.firstIndex(of: 0x0A) {
                let line = carry[carry.startIndex..<newline]
                state.offset += UInt64(line.count + 1)
                carry = carry[carry.index(after: newline)...]
                take(Data(line), into: &state)
            }
        }
        progress[sessionID] = state
        return state.since.values.reduce(state.banked + state.latest, +)
    }

    /// Adds one line of a transcript to the running figures, if it is one of Claude Code's cost entries.
    private nonisolated static func take(_ line: Data, into state: inout Progress) {
        if line.range(of: Data("\"cost-state\"".utf8)) == nil {
            takeReply(line, into: &state)
            return
        }
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "cost-state" else { return }
        // Claude Code's own total takes in every reply up to here.
        state.since.removeAll()
        var now = Usage(cost: entry["totalCostUSD"] as? Double ?? 0)
        for (_, model) in entry["modelUsage"] as? [String: [String: Any]] ?? [:] {
            now.input += model["inputTokens"] as? Int ?? 0
            now.output += model["outputTokens"] as? Int ?? 0
            now.cacheRead += model["cacheReadInputTokens"] as? Int ?? 0
            now.cacheWrite += model["cacheCreationInputTokens"] as? Int ?? 0
        }
        // Each process the session has run in keeps its own running total. A total that falls
        // means a new process began from nothing, so what the last one reached is banked.
        if now.cost < state.latest.cost || now.tokens < state.latest.tokens { state.banked = state.banked + state.latest }
        state.latest = now
    }

    /// Prices one of the agent's replies from the token counts the API returned with it.
    private nonisolated static func takeReply(_ line: Data, into state: inout Progress) {
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "assistant",
              let message = entry["message"] as? [String: Any],
              let id = message["id"] as? String,
              let used = message["usage"] as? [String: Any] else { return }
        var reply = Usage()
        reply.input = used["input_tokens"] as? Int ?? 0
        reply.output = used["output_tokens"] as? Int ?? 0
        reply.cacheRead = used["cache_read_input_tokens"] as? Int ?? 0
        reply.cacheWrite = used["cache_creation_input_tokens"] as? Int ?? 0
        if let price = ModelPrice.of(message["model"] as? String ?? "") {
            let split = used["cache_creation"] as? [String: Any]
            let hour = split?["ephemeral_1h_input_tokens"] as? Int ?? 0
            // Anything not marked as a one-hour entry is the shorter, cheaper kind.
            let short = max(0, reply.cacheWrite - hour)
            let dollars = Double(reply.input) * price.input + Double(reply.output) * price.output
                + Double(reply.cacheRead) * price.cacheRead + Double(hour) * price.cacheWrite1h + Double(short) * price.cacheWrite5m
            // Fast mode is billed at twice the usual rate.
            reply.cost = dollars / 1_000_000 * ((used["speed"] as? String) == "fast" ? 2 : 1)
        }
        state.since[id] = reply
    }

    private nonisolated static func transcript(for sessionID: String) -> URL? {
        // A session id is a UUID. Anything else is not used to build a path.
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent("\(sessionID).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
