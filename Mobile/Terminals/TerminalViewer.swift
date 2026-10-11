import QueenBeeCore
import SwiftUI
import UIKit

/// What a session is called and what it is doing, for a terminal's heading.
struct SessionCaption: Equatable {
    var name: String
    var state: SessionState?

    @MainActor init(key: String, client: RemoteClient) {
        let snapshot = client.mirror.snapshot
        name = key == TerminalRegistry.orchestratorKey ? "Orchestrator" : snapshot?.flow.card(key)?.name ?? "Terminal"
        state = snapshot?.run.sessions[key]
    }

    /// The same word and tint the session's card shows.
    var badge: (text: String, tone: Badge.Tone)? {
        guard let state else { return nil }
        return (state.label.lowercased(), state.tone)
    }
}

/// One session's terminal, full screen: at a size that can be read, following what the session prints,
/// with a finger scrolling back through what it printed before. Two fingers make it larger or smaller.
///
/// The terminal itself takes no typing. When the Mac lets this device control it and the session is running,
/// a bar under the terminal does: see `ComposerBar`. The bar stays above the keyboard, and the terminal
/// takes what room is left, with the row it is writing on kept in view.
struct TerminalViewer: View {
    @Environment(RemoteClient.self) private var client
    let key: String

    var body: some View {
        let caption = SessionCaption(key: key, client: client)
        let typing = client.abilities.typing[key] ?? Typing()
        let hasFoot = typing.hasBar || typing.line != nil
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink.ui)
                    .accessibilityHidden(true)
                Text(caption.name)
                    .dsMono(Theme.Touch.title, .medium)
                    .foregroundStyle(Theme.ink.ui)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let badge = caption.badge { Badge(text: badge.text, tone: badge.tone) }
                Spacer(minLength: Theme.Space.s)
                if client.state != .connected { ConnectionPill(isBrief: true) }
                Button("Done") { client.terminals.expand(nil) }
                    .buttonStyle(.panel())
                    // In keys mode Esc is a key for the session, like any other.
                    .keyboardShortcut(typing.hasBar && client.composer.mode == .keys ? nil : KeyboardShortcut.cancelAction)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.Touch.target + Theme.Space.s)
            .background(Theme.bar.ui)
            Hairline()
            TerminalStage(registry: client.terminals, key: key, size: client.terminals.sizes[key] ?? .zero)
                // With nothing under it the terminal runs to the foot of the screen.
                .ignoresSafeArea(edges: hasFoot ? [] : .bottom)
                .accessibilityLabel("\(caption.name)'s terminal")
                .accessibilityHint("Drag to read earlier output.")
            ComposerBar(key: key)
        }
        .background(Theme.terminal.ui)
        // Ctrl pressed here and not yet used is let go when this terminal is left, by closing it or by another taking its place.
        .onChange(of: key) { client.composer.releaseControl() }
        .onDisappear {
            client.composer.wantsKeyboard = false
            client.composer.mode = .message
            client.composer.releaseControl()
        }
    }
}

/// Hosts the full-screen terminal in SwiftUI.
private struct TerminalStage: UIViewRepresentable {
    let registry: TerminalRegistry
    let key: String
    /// The terminal's size, passed in so a new one from the Mac lays the stage out again.
    let size: CGSize

    func makeUIView(context: Context) -> TerminalStageView { TerminalStageView() }

    func updateUIView(_ stage: TerminalStageView, context: Context) {
        stage.show(registry.expandedView(for: key), size: size)
        registry.onExpandedOutput = { [weak stage] in stage?.outputArrived() }
    }

    static func dismantleUIView(_ stage: TerminalStageView, coordinator: ()) {
        stage.show(nil, size: .zero)
    }
}

/// The full-screen terminal: a scroll view that zooms the terminal's mount with two fingers and pans it when
/// it is larger than the screen. Scrolling back through earlier output is the terminal's own doing, so a
/// drag up or down goes to it first.
final class TerminalStageView: UIView, UIScrollViewDelegate {
    /// Around the terminal, so its text doesn't touch the screen's edge.
    private static let margin: CGFloat = 12
    /// Never opened larger than this, however small the Mac's terminal: twice life size is plenty to read.
    private static let largestStart: CGFloat = 2
    private static let largest: CGFloat = 3

    private let zoomer = UIScrollView()
    private weak var mount: TerminalMount?
    private var natural = CGSize.zero
    private var laidOut = CGSize.zero
    /// True until the person zooms, so turning the device or a new size from the Mac fits it afresh.
    private var isFitted = true
    /// True until the person moves the terminal about themselves. While it is, the row the session is writing
    /// on is kept in view when the terminal is taller than the room for it, as it is with the keyboard up.
    private var follows = true
    private var isFollowPending = false
    /// Kept in view under the row the cursor is on, so what is being typed isn't hard against the bar.
    private static let rowsBelow = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.terminal
        zoomer.delegate = self
        zoomer.showsVerticalScrollIndicator = false
        zoomer.showsHorizontalScrollIndicator = false
        zoomer.scrollsToTop = false
        zoomer.bouncesZoom = false
        zoomer.contentInsetAdjustmentBehavior = .never
        // A drag that carries on down into the keyboard takes the keyboard with it.
        zoomer.keyboardDismissMode = .interactive
        addSubview(zoomer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Takes the terminal in, or with nil lets it go.
    func show(_ new: TerminalMount?, size: CGSize) {
        if new !== mount {
            // One that has already gone back to its card is left there.
            if let old = mount, old.superview === zoomer {
                old.removeFromSuperview()
                old.transform = .identity
                old.isUserInteractionEnabled = false
            }
            mount = new
            if let new {
                zoomer.zoomScale = 1
                new.transform = .identity
                // On, so a drag reaches the terminal and scrolls it back.
                new.isUserInteractionEnabled = true
                zoomer.addSubview(new)
                isFitted = true
                follows = true
                natural = .zero
            }
        }
        if size != natural, mount != nil {
            natural = size
            laidOut = .zero
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        zoomer.frame = bounds
        guard let mount, mount.superview === zoomer, natural.width > 1, bounds.width > 0, laidOut != bounds.size else { return }
        laidOut = bounds.size
        let was = zoomer.zoomScale
        zoomer.minimumZoomScale = 1
        zoomer.maximumZoomScale = 1
        zoomer.zoomScale = 1
        mount.frame = CGRect(origin: .zero, size: natural)
        zoomer.contentSize = natural

        let room = CGSize(width: bounds.width - Self.margin * 2, height: bounds.height - Self.margin * 2 - safeAreaInsets.bottom)
        let toWidth = room.width / natural.width, whole = min(toWidth, room.height / natural.height)
        // The whole terminal if that can still be read. One too tall for that fills the width, and the
        // rest is a drag away.
        let start = min(Self.largestStart, max(whole, min(1, toWidth)))
        zoomer.minimumZoomScale = min(start, whole, 1)
        zoomer.maximumZoomScale = max(Self.largest, start)
        zoomer.zoomScale = isFitted ? start : min(max(was, zoomer.minimumZoomScale), zoomer.maximumZoomScale)
        settle()
        // The room has changed: the keyboard came or went, or the device was turned.
        follows = true
        showLatest()
    }

    /// The session printed something. A moment later, so a burst of output moves the terminal once.
    func outputArrived() {
        guard follows, !isFollowPending else { return }
        isFollowPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            isFollowPending = false
            if follows, !zoomer.isTracking, !zoomer.isDecelerating, !zoomer.isZooming { showLatest() }
        }
    }

    /// Brings the row the cursor is on into view, when the terminal is taller than the room it has. A
    /// terminal that fits is left at the top, where `settle` put it.
    private func showLatest() {
        guard let mount, mount.superview === zoomer, mount.cell.height > 0 else { return }
        let shown = zoomer.contentSize
        guard shown.height > bounds.height - Self.margin * 2 else { return }
        let row = mount.terminal.terminalStateSnapshot().cursor.row
        let under = CGFloat(row + 1 + Self.rowsBelow) * mount.cell.height * zoomer.zoomScale
        let lowest = shown.height + zoomer.contentInset.bottom - bounds.height
        zoomer.contentOffset.y = min(lowest, max(-zoomer.contentInset.top, under + Self.margin - bounds.height))
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { follows = false }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        laidOut = .zero
        setNeedsLayout()
    }

    /// Keeps a terminal smaller than the screen in the middle of its width and at the top, and has it
    /// drawn as finely as it is now shown.
    private func settle() {
        let shown = zoomer.contentSize
        let side = max(Self.margin, (bounds.width - shown.width) / 2)
        zoomer.contentInset = UIEdgeInsets(top: Self.margin, left: side, bottom: Self.margin + safeAreaInsets.bottom, right: side)
        if shown.width <= bounds.width - Self.margin * 2 { zoomer.contentOffset.x = -side }
        if shown.height <= bounds.height - Self.margin * 2 { zoomer.contentOffset.y = -Self.margin }
        mount?.magnify(zoomer.zoomScale)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { mount }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isFitted = false
        follows = false
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { settle() }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let shown = zoomer.contentSize
        let side = max(Self.margin, (bounds.width - shown.width) / 2)
        zoomer.contentInset.left = side
        zoomer.contentInset.right = side
    }
}

/// A session's terminal as a picture in a panel: as wide as the panel, as tall as that makes it. It follows
/// the session and takes no touches. While the terminal is open full screen the place is left empty.
struct TerminalPicture: View {
    @Environment(RemoteClient.self) private var client
    let key: String

    var body: some View {
        let registry = client.terminals
        if let size = registry.sizes[key], size.width > 1, size.height > 1 {
            TerminalSlot(registry: registry, key: key, isExpanded: registry.expandedKey == key, size: size)
                .aspectRatio(size.width / size.height, contentMode: .fit)
                .accessibilityHidden(true)
        }
    }
}

private struct TerminalSlot: UIViewRepresentable {
    let registry: TerminalRegistry
    let key: String
    /// Passed in so the slot is asked again when the terminal goes to the full-screen view and comes back.
    let isExpanded: Bool
    let size: CGSize

    func makeUIView(context: Context) -> TerminalSlotView { TerminalSlotView() }
    func updateUIView(_ slot: TerminalSlotView, context: Context) { slot.hold(registry.view(for: key)) }
    static func dismantleUIView(_ slot: TerminalSlotView, coordinator: ()) { slot.hold(nil) }
}

final class TerminalSlotView: UIView {
    private weak var mount: TerminalMount?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.terminal
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func hold(_ new: TerminalMount?) {
        if let new, new.superview !== self {
            new.transform = .identity
            new.magnify(1)
            addSubview(new)
        } else if new == nil, let old = mount, old.superview === self {
            old.removeFromSuperview()
        }
        mount = new
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let mount, mount.superview === self { mount.frame = bounds }
    }
}
