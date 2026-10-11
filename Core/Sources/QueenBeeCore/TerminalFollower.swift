import Foundation

/// One thing a remote terminal does with what the Mac sent, in the order it must be done.
public enum TerminalStep: Equatable, Sendable {
    /// Start from nothing at this size: no screen, no earlier output, no modes left over.
    case start(cols: Int, rows: Int)
    /// Take this size and keep what is on screen.
    case resize(cols: Int, rows: Int)
    case feed(Data)
}

/// Follows one session's terminal: turns each chunk from the Mac into the steps a terminal on the device
/// takes. It holds no bytes, only the size the terminal has and a count of what has passed through.
public struct TerminalFollower: Equatable, Sendable {
    /// As large as a terminal is ever made here. A card on the Mac is a few hundred columns at the most, so
    /// anything past this is a mistake, and a terminal that size would take the device's memory with it.
    public static let largest = 1000

    /// The size the terminal has now. Zero until the first chunk.
    public private(set) var cols = 0
    public private(set) var rows = 0
    public private(set) var chunks = 0
    public private(set) var resets = 0
    public private(set) var bytes = 0

    public init() {}

    public var isSized: Bool { cols > 0 && rows > 0 }

    public mutating func steps(for chunk: TerminalChunk) -> [TerminalStep] {
        let sizeIsGood = (1 ... Self.largest).contains(chunk.cols) && (1 ... Self.largest).contains(chunk.rows)
        // With no size to go by, there is nothing to lay the bytes out on. The Mac's next fresh start puts it right.
        guard sizeIsGood || isSized else { return [] }
        chunks += 1
        bytes += chunk.data.count
        var steps: [TerminalStep] = []
        if sizeIsGood {
            // The first chunk normally says `reset`. One that doesn't still has to give the terminal its size.
            if chunk.reset || !isSized {
                steps.append(.start(cols: chunk.cols, rows: chunk.rows))
                if chunk.reset { resets += 1 }
            } else if chunk.cols != cols || chunk.rows != rows {
                steps.append(.resize(cols: chunk.cols, rows: chunk.rows))
            }
            cols = chunk.cols
            rows = chunk.rows
        } else if chunk.reset {
            // Told to start again at a size that can't be: start again at the size it has.
            steps.append(.start(cols: cols, rows: rows))
            resets += 1
        }
        if !chunk.data.isEmpty { steps.append(.feed(chunk.data)) }
        return steps
    }
}
