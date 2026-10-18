import GameController
import QueenBeeCore
import SwiftUI
import UIKit

/// One agent card's browser, full screen: the Mac's bar with Back, Forward, Reload and the address, the
/// newest picture of the page as large as fits, and the Mac's notice over it when there is no page to show.
///
/// With "Can control", the page is used as the person at the Mac uses it: a tap clicks, a finger dragged
/// scrolls, a press held and then dragged drags, and the keys under the page and the keyboard type into it.
/// Copy brings the page's selected text to this device's clipboard, and Paste types this device's. All of
/// it goes to the Mac as the Mac's own browser half sends it. A device that may only watch is sent nothing of
/// the page, and says so in its place.
struct BrowserViewer: View {
    @Environment(RemoteClient.self) private var client
    let cardID: String
    @State private var typed = ""
    @FocusState private var isTypingAddress: Bool
    @State private var wantsKeyboard = false
    @State private var isCatching = false

    static let watchOnly = "This device can only watch. To use the browser from here, turn on “Can control” for it on your Mac: Settings, then Remote."

    var body: some View {
        let feeds = client.browsers
        // Read so that each new picture and each change to the bar draws this again.
        let _ = feeds.revision
        let page = feeds.page(cardID) ?? RemoteBrowserPage()
        let canAct = client.abilities.canAct
        let name = client.mirror.snapshot?.flow.card(cardID)?.name ?? "Browser"
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink.ui)
                    .accessibilityHidden(true)
                Text(name)
                    .dsMono(Theme.Touch.title, .medium)
                    .foregroundStyle(Theme.ink.ui)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if page.isLoading {
                    ProgressView()
                        .tint(Theme.inkSecondary.ui)
                        .accessibilityLabel("Loading")
                }
                Spacer(minLength: Theme.Space.s)
                if client.state != .connected { ConnectionPill(isBrief: true) }
                Button("Done") { client.openBrowser(nil) }
                    .buttonStyle(.panel())
                    // While the page has the keyboard, Esc is a key for the page.
                    .keyboardShortcut(isCatching || isTypingAddress ? nil : KeyboardShortcut.cancelAction)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.Touch.target + Theme.Space.s)
            .background(Theme.bar.ui)
            Hairline()
            addressBar(page, canAct: canAct)
            if let problem = page.addressProblem ?? feeds.refusals[cardID] {
                Text(problem)
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.failInk.ui)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.xs)
                    .background(Theme.bar.ui)
            }
            Hairline()
            ZStack {
                BrowserStage(client: client, cardID: cardID, picture: page.notice == nil ? feeds.picture(cardID) : nil, canAct: canAct,
                             spoken: spoken(page, name: name)) {
                    // A real keyboard types into the page once the page has been tapped, as a click gives a page on the Mac the keyboard.
                    if GCKeyboard.coalesced != nil { wantsKeyboard = true }
                }
                if let notice = page.notice { noticeView(notice, canAct: canAct) }
            }
            BrowserKeysBar(cardID: cardID, canAct: canAct && page.notice == nil, wantsKeyboard: $wantsKeyboard, isCatching: $isCatching)
        }
        .background(Theme.surface.ui)
        .onAppear {
            typed = page.url
            #if DEBUG
            if DebugBrowser.wantsKeys { wantsKeyboard = true }
            #endif
        }
        .onChange(of: page.url) { _, now in if !isTypingAddress { typed = now } }
        .onChange(of: isTypingAddress) { _, now in if now { wantsKeyboard = false } }
        .onDisappear { client.openBrowser(nil) }
    }

    /// What VoiceOver says of the page: it is a picture of the Mac's, and of what.
    private func spoken(_ page: RemoteBrowserPage, name: String) -> String {
        let what = page.title.isEmpty ? (page.url.isEmpty ? "a blank page" : page.url) : page.title
        return "\(what). A picture of the page in \(name)'s browser on your Mac."
    }

    @ViewBuilder private func addressBar(_ page: RemoteBrowserPage, canAct: Bool) -> some View {
        HStack(spacing: Theme.Space.xs) {
            barButton("chevron.left", "Back", isEnabled: canAct && page.canGoBack) { use(.back) }
            barButton("chevron.right", "Forward", isEnabled: canAct && page.canGoForward) { use(.forward) }
            barButton("arrow.clockwise", "Reload this page", isEnabled: canAct) { use(.reload) }
            TextField("Type an address, or what to search for", text: $typed)
                .dsMono(Theme.Touch.body)
                .foregroundStyle(Theme.ink.ui)
                .tint(Theme.select.ui)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isTypingAddress)
                .disabled(!canAct)
                .onSubmit { go() }
                // Esc puts the page's address back, as on the Mac.
                .onKeyPress(.escape) {
                    typed = page.url
                    isTypingAddress = false
                    return .handled
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: 36)
                .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder((isTypingAddress ? Theme.select : Theme.hairline).ui, lineWidth: Theme.Stroke.card))
                .accessibilityLabel("Address")
                .accessibilityValue(page.url.isEmpty ? "Blank page" : page.url)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.bar.ui)
        #if DEBUG
        // What the bar shows, for a test that can't see it.
        .onChange(of: typed, initial: true) { _, now in client.browsers.debugAddress = now }
        #endif
    }

    private func barButton(_ symbol: String, _ label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.panel(.tool))
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func noticeView(_ notice: BrowserNotice, canAct: Bool) -> some View {
        VStack(spacing: Theme.Space.m) {
            Text(notice.words)
                .dsSans(Theme.Touch.body)
                .foregroundStyle(Theme.inkSecondary.ui)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let offer = notice.offer {
                Button(offer.title) {
                    Task { await client.browser(offer == .download ? .download : .restart) }
                }
                .buttonStyle(.panel())
                .disabled(!canAct)
                if !canAct {
                    Text("Your Mac offers this. This device can only watch.")
                        .dsSans(Theme.Touch.caption + 1)
                        .foregroundStyle(Theme.inkSecondary.ui)
                }
            }
            if let refusal = client.settings.browserRefusal {
                Text(refusal)
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.failInk.ui)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 360)
        .padding(Theme.Space.l)
    }

    private func use(_ action: RemoteBrowserAction) {
        Task { await client.useBrowser(cardID, action) }
    }

    /// Opens what was typed in the bar, by the Mac's bar's own rules. What it won't open is said under the bar.
    private func go() {
        let text = typed
        Task {
            if await client.useBrowser(cardID, .navigate(text)) == nil { isTypingAddress = false }
        }
    }
}

/// The keys under the page: the ones a touch keyboard lacks, Copy and Paste, and the button that brings the
/// keyboard up. Behind them sits the key catcher, which is what has the keyboard. With a real keyboard, ⌘A,
/// ⌘Z, ⌘⇧Z, ⌘C, ⌘X, ⌘V and ⌘R do what they do in the Mac's browser half.
private struct BrowserKeysBar: View {
    @Environment(RemoteClient.self) private var client
    let cardID: String
    let canAct: Bool
    @Binding var wantsKeyboard: Bool
    @Binding var isCatching: Bool

    private static let keys: [(name: String, title: String, symbol: String?, spoken: String)] = [
        ("Escape", "Esc", nil, "Escape"), ("Tab", "Tab", nil, "Tab"),
        ("ArrowLeft", "", "arrow.left", "Left arrow"), ("ArrowUp", "", "arrow.up", "Up arrow"),
        ("ArrowDown", "", "arrow.down", "Down arrow"), ("ArrowRight", "", "arrow.right", "Right arrow"),
        ("Backspace", "", "delete.left", "Delete"), ("Enter", "Enter", "return", "Enter"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            if canAct {
                HStack(spacing: Theme.Space.s) {
                    ScrollView(.horizontal) {
                        HStack(spacing: Theme.Space.xs + 2) {
                            ForEach(Self.keys, id: \.name) { key in
                                Button { client.pressInBrowser(cardID, key.name) } label: {
                                    HStack(spacing: Theme.Space.xs) {
                                        if let symbol = key.symbol { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
                                        if !key.title.isEmpty { Text(key.title) }
                                    }
                                    .padding(.horizontal, Theme.Space.xs)
                                    .frame(minWidth: Theme.Touch.target - 2 * Theme.Space.l)
                                }
                                .buttonStyle(.panel())
                                .buttonRepeatBehavior(key.name.hasPrefix("Arrow") || key.name == "Backspace" ? .enabled : .disabled)
                                .accessibilityLabel(key.spoken)
                            }
                            Rectangle().fill(Theme.hairline.ui).frame(width: 1, height: 28).padding(.horizontal, Theme.Space.xs)
                                .accessibilityHidden(true)
                            Button("Copy") { Task { await client.copyFromBrowser(cardID) } }
                                .buttonStyle(.panel())
                                .accessibilityHint("Puts the text selected on the page on this device's clipboard.")
                            Button("Paste") { client.pasteIntoBrowser(cardID) }
                                .buttonStyle(.panel())
                                .accessibilityHint("Types what is on this device's clipboard into the page.")
                        }
                        .padding(.vertical, 1)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    Button {
                        wantsKeyboard = !isCatching
                    } label: {
                        Image(systemName: isCatching ? "keyboard.chevron.compact.down" : "keyboard")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.ink.ui)
                            .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCatching ? "Hide the keyboard" : "Type into the page")
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background {
                    BrowserKeyCatcherHost(isWanted: wantsKeyboard,
                                          onText: { client.typeInBrowser(cardID, $0) },
                                          onKey: { client.pressInBrowser(cardID, $0) },
                                          onShortcut: { shortcut($0, shift: $1) },
                                          onFocus: { has in
                                              isCatching = has
                                              if !has { wantsKeyboard = false }
                                          })
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            } else {
                Text(client.abilities.canAct ? "Nothing can be typed until the page is there." : BrowserViewer.watchOnly)
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
            }
        }
        .background(Theme.bar.ui)
        #if DEBUG
        .onChange(of: isCatching, initial: true) { _, now in client.browsers.debugCatching = now }
        #endif
    }

    /// A ⌘ shortcut from a real keyboard, as the Mac's browser half takes it.
    private func shortcut(_ letter: Character, shift: Bool) {
        switch letter {
        case "a": Task { await client.useBrowser(cardID, .shortcut(.selectAll)) }
        case "z": Task { await client.useBrowser(cardID, .shortcut(shift ? .redo : .undo)) }
        case "c": Task { await client.copyFromBrowser(cardID) }
        case "x": Task { await client.copyFromBrowser(cardID, cut: true) }
        case "v": client.pasteIntoBrowser(cardID)
        case "r": Task { await client.useBrowser(cardID, .reload) }
        default: break
        }
    }
}

/// Hosts the page in SwiftUI.
private struct BrowserStage: UIViewRepresentable {
    let client: RemoteClient
    let cardID: String
    let picture: BrowserPicture?
    let canAct: Bool
    let spoken: String
    let tapped: () -> Void

    func makeUIView(context: Context) -> BrowserStageView {
        let stage = BrowserStageView()
        #if DEBUG
        client.browsers.debugStage = stage
        #endif
        return stage
    }

    func updateUIView(_ stage: BrowserStageView, context: Context) {
        stage.show(picture)
        stage.isEnabled = canAct
        stage.accessibilityLabel = spoken
        let client = client, card = cardID, tapped = tapped
        stage.onClick = { point, clicks in
            tapped()
            Task { await client.useBrowser(card, .mouse(RemoteMouse(.pressed, x: point.x, y: point.y, isDown: true, clicks: clicks))) }
            Task { await client.useBrowser(card, .mouse(RemoteMouse(.released, x: point.x, y: point.y, clicks: clicks))) }
        }
        stage.onScroll = { point, delta in client.scrollBrowser(card, at: point, dx: delta.width, dy: delta.height) }
        stage.onDrag = { phase, point in
            switch phase {
            case .began: Task { await client.useBrowser(card, .mouse(RemoteMouse(.pressed, x: point.x, y: point.y, isDown: true, clicks: 1))) }
            case .moved: client.moveBrowserPointer(card, to: RemoteMouse(.moved, x: point.x, y: point.y, isDown: true))
            case .ended: Task { await client.useBrowser(card, .mouse(RemoteMouse(.released, x: point.x, y: point.y, clicks: 1))) }
            }
        }
    }
}

/// The page, drawn as large as fits, kept to its shape. A tap clicks where it lands on the page, a finger
/// dragged scrolls, and a press held a moment and then dragged drags with the button down, as to select text.
/// Points are mapped from here to the page's own size, which the Mac's tab is laid out at.
final class BrowserStageView: UIView {
    enum Phase { case began, moved, ended }

    private let image = UIImageView()
    private(set) var picture: BrowserPicture?
    var isEnabled = false
    var onClick: ((CGPoint, Int) -> Void)?
    var onScroll: ((CGPoint, CGSize) -> Void)?
    var onDrag: ((Phase, CGPoint) -> Void)?
    private var lastTap: (at: CGPoint, time: TimeInterval)?
    private var lastPan = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.surface
        image.contentMode = .scaleAspectFit
        image.backgroundColor = .clear
        addSubview(image)
        isAccessibilityElement = true
        accessibilityTraits = .image

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 8
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 2
        // Scrolling waits only as long as it takes to see the finger isn't holding still.
        pan.require(toFail: hold)
        [tap, hold, pan].forEach(addGestureRecognizer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ new: BrowserPicture?) {
        picture = new
        image.image = new?.image
        // A page is drawn on white whatever the app's appearance, as it is on the Mac.
        image.backgroundColor = new == nil ? .clear : .white
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let picture else {
            image.frame = bounds
            return
        }
        image.frame = BrowserGeometry.fitted(picture.page, in: bounds.size)
    }

    override func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        guard isEnabled, picture != nil else { return false }
        // A tap beside the picture is on nothing.
        if recogniser is UITapGestureRecognizer || recogniser is UILongPressGestureRecognizer {
            return page(at: recogniser.location(in: self)) != nil
        }
        return true
    }

    /// The point on the page under a point of this view, or nil beside the picture.
    private func page(at point: CGPoint) -> CGPoint? {
        guard let picture else { return nil }
        return BrowserGeometry.pagePoint(at: point, in: bounds.size, page: picture.page)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        click(at: tap.location(in: self))
    }

    /// A click where a finger landed: a second tap soon after, close to the first, is a double click.
    func click(at point: CGPoint) {
        guard let onPage = page(at: point) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let isDouble = lastTap.map { now - $0.time < 0.35 && hypot($0.at.x - point.x, $0.at.y - point.y) < 12 } ?? false
        lastTap = isDouble ? nil : (point, now)
        onClick?(onPage, isDouble ? 2 : 1)
    }

    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        guard let picture else { return }
        let point = BrowserGeometry.clampedPagePoint(at: hold.location(in: self), in: bounds.size, page: picture.page)
        switch hold.state {
        case .began: onDrag?(.began, point)
        case .changed: onDrag?(.moved, point)
        case .ended, .cancelled, .failed: onDrag?(.ended, point)
        default: break
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let picture else { return }
        let moved = pan.translation(in: self)
        if pan.state == .began { lastPan = .zero }
        let step = CGSize(width: moved.x - lastPan.x, height: moved.y - lastPan.y)
        lastPan = moved
        guard pan.state == .began || pan.state == .changed, step != .zero else { return }
        // The page moves with the finger, so a finger going up scrolls down.
        let distance = BrowserGeometry.pageDistance(step, in: bounds.size, page: picture.page)
        let at = BrowserGeometry.clampedPagePoint(at: pan.location(in: self), in: bounds.size, page: picture.page)
        onScroll?(at, CGSize(width: -distance.width, height: -distance.height))
    }

    #if DEBUG
    /// Clicks a point of the page, given in the page's own points, as a finger tapping the view there would:
    /// through the same mapping from the view back to the page.
    func debugClick(page point: CGPoint) -> CGPoint? {
        // A finger on a page this device may only watch does nothing, and nor does this.
        guard let picture, isEnabled else { return nil }
        let drawn = BrowserGeometry.fitted(picture.page, in: bounds.size)
        let inView = CGPoint(x: drawn.minX + point.x / picture.page.width * drawn.width, y: drawn.minY + point.y / picture.page.height * drawn.height)
        lastTap = nil
        click(at: inView)
        return convert(inView, to: nil)
    }

    var debugFrame: CGRect { convert(image.frame, to: nil) }
    #endif
}

/// Takes the keyboard for a card's page. The page is a picture, so keys come to this view, which draws
/// nothing, and are handed on as text and as the names of keys.
final class BrowserKeyCatcher: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((String) -> Void)?
    /// ⌘ with a letter on a real keyboard, and whether Shift was held.
    var onShortcut: ((Character, Bool) -> Void)?
    var onFocus: ((Bool) -> Void)?
    private var isWanted = false

    override var canBecomeFirstResponder: Bool { true }

    func want(_ wanted: Bool) {
        isWanted = wanted
        Task { [weak self] in self?.settle() }
    }

    private func settle() {
        if isWanted, !isFirstResponder, window != nil {
            becomeFirstResponder()
        } else if !isWanted, isFirstResponder {
            resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { settle() }
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let did = super.becomeFirstResponder()
        if did { onFocus?(true) }
        return did
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let did = super.resignFirstResponder()
        if did { onFocus?(false) }
        return did
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        // The Return key arrives as a new line, which a page takes as the Enter key.
        let typed = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || ($0.value >= 0x20 && $0.value != 0x7F) }))
        if !typed.isEmpty { onText?(typed) }
    }

    func deleteBackward() { onKey?("Backspace") }

    var autocapitalizationType = UITextAutocapitalizationType.none
    var autocorrectionType = UITextAutocorrectionType.no
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no
    var keyboardType = UIKeyboardType.default
    var keyboardAppearance = UIKeyboardAppearance.default

    private static let named: [(input: String, flags: UIKeyModifierFlags, key: String)] = [
        (UIKeyCommand.inputUpArrow, [], "ArrowUp"), (UIKeyCommand.inputDownArrow, [], "ArrowDown"),
        (UIKeyCommand.inputLeftArrow, [], "ArrowLeft"), (UIKeyCommand.inputRightArrow, [], "ArrowRight"),
        (UIKeyCommand.inputEscape, [], "Escape"), ("\t", [], "Tab"),
    ]
    private static let shortcuts: [(input: String, flags: UIKeyModifierFlags)] = [
        ("a", .command), ("z", .command), ("z", [.command, .shift]), ("c", .command), ("x", .command), ("v", .command), ("r", .command),
    ]

    override var keyCommands: [UIKeyCommand]? {
        Self.named.map { entry in
            let command = UIKeyCommand(input: entry.input, modifierFlags: entry.flags, action: #selector(pressed(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        } + Self.shortcuts.map { entry in
            let command = UIKeyCommand(input: entry.input, modifierFlags: entry.flags, action: #selector(shortcut(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func pressed(_ command: UIKeyCommand) {
        if let entry = Self.named.first(where: { $0.input == command.input && $0.flags == command.modifierFlags }) { onKey?(entry.key) }
    }

    @objc private func shortcut(_ command: UIKeyCommand) {
        guard let letter = command.input?.first else { return }
        onShortcut?(letter, command.modifierFlags.contains(.shift))
    }
}

private struct BrowserKeyCatcherHost: UIViewRepresentable {
    let isWanted: Bool
    let onText: (String) -> Void
    let onKey: (String) -> Void
    let onShortcut: (Character, Bool) -> Void
    let onFocus: (Bool) -> Void

    func makeUIView(context: Context) -> BrowserKeyCatcher {
        let catcher = BrowserKeyCatcher()
        catcher.isAccessibilityElement = false
        return catcher
    }

    func updateUIView(_ catcher: BrowserKeyCatcher, context: Context) {
        catcher.onText = onText
        catcher.onKey = onKey
        catcher.onShortcut = onShortcut
        catcher.onFocus = onFocus
        catcher.want(isWanted)
    }

    static func dismantleUIView(_ catcher: BrowserKeyCatcher, coordinator: ()) {
        catcher.onFocus = nil
        catcher.want(false)
    }
}
