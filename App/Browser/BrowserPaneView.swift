import AppKit
import QueenBeeCore

/// The browser half of an agent card: a thin bar with back, forward, reload and the address, and under it a
/// live picture of the page that takes the person's clicks, scrolling and keys.
final class BrowserPaneView: NSView, NSTextFieldDelegate {
    static let barHeight: CGFloat = 26

    let tab: BrowserTab
    private let bar = FlippedView()
    private let barRule = NSView()
    private let backButton = BrowserPaneView.barButton("chevron.left", "Back")
    private let forwardButton = BrowserPaneView.barButton("chevron.right", "Forward")
    private let reloadButton = BrowserPaneView.barButton("arrow.clockwise", "Reload this page")
    private let address = NSTextField()
    let page: BrowserPageView
    /// Shown over the page when there is no page to show: the browser is starting, stopped or missing.
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let noticeButton = NSButton(title: "", target: nil, action: nil)
    private var noticeAction: (() -> Void)?

    override var isFlipped: Bool { true }

    /// The card is on screen and large enough to read, so the page is worth streaming.
    var isInView = false { didSet { if isInView != oldValue { tab.setStreaming(isInView && window != nil) } } }

    init(tab: BrowserTab) {
        self.tab = tab
        page = BrowserPageView(tab: tab)
        super.init(frame: .zero)
        wantsLayer = true

        bar.wantsLayer = true
        barRule.wantsLayer = true
        addSubview(page)
        addSubview(bar)
        addSubview(barRule)
        for (button, action) in [(backButton, #selector(goBack)), (forwardButton, #selector(goForward)), (reloadButton, #selector(reload))] {
            button.target = self
            button.action = action
            bar.addSubview(button)
        }
        address.font = Theme.mono(Theme.Size.caption)
        address.textColor = Theme.ink
        address.isBordered = false
        address.drawsBackground = false
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingTail
        address.cell?.usesSingleLineMode = true
        address.cell?.isScrollable = true
        address.placeholderString = "Type an address, or what to search for"
        address.delegate = self
        address.target = self
        address.action = #selector(openAddress)
        bar.addSubview(address)

        notice.font = Theme.sans(Theme.Size.body)
        notice.textColor = Theme.inkSecondary
        notice.alignment = .center
        addSubview(notice)
        noticeButton.bezelStyle = .rounded
        noticeButton.font = Theme.mono(Theme.Size.body)
        noticeButton.target = self
        noticeButton.action = #selector(runNoticeAction)
        addSubview(noticeButton)

        tab.onFrame = { [weak self] image in self?.page.show(image) }
        tab.onChange = { [weak self] in self?.refresh() }
        if let last = tab.lastFrame { page.show(last) }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func barButton(_ symbol: String, _ help: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = Theme.ink
        button.toolTip = help
        return button
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tab.setStreaming(isInView && window != nil)
    }

    /// The card's view is being thrown away. A newer view of the same card may already have taken the tab over.
    func letGo() {
        tab.setStreaming(false)
    }

    override func layout() {
        super.layout()
        let h = Self.barHeight
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        barRule.frame = CGRect(x: 0, y: h, width: bounds.width, height: 1)
        var x: CGFloat = 4
        for button in [backButton, forwardButton, reloadButton] {
            button.frame = CGRect(x: x, y: 2, width: 22, height: h - 4)
            x += 22
        }
        address.frame = CGRect(x: x + 6, y: (h - 15) / 2, width: max(0, bounds.width - x - 14), height: 15)
        page.frame = CGRect(x: 0, y: h + 1, width: bounds.width, height: max(0, bounds.height - h - 1))
        tab.setSize(page.bounds.size)

        let width = min(page.frame.width - 32, 300)
        let wanted = notice.sizeThatFits(NSSize(width: width, height: 200))
        noticeButton.sizeToFit()
        let total = wanted.height + (noticeButton.isHidden ? 0 : noticeButton.frame.height + 10)
        let top = page.frame.minY + max(8, (page.frame.height - total) / 2)
        notice.frame = CGRect(x: page.frame.midX - width / 2, y: top, width: width, height: wanted.height)
        noticeButton.frame.origin = CGPoint(x: page.frame.midX - noticeButton.frame.width / 2, y: top + wanted.height + 10)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        bar.layer?.backgroundColor = Theme.bar.cgColor
        barRule.layer?.backgroundColor = Theme.hairline.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Brings the bar and the notice in line with the tab and the browser behind it.
    private func refresh() {
        // What the person is typing in the address bar is theirs until they finish.
        if address.currentEditor() == nil, address.stringValue != tab.url { address.stringValue = tab.url }
        address.toolTip = tab.title.isEmpty ? nil : tab.title

        var words = ""
        var button = ""
        var action: (() -> Void)?
        weak var host = tab.host
        switch tab.hostState {
        case .missing:
            words = "This card's browser needs Chrome, and there isn't one on this Mac. Queen Bee can download a copy for its own use, about 150 MB."
            button = "Download"
            action = { host?.download() }
        case .downloading(let fraction):
            words = "Downloading the browser… \(Int(fraction * 100))%"
        case .failed(let reason):
            words = reason
            button = "Try again"
            action = { host?.restart() }
        case .stopped:
            words = "Browser stopped"
            button = "Restart"
            action = { host?.restart() }
        case .starting:
            words = "Starting the browser…"
        case .idle, .running:
            if !tab.isAttached, tab.lastFrame == nil { words = "Starting the browser…" }
        }
        let shows = !words.isEmpty
        if notice.stringValue != words { notice.stringValue = words }
        notice.isHidden = !shows
        noticeButton.isHidden = button.isEmpty
        if !button.isEmpty { noticeButton.title = button }
        noticeAction = action
        // A page left over from before the browser stopped would look live when it isn't.
        page.isCovered = shows
        needsLayout = true
    }

    @objc private func runNoticeAction() { noticeAction?() }
    @objc private func goBack() { Task { _ = try? await tab.back() } }
    @objc private func goForward() { Task { await tab.goForward() } }
    @objc private func reload() { tab.reload() }

    @objc private func openAddress() {
        let typed = address.stringValue
        window?.makeFirstResponder(page)
        Task {
            do {
                try await tab.openTyped(typed)
            } catch {
                // The address bar says why, until the next page change puts the address back.
                address.stringValue = (error as? BrowserError)?.description ?? "That page didn't open"
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        // Escape puts the page's address back and returns the keyboard to the page.
        address.abortEditing()
        address.stringValue = tab.url
        window?.makeFirstResponder(page)
        return true
    }
}

/// The page itself: the latest picture from the browser. A point in this view is the same point on the page,
/// because the page is laid out at this view's size.
final class BrowserPageView: NSView {
    private let tab: BrowserTab
    private var tracking: NSTrackingArea?
    var isCovered = false { didSet { if isCovered != oldValue { layer?.contents = isCovered ? nil : image } } }
    private var image: CGImage?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(tab: BrowserTab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
        layer?.backgroundColor = NSColor.white.cgColor
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ new: CGImage) {
        image = new
        guard !isCovered else { return }
        // A new picture replaces the old one at once: the default fade would smear a scrolling page.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = new
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Mouse

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// The held modifier keys, as Chrome's remote control counts them.
    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) | (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        tab.mouse("mousePressed", at: point(event), button: "left", buttons: 1, clicks: event.clickCount, modifiers: Self.modifiers(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        tab.mouse("mouseMoved", at: point(event), button: "left", buttons: 1, modifiers: Self.modifiers(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        tab.mouse("mouseReleased", at: point(event), button: "left", clicks: event.clickCount, modifiers: Self.modifiers(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        // Pages react to the pointer, but only one the person is working in gets told where it is.
        guard window?.firstResponder === self else { return }
        tab.mouse("mouseMoved", at: point(event), modifiers: Self.modifiers(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        // A trackpad reports points. A wheel reports lines, which are scaled up to feel alike.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        tab.wheel(at: point(event), dx: -event.scrollingDeltaX * scale, dy: -event.scrollingDeltaY * scale,
                  modifiers: Self.modifiers(event.modifierFlags))
    }

    // MARK: Keys

    private static let special: [UInt16: String] = [
        36: "Enter", 76: "Enter", 48: "Tab", 53: "Escape", 51: "Backspace", 117: "Delete", 49: "Space",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
    ]

    private static func key(for event: NSEvent) -> BrowserKey? {
        if let name = special[event.keyCode] { return BrowserKey.named(name) }
        guard let typed = event.characters, let first = typed.first else { return nil }
        // Function keys arrive as characters from a private range that no page can show.
        if let scalar = first.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) { return nil }
        var key = BrowserKey.typing(first)
        // The codes come from the key as it is without Shift or Option; the text is what it types with them.
        if let plain = event.charactersIgnoringModifiers?.first {
            let base = BrowserKey.typing(plain)
            key.code = base.code
            key.keyCode = base.keyCode
        }
        key.text = typed
        return key
    }

    override func keyDown(with event: NSEvent) {
        guard let key = Self.key(for: event) else { return }
        tab.key(down: true, key, modifiers: Self.modifiers(event.modifierFlags))
    }

    override func keyUp(with event: NSEvent) {
        guard let key = Self.key(for: event) else { return }
        tab.key(down: false, key, modifiers: Self.modifiers(event.modifierFlags))
    }

    /// Copy, paste and the rest reach the page while it has the keyboard. Anything else stays a menu shortcut.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]) == .command,
              let letter = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch letter {
        case "a": edit("a", "selectAll")
        case "z": edit("z", shift ? "redo" : "undo", shift: shift)
        case "c": copySelection()
        case "x": copySelection(thenDelete: true)
        case "v":
            if let text = NSPasteboard.general.string(forType: .string) { tab.insert(text: text) }
        case "r": tab.reload()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func edit(_ letter: Character, _ command: String, shift: Bool = false) {
        let key = BrowserKey.typing(letter)
        let modifiers = 4 | (shift ? 8 : 0)
        tab.key(down: true, key, modifiers: modifiers, commands: [command])
        tab.key(down: false, key, modifiers: modifiers)
    }

    /// Copy, and Cut when `thenDelete` is set. The text is fetched before anything is deleted, or there would
    /// be nothing left to fetch.
    private func copySelection(thenDelete: Bool = false) {
        Task {
            let text = await tab.selectedText()
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if thenDelete { edit("x", "delete") }
        }
    }
}
