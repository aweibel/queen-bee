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
/// Nothing can be typed: this is for reading.
struct TerminalViewer: View {
    @Environment(RemoteClient.self) private var client
    let key: String

    var body: some View {
        let caption = SessionCaption(key: key, client: client)
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
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.Touch.target + Theme.Space.s)
            .background(Theme.bar.ui)
            Hairline()
            TerminalStage(registry: client.terminals, key: key, size: client.terminals.sizes[key] ?? .zero)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityLabel("\(caption.name)'s terminal")
                .accessibilityHint("Drag to read earlier output.")
        }
        .background(Theme.terminal.ui)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.terminal
        zoomer.delegate = self
        zoomer.showsVerticalScrollIndicator = false
        zoomer.showsHorizontalScrollIndicator = false
        zoomer.scrollsToTop = false
        zoomer.bouncesZoom = false
        zoomer.contentInsetAdjustmentBehavior = .never
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
    }

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
        mount?.magnification = zoomer.zoomScale
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { mount }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { isFitted = false }
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
            new.magnification = 1
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
