import QueenBeeCore
import UIKit

/// What is on its way to the Mac for the cards' browsers, in the order the person did it. Each thing goes
/// after the one before it has been answered, as keys for a terminal do, so a click's release never
/// overtakes its press. The pointer moving and scrolls are never answered, and go as soon as their turn comes.
///
/// Typing is gathered for a moment and sent as one insert. The pointer's newest place, and scrolls added
/// together, are let go at most `Remote.pointerStepsASecond` times a second.
final class BrowserInputQueue {
    fileprivate var waiting: [(card: String, action: RemoteBrowserAction, answered: ((String?) -> Void)?)] = []
    fileprivate var pump: Task<Void, Never>?
    fileprivate var text: (card: String, text: String)?
    fileprivate var textTimer: Task<Void, Never>?
    fileprivate var move: (card: String, mouse: RemoteMouse)?
    fileprivate var scroll: (card: String, x: Double, y: Double, dx: Double, dy: Double)?
    fileprivate var gatherer = PointerGatherer()
    fileprivate var pointerTimer: Task<Void, Never>?
    /// How long typing is gathered before it is sent.
    fileprivate static let gather: Duration = .milliseconds(30)

    /// Something is gathered, waiting or on its way.
    var isBusy: Bool { pump != nil || text != nil || move != nil || scroll != nil }

    func clear() {
        pump?.cancel()
        textTimer?.cancel()
        pointerTimer?.cancel()
        // Whoever waits for an answer is told there won't be one.
        waiting.forEach { $0.answered?(RemoteClient.notConnected) }
        waiting = []
        pump = nil
        text = nil
        move = nil
        scroll = nil
    }
}

extension RemoteClient {
    /// Opens an agent card's browser full screen, or with nil closes it. A terminal open full screen is closed first.
    func openBrowser(_ cardID: String?) {
        if cardID != nil { terminals.expand(nil) }
        if cardID == nil { browserInput.clear() }
        browsers.expand(cardID)
    }

    /// Something done in a card's browser that is answered: a click, a key, Back, an address. Goes after
    /// everything done before it. Returns what the Mac said: nil when it was done.
    @discardableResult
    func useBrowser(_ card: String, _ action: RemoteBrowserAction) async -> String? {
        await withCheckedContinuation { done in
            enqueueBrowser(card, action) { done.resume(returning: $0) }
        }
    }

    /// The pointer moved in a card's page: with the button held, a drag. Only the newest place is kept.
    func moveBrowserPointer(_ card: String, to mouse: RemoteMouse) {
        guard abilities.canAct else { return }
        let queue = browserInput
        if let held = queue.move, held.card != card { flushPointer() }
        queue.move = (card, mouse)
        pointerSoon()
    }

    /// A finger scrolled a card's page. Scrolls are added together until they may go.
    func scrollBrowser(_ card: String, at point: CGPoint, dx: Double, dy: Double) {
        guard abilities.canAct else { return }
        let queue = browserInput
        if let held = queue.scroll, held.card == card {
            queue.scroll = (card, Double(point.x), Double(point.y), held.dx + dx, held.dy + dy)
        } else {
            flushPointer()
            queue.scroll = (card, Double(point.x), Double(point.y), dx, dy)
        }
        pointerSoon()
    }

    /// Text from the keyboard for a card's page. A new line is the Return key.
    func typeInBrowser(_ card: String, _ typed: String) {
        // A courtesy, as every control's is: the Mac refuses a device that may only watch whatever it sends.
        guard abilities.canAct else { return }
        let lines = typed.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { pressInBrowser(card, "Enter") }
            guard !line.isEmpty else { continue }
            let queue = browserInput
            if let held = queue.text, held.card != card { flushText() }
            queue.text = (card, (queue.text?.text ?? "") + line)
            if queue.textTimer == nil {
                queue.textTimer = Task {
                    try? await Task.sleep(for: BrowserInputQueue.gather)
                    queue.textTimer = nil
                    self.flushText()
                }
            }
        }
    }

    /// One of the keys a touch keyboard lacks, or one from a real keyboard, by its name in `BrowserKey.named`.
    func pressInBrowser(_ card: String, _ name: String, modifiers: Int = 0) {
        enqueueBrowser(card, .key(name: name, modifiers: modifiers))
    }

    /// Copy, or Cut: the page's selected text, from the Mac, onto this device's clipboard.
    @discardableResult
    func copyFromBrowser(_ card: String, cut: Bool = false) async -> String? {
        browsers.copied[card] = nil
        let refusal = await useBrowser(card, .copy(cut: cut))
        if refusal == nil, let text = browsers.copied[card], !text.isEmpty { UIPasteboard.general.string = text }
        return refusal
    }

    /// Paste: what is on this device's clipboard, typed into the page as the Mac's paste does it.
    func pasteIntoBrowser(_ card: String) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        for piece in Self.pieces(of: Remote.plainText(text)) { enqueueBrowser(card, .text(piece)) }
    }

    /// Text cut into pieces the Mac takes, at most `Remote.browserTextLimit` bytes each, never inside a character.
    static func pieces(of text: String) -> [String] {
        var pieces: [String] = [], current = ""
        for character in text {
            if current.utf8.count + String(character).utf8.count > Remote.browserTextLimit {
                pieces.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: The queue

    private func enqueueBrowser(_ card: String, _ action: RemoteBrowserAction, answered: ((String?) -> Void)? = nil) {
        guard abilities.canAct else {
            answered?(mirror.canControl ? Self.notConnected : BrowserViewer.watchOnly)
            return
        }
        // What was gathered goes first: it was done first.
        flushPointer()
        if case .text = action {} else { flushText() }
        append(card, action, answered)
    }

    private func append(_ card: String, _ action: RemoteBrowserAction, _ answered: ((String?) -> Void)? = nil) {
        let queue = browserInput
        queue.waiting.append((card, action, answered))
        guard queue.pump == nil else { return }
        queue.pump = Task {
            while !Task.isCancelled, !queue.waiting.isEmpty {
                let (card, action, answer) = queue.waiting.removeFirst()
                guard let flowID = mirror.openFlowID else {
                    answer?(Self.notConnected)
                    continue
                }
                let command = RemoteCommand.browser(flowID: flowID, cardID: card, action: action)
                if action.isAnswered {
                    let refusal = await send(command)
                    browsers.refusals[card] = refusal
                    answer?(refusal)
                    // Typed late and out of step, keys could act on a page the person no longer sees.
                    if refusal != nil {
                        let dropped = queue.waiting.filter(\.action.isTyping)
                        queue.waiting.removeAll(where: \.action.isTyping)
                        dropped.forEach { $0.answered?(refusal) }
                    }
                } else {
                    sendStep(command)
                }
            }
            queue.pump = nil
        }
    }

    private func flushText() {
        let queue = browserInput
        queue.textTimer?.cancel()
        queue.textTimer = nil
        guard let held = queue.text else { return }
        queue.text = nil
        for piece in Self.pieces(of: held.text) { append(held.card, .text(piece)) }
    }

    private func pointerSoon() {
        let queue = browserInput
        if queue.gatherer.mayGo() { return flushPointer() }
        guard queue.pointerTimer == nil else { return }
        queue.pointerTimer = Task {
            try? await Task.sleep(for: .seconds(queue.gatherer.wait()))
            queue.pointerTimer = nil
            if queue.gatherer.mayGo() { self.flushPointer() } else { self.pointerSoon() }
        }
    }

    /// Sends the pointer's newest place and the scrolls gathered. A press or a key sends them first, whatever the pace.
    private func flushPointer() {
        let queue = browserInput
        if let move = queue.move {
            queue.move = nil
            append(move.card, .mouse(move.mouse))
        }
        if let scroll = queue.scroll {
            queue.scroll = nil
            append(scroll.card, .wheel(x: scroll.x, y: scroll.y, dx: scroll.dx, dy: scroll.dy))
        }
    }
}

private extension RemoteBrowserAction {
    var isTyping: Bool {
        switch self {
        case .text, .key: true
        default: false
        }
    }
}
