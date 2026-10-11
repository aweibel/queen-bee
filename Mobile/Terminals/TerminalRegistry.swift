import Observation
import QueenBeeCore
import UIKit

/// One session's terminal on this device: the view, and what it has been fed.
final class MirrorTerminal {
    let key: String
    let mount = TerminalMount()
    private(set) var follower = TerminalFollower()

    init(key: String) { self.key = key }

    /// Does with a chunk what the Mac's notes say a device must. True if the terminal's size changed.
    func apply(_ chunk: TerminalChunk) -> Bool {
        let before = (follower.cols, follower.rows)
        for step in follower.steps(for: chunk) {
            switch step {
            case .start(let cols, let rows):
                // A fresh start leaves nothing behind: the size first, then the screen and its modes, then
                // the earlier output. In this order, as the Mac's own second terminal does it.
                mount.size(cols: cols, rows: rows)
                mount.terminal.resetToInitialState()
                mount.terminal.clearScrollback()
            case .resize(let cols, let rows):
                mount.size(cols: cols, rows: rows)
            case .feed(let data):
                mount.terminal.feed(byteArray: [UInt8](data)[...])
            }
        }
        return before != (follower.cols, follower.rows)
    }
}

/// The terminals of the open flow, by session key: an agent card's id, or "orchestrator" for the session
/// that runs the flow. Each is made when its first bytes arrive and thrown away when the flow is closed.
@Observable
final class TerminalRegistry {
    static let orchestratorKey = "orchestrator"

    /// The size of each session's terminal in points, at the Mac's own type size. Having one is how the
    /// rest of the app knows a session has a terminal to show.
    private(set) var sizes: [String: CGSize] = [:]
    /// The session whose terminal is open full screen. Its card or panel goes without until it is closed.
    private(set) var expandedKey: String?

    @ObservationIgnored private var terminals: [String: MirrorTerminal] = [:]
    /// Called when a terminal has come, gone or moved, so the canvas can put the right one in each card.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called when the terminal that is open full screen has been fed more, so that view can keep up with it.
    @ObservationIgnored var onExpandedOutput: (() -> Void)?

    func receive(_ event: TerminalEvent) {
        let terminal: MirrorTerminal
        if let existing = terminals[event.key] {
            terminal = existing
        } else {
            terminal = MirrorTerminal(key: event.key)
            #if DEBUG
            terminal.mount.onChange = { [weak self] in self?.noteChange() }
            #endif
        }
        let resized = terminal.apply(event.chunk)
        // A chunk that gave the terminal no size leaves nothing worth keeping.
        guard terminal.follower.isSized else { return }
        let isNew = terminals[event.key] == nil
        terminals[event.key] = terminal
        if isNew || resized { sizes[event.key] = terminal.mount.natural }
        if isNew { onChange?() }
        if event.key == expandedKey { onExpandedOutput?() }
        #if DEBUG
        noteChange()
        #endif
    }

    /// The flow on show has changed, or there is no Mac any more: every terminal is thrown away.
    func reset() {
        guard !terminals.isEmpty || expandedKey != nil else { return }
        terminals.values.forEach { $0.mount.removeFromSuperview() }
        terminals = [:]
        sizes = [:]
        expandedKey = nil
        onChange?()
        #if DEBUG
        noteChange()
        #endif
    }

    /// The terminal to put in a session's card or panel. Nil if it has none yet, or it is open full screen.
    func view(for key: String) -> TerminalMount? {
        key == expandedKey ? nil : terminals[key]?.mount
    }

    /// The terminal for the full-screen view, which is the one place that takes it while it is expanded.
    func expandedView(for key: String) -> TerminalMount? {
        key == expandedKey ? terminals[key]?.mount : nil
    }

    /// Opens a session's terminal full screen, or with nil closes it and gives the terminal back.
    func expand(_ key: String?) {
        guard key != expandedKey, key == nil || terminals[key ?? ""] != nil else { return }
        // Back to following the newest output, wherever it had been scrolled to.
        if let old = expandedKey, let mount = terminals[old]?.mount {
            mount.terminal.scroll(toPosition: 1)
            // The full-screen view zoomed it and let a finger scroll it. A card or a panel does neither.
            mount.transform = .identity
            mount.isUserInteractionEnabled = false
        }
        expandedKey = key
        onChange?()
        #if DEBUG
        noteChange()
        // A finger scrolling the terminal changes nothing else the app could go by, so while one is full
        // screen the state is written again every second.
        if key != nil {
            Task {
                while expandedKey == key {
                    try? await Task.sleep(for: .seconds(1))
                    noteChange()
                }
            }
        }
        #endif
    }

    #if DEBUG
    /// Goes up a moment after anything a test might read has changed. Output arrives many times a second,
    /// so the changes are gathered.
    private(set) var debugRevision = 0
    @ObservationIgnored private var debugPending = false

    private func noteChange() {
        guard !debugPending else { return }
        debugPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            debugPending = false
            debugRevision += 1
        }
    }

    /// Scrolls a terminal back by a number of lines, as a finger would.
    func debugScrollBack(_ key: String, lines: Int) {
        guard let mount = terminals[key]?.mount else { return }
        mount.terminal.scrollUp(lines: lines)
        noteChange()
    }

    /// What each terminal shows, read from the views themselves, for a script that can't see the screen.
    var debugState: [String: Any] {
        var all: [String: Any] = [:]
        for (key, terminal) in terminals {
            let view = terminal.mount.terminal
            let state = view.terminalStateSnapshot()
            let lines = String(decoding: view.getBufferAsData(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
            let dropped = view.droppedReplies
            let host = terminal.mount.superview
            all[key] = [
                "cols": state.dimensions.cols, "rows": state.dimensions.rows,
                "cursor": [state.cursor.col, state.cursor.row],
                // The rows on show, which are earlier ones when it has been scrolled back.
                "screen": state.visibleRows.map(\.text),
                "scrollback": max(0, lines.count - state.dimensions.rows),
                "chunks": terminal.follower.chunks, "resets": terminal.follower.resets, "bytes": terminal.follower.bytes,
                "droppedReplies": dropped.count, "droppedBytes": dropped.bytes,
                "expanded": key == expandedKey,
                "shown": host?.window != nil,
                "scale": terminal.mount.scale,
                // How many times the screen's own fineness it is drawn at.
                "sharpness": terminal.mount.sharpness,
                "natural": ["width": terminal.mount.natural.width, "height": terminal.mount.natural.height],
                "cell": ["width": terminal.mount.cell.width, "height": terminal.mount.cell.height],
                // Where the terminal's picture is on screen, to set against the card it is in.
                "onScreen": {
                    let r = terminal.mount.convert(CGRect(origin: .zero, size: CGSize(width: terminal.mount.natural.width * terminal.mount.scale,
                                                                                         height: terminal.mount.natural.height * terminal.mount.scale)), to: nil)
                    return ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
                }(),
                "isFirstResponder": view.isFirstResponder,
            ] as [String: Any]
        }
        return all
    }
    #endif
}
