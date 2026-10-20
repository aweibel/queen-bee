import AppKit
import QueenBeeCore

/// A round dot on a card's edge that a link starts from or lands on.
final class PortDotView: NSView {
    let port: String
    let isOutput: Bool
    var isLinked = false { didSet { if isLinked != oldValue { needsDisplay = true } } }
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private let dot = CAShapeLayer()
    private var hasDrawn = false

    init(port: String, isOutput: Bool) {
        self.port = port
        self.isOutput = isOutput
        let d = CanvasGeometry.portRadius * 2 + 6
        super.init(frame: NSRect(x: 0, y: 0, width: d, height: d))
        wantsLayer = true
        dot.lineWidth = Theme.Stroke.card
        layer?.addSublayer(dot)
        toolTip = isOutput ? "\(portLabel(port)): drag from here to another card to link them" : "Messages arrive here"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // An output grows a little under the pointer, to say it can be dragged from.
        let r = CanvasGeometry.portRadius + (isHovered && isOutput ? 1.5 : 0)
        let circle = CGRect(x: bounds.midX - r, y: bounds.midY - r, width: r * 2, height: r * 2)
        dot.frame = bounds
        dot.strokeColor = Theme.ink.cgColor
        dot.ease("path", to: CGPath(ellipseIn: circle, transform: nil), animated: hasDrawn)
        dot.ease("fillColor", to: (isLinked || isHovered ? Theme.ink : Theme.surface).cgColor, animated: hasDrawn)
        hasDrawn = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        if isOutput { addCursorRect(bounds, cursor: .crosshair) }
    }
}

/// The strip you drag a card by. It shows the open hand under the pointer, and tints a
/// little, so it reads as something to grab.
final class TitleBarView: NSView {
    var isHovered = false { didSet { if isHovered != oldValue { superview?.superview?.needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// A small tinted label in a card's title bar: a state, a count, a check.
final class BadgeLabel: NSView {
    enum Tone { case plain, live, pass, fail }

    private let label = NSTextField(labelWithString: "")
    private(set) var tone: Tone = .plain

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.badge
        label.font = Theme.mono(Theme.Size.caption, .medium)
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, tone: Tone) {
        self.tone = tone
        if label.stringValue != text { label.stringValue = text }
        isHidden = text.isEmpty
        label.textColor = switch tone {
        case .plain: Theme.inkSecondary
        case .live: Theme.liveInk
        case .pass: Theme.passInk
        case .fail: Theme.failInk
        }
        label.sizeToFit()
        setFrameSize(NSSize(width: label.frame.width + 10, height: 16))
        label.setFrameOrigin(NSPoint(x: 5, y: (16 - label.frame.height) / 2))
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = switch tone {
        case .plain: NSColor.clear.cgColor
        case .live: Theme.liveTint.cgColor
        case .pass: Theme.passTint.cgColor
        case .fail: Theme.failTint.cgColor
        }
    }
}

/// What a link being dragged would do if dropped on a card.
enum LinkDrop {
    case none, accepts, refuses
}

/// A card on the canvas: a title bar to drag it by, dots for its links, a corner to resize it.
/// Its frame is the card's rectangle widened by `gutter` on each side, so the dots that
/// straddle the card's edges stay inside the view and can be clicked.
class CardView: NSView, NSGestureRecognizerDelegate {
    static let gutter: CGFloat = CanvasGeometry.portRadius + 3
    /// As far left or up as a card may be dragged: just inside the canvas's edge.
    static let farLeft: CGFloat = -CanvasView.margin + 100

    private(set) var card: Card
    private(set) var context = CardContext()
    weak var canvas: CanvasView?

    let body = FlippedView()
    let titleBar = TitleBarView()
    let content = FlippedView()
    private let titleRule = FlippedView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let runBadge = BadgeLabel()
    private let resizeGrip = ResizeGripView()
    /// Covers the card when the canvas is zoomed too far out to read: the name, large, and a
    /// word on what the card is doing. It is also the handle the card is dragged by then.
    private let overview = OverviewView()
    private let overviewName = NSTextField(wrappingLabelWithString: "")
    private let overviewDetail = NSTextField(labelWithString: "")
    /// Below this zoom a card shows its overview.
    static let overviewBelow: CGFloat = 0.4
    /// The canvas's zoom, set by the canvas.
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { applyZoom(from: oldValue) } } }
    private var inputDot: PortDotView?
    private var outputDots: [PortDotView] = []
    private var dragOrigins: [String: CGPoint] = [:]
    private var dragSize = CGSize.zero
    /// Where on the canvas the pointer was when the drag began.
    private var dragStart = CGPoint.zero
    /// What the view last showed, so a sync that changes nothing for this card costs nothing.
    private var shown: (card: Card, context: CardContext)?
    private var hasDrawn = false
    var linkDrop: LinkDrop = .none { didSet { if linkDrop != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    init(card: Card) {
        self.card = card
        super.init(frame: CardView.frame(for: card))
        wantsLayer = true

        body.wantsLayer = true
        body.layer?.cornerRadius = Theme.Radius.card
        body.layer?.masksToBounds = true
        addSubview(body)

        titleBar.wantsLayer = true
        titleRule.wantsLayer = true
        body.addSubview(titleBar)
        body.addSubview(content)
        body.addSubview(titleRule)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.ink
        titleBar.addSubview(iconView)
        nameLabel.font = Theme.mono(Theme.Size.body, .medium)
        nameLabel.textColor = Theme.ink
        nameLabel.lineBreakMode = .byTruncatingTail
        titleBar.addSubview(nameLabel)
        titleBar.addSubview(runBadge)

        overview.wantsLayer = true
        overview.layer?.opacity = 0
        overviewName.alignment = .center
        overviewName.textColor = Theme.ink
        overviewName.maximumNumberOfLines = 2
        overviewName.lineBreakMode = .byTruncatingTail
        overviewDetail.alignment = .center
        overviewDetail.textColor = Theme.inkSecondary
        overviewDetail.lineBreakMode = .byTruncatingTail
        overview.addSubview(overviewName)
        overview.addSubview(overviewDetail)
        body.addSubview(overview)

        addSubview(resizeGrip)

        // The title bar is the handle, and so is the overview while it covers the card.
        for handle in [titleBar, overview] {
            handle.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleMove(_:))))
            handle.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:))))
            handle.addGestureRecognizer(GrabGesture.make(target: self, action: #selector(handleGrab(_:)), delegate: self))
            let double = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
            double.numberOfClicksRequired = 2
            handle.addGestureRecognizer(double)
        }
        resizeGrip.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleResize(_:))))

        rebuildPorts()
        applyCard()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func frame(for card: Card) -> CGRect {
        CanvasGeometry.frame(of: card).insetBy(dx: -gutter, dy: 0)
    }

    /// Whether `update` would change anything. Dragging one card re-syncs the whole canvas
    /// on every move of the pointer; the cards that didn't move skip the work.
    func isCurrent(card new: Card, context: CardContext) -> Bool {
        guard let shown else { return false }
        return shown.card == new && shown.context == context
    }

    /// Brings the view in line with the model. Subclasses add their own state on top.
    func update(card new: Card, context: CardContext) {
        shown = (new, context)
        let portsChanged = ports(of: new) != ports(of: card) || acceptsInput(new) != acceptsInput(card)
        card = new
        self.context = context
        let target = CardView.frame(for: new)
        if frame != target { frame = target }
        if portsChanged { rebuildPorts() }
        applyCard()

        inputDot?.isLinked = context.linkedInputs
        for dot in outputDots { dot.isLinked = context.linkedPorts.contains(dot.port) }

        let mark = context.mark
        if mark.failed {
            runBadge.set("✕", tone: .fail)
        } else if runCount > 0 {
            runBadge.set(runCount > 1 ? "✓ \(runCount)" : "✓", tone: .pass)
        } else {
            runBadge.set("", tone: .plain)
        }
        overviewName.stringValue = new.name
        // A card still called by its kind's name doesn't need telling twice.
        let said = overviewText.caseInsensitiveCompare(new.name) == .orderedSame ? nil : overviewText
        let count = runCount > 0 ? (runCount > 1 ? "✓ \(runCount)" : "✓") : nil
        overviewDetail.stringValue = [said, count].compactMap { $0 }.joined(separator: " · ")
        needsLayout = true
        needsDisplay = true
    }

    /// What the overview says under the name. Subclasses say what the card is doing.
    var overviewText: String { card.kind.label }

    private func applyZoom(from old: CGFloat) {
        let shows = zoom < Self.overviewBelow
        overview.isShowing = shows
        if shows != (old < Self.overviewBelow) {
            overview.layer?.ease("opacity", to: Float(shows ? 1 : 0), duration: Theme.Motion.standardDuration)
        }
        // The overview's type is sized to read the same on screen whatever the zoom.
        if shows { needsLayout = true }
    }

    /// How many times the run has passed through this card. An End counts what reached it;
    /// every other card counts what left it.
    var runCount: Int {
        card.kind == .end ? context.mark.arrivals : context.mark.passes
    }

    private func applyCard() {
        nameLabel.stringValue = card.name
        iconView.image = NSImage(systemSymbolName: CanvasGeometry.icon(for: card.kind), accessibilityDescription: card.kind.label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        setAccessibilityLabel("\(card.kind.label) card \(card.name)")
        setAccessibilityIdentifier("card-\(card.id)")
    }

    private func rebuildPorts() {
        inputDot?.removeFromSuperview()
        outputDots.forEach { $0.removeFromSuperview() }
        inputDot = nil
        outputDots = []
        if acceptsInput(card) {
            let dot = PortDotView(port: "in", isOutput: false)
            addSubview(dot)
            inputDot = dot
        }
        for port in ports(of: card) {
            let dot = PortDotView(port: port, isOutput: true)
            dot.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleLinkDrag(_:))))
            addSubview(dot)
            outputDots.append(dot)
        }
        addSubview(resizeGrip) // keep the grip above everything
    }

    override func layout() {
        super.layout()
        let g = CardView.gutter
        body.frame = NSRect(x: g, y: 0, width: bounds.width - g * 2, height: bounds.height)
        titleBar.frame = NSRect(x: 0, y: 0, width: body.bounds.width, height: CanvasGeometry.titleHeight)
        titleRule.frame = NSRect(x: 0, y: CanvasGeometry.titleHeight - 1, width: body.bounds.width, height: 1)
        content.frame = NSRect(x: 0, y: CanvasGeometry.titleHeight, width: body.bounds.width,
                               height: body.bounds.height - CanvasGeometry.titleHeight)
        iconView.frame = NSRect(x: 9, y: 7, width: 14, height: 14)

        // Badges sit at the title's right, the run badge outermost; the name takes what is left.
        var right = titleBar.bounds.width - 8
        for badge in [runBadge] + titleAccessories where !badge.isHidden {
            badge.setFrameOrigin(NSPoint(x: right - badge.frame.width, y: (CanvasGeometry.titleHeight - badge.frame.height) / 2))
            right = badge.frame.minX - 5
        }
        nameLabel.frame = NSRect(x: 29, y: 6, width: max(0, right - 29), height: 16)

        overview.frame = body.bounds
        if overview.isShowing {
            let scale = 1 / max(zoom, 0.01)
            overviewName.font = Theme.mono(min(44, 13 * scale), .medium)
            overviewDetail.font = Theme.mono(min(32, 10 * scale))
            let width = max(0, overview.bounds.width - 24)
            let nameHeight = min(overviewName.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height, overview.bounds.height * 0.6)
            let detailHeight = overviewDetail.intrinsicContentSize.height
            let top = max(4, (overview.bounds.height - nameHeight - detailHeight - 4) / 2)
            overviewName.frame = NSRect(x: 12, y: top, width: width, height: nameHeight)
            overviewDetail.frame = NSRect(x: 12, y: top + nameHeight + 4, width: width, height: detailHeight)
        }

        let origin = CGPoint(x: card.x - g, y: card.y)
        if let dot = inputDot { place(dot, at: CanvasGeometry.inputPoint(of: card), origin: origin) }
        for dot in outputDots { place(dot, at: CanvasGeometry.outputPoint(of: card, port: dot.port), origin: origin) }
        let s = CanvasGeometry.resizeHandle
        resizeGrip.frame = NSRect(x: bounds.width - g - s, y: bounds.height - s, width: s, height: s)
        layoutContent()
    }

    /// Extra badges a subclass shows in the title bar, right to left after the run badge.
    var titleAccessories: [NSView] { [] }

    /// Subclasses lay out what sits under the title.
    func layoutContent() {}

    private func place(_ dot: PortDotView, at point: CGPoint, origin: CGPoint) {
        dot.frame.origin = CGPoint(x: point.x - origin.x - dot.bounds.width / 2, y: point.y - origin.y - dot.bounds.height / 2)
    }

    // MARK: Colour

    /// The outline says the most pressing thing about the card: a link is about to land,
    /// it is selected, it failed, it is live, or nothing in particular.
    var outline: (color: NSColor, width: CGFloat) {
        switch linkDrop {
        case .accepts: return (Theme.live, Theme.Stroke.selected)
        case .refuses: return (Theme.failInk, Theme.Stroke.selected)
        case .none: break
        }
        if context.isFocused || context.isSelected { return (Theme.select, Theme.Stroke.selected) }
        if context.mark.failed { return (Theme.failInk, Theme.Stroke.link) }
        if context.isLive { return (Theme.live, Theme.Stroke.link) }
        return (Theme.ink, Theme.Stroke.card)
    }

    override var wantsUpdateLayer: Bool { true }

    // Layer colours are set here because this runs with the view's own light or dark
    // appearance in force, so they follow a change of mode.
    override func updateLayer() {
        body.layer?.backgroundColor = Theme.surface.cgColor
        // The outline and the title's tint ease, so selecting and hovering don't snap.
        body.layer?.ease("borderColor", to: outline.color.cgColor, animated: hasDrawn)
        body.layer?.ease("borderWidth", to: outline.width, animated: hasDrawn)
        titleBar.layer?.ease("backgroundColor", to: (titleBar.isHovered ? Theme.barHover : Theme.bar).cgColor, animated: hasDrawn)
        titleRule.layer?.backgroundColor = Theme.hairline.cgColor
        // From far out, the overview's tint is what says a card is live or where a run stopped.
        let tint = context.mark.failed ? Theme.failTint : context.isLive ? Theme.liveTint : Theme.surface
        overview.layer?.ease("backgroundColor", to: tint.cgColor, animated: hasDrawn)
        updateContentLayers()
        hasDrawn = true
    }

    /// Subclasses colour their own layers here.
    func updateContentLayers() {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Appearing

    /// A new card settles into place: it fades in while growing the last few percent.
    func playDrawIn() {
        guard Theme.Motion.isAllowed, let layer else { return }
        // A view's layer is anchored at its corner, so the scale is taken about the middle by hand.
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        var small = CATransform3DMakeTranslation(middle.x, middle.y, 0)
        small = CATransform3DScale(small, 0.96, 0.96, 1)
        small = CATransform3DTranslate(small, -middle.x, -middle.y, 0)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = small
        grow.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Theme.Motion.standardDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "drawIn")
    }

    // MARK: Gestures

    @objc private func handleClick(_ g: NSClickGestureRecognizer) {
        // Shift adds the card to what is selected, or takes it out.
        if NSEvent.modifierFlags.contains(.shift) {
            canvas?.controller?.toggleSelection(card.id)
        } else {
            canvas?.controller?.select(.card(card.id))
        }
        canvas?.takeFocus()
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller = canvas?.controller else { return nil }
        // A right-click on a card outside the selection is about that card alone.
        if !controller.selection.cardIDs.contains(card.id) { controller.select(.card(card.id)) }
        canvas?.takeFocus()
        let id = card.id
        let several = controller.selection.cardIDs.count > 1
        let menu = NSMenu()
        if !several {
            menu.addItem(menuItem("Zoom to Card") { [weak canvas] in canvas?.zoom(toCard: id) })
            if card.kind == .agent {
                let isLive = controller.session(forCard: id).isLive
                menu.addItem(menuItem(isLive ? "Restart Agent" : "Start Agent") { [weak controller] in controller?.startSession(forCard: id) })
            }
            menu.addItem(.separator())
        }
        if !several, card.kind == .flow {
            menu.addItem(menuItem("Open Its Flow") { [weak controller] in controller?.openSubflow(forCard: id) })
        }
        if !several, card.kind == .start {
            menu.addItem(menuItem("Run from This Start") { [weak controller] in
                guard let controller else { return }
                Task { await controller.run(startCardID: id) }
            })
            menu.addItem(.separator())
        }
        if !several, acceptsInput(card) {
            menu.addItem(menuItem("Run from Here…") { [weak controller] in
                controller?.select(.card(id))
                controller?.runFromCardID = id
            })
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("Duplicate") { [weak controller] in controller?.duplicateSelection() })
        menu.addItem(menuItem("Copy") { [weak controller] in controller?.copySelection() })
        menu.addItem(.separator())
        menu.addItem(menuItem(several ? "Delete \(controller.selection.cardIDs.count) Cards" : "Delete") { [weak controller] in controller?.deleteSelection() })
        return menu
    }

    @objc private func handleDoubleClick(_ g: NSClickGestureRecognizer) {
        // A Flow card is a way into another flow. Every other card zooms to fill the window.
        if card.kind == .flow {
            canvas?.controller?.openSubflow(forCard: card.id)
        } else {
            canvas?.zoom(toCard: card.id)
        }
    }

    /// The hand closes the moment the button goes down on the handle, before any movement,
    /// so it is plain the card has been taken hold of.
    @objc private func handleGrab(_ g: NSPressGestureRecognizer) {
        GrabGesture.follow(g, in: window, handle: g.view)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
        gestureRecognizer is NSPressGestureRecognizer || other is NSPressGestureRecognizer
    }

    @objc private func handleMove(_ g: NSPanGestureRecognizer) {
        guard let canvas else { return }
        switch g.state {
        case .began:
            dragOrigins = canvas.controller?.dragOrigins(for: card.id) ?? [:]
            beginDrag(g, in: canvas) { [weak self] in self?.moveToPointer() }
            canvas.controller?.beginGesture()
        case .changed:
            moveToPointer()
        case .ended, .cancelled, .failed:
            if g.state == .ended { moveToPointer() }
            canvas.endEdgePan()
            canvas.clearGuides()
            canvas.controller?.endGesture("Move")
        default: break
        }
    }

    /// Notes where a drag began and lets it pan the canvas from the edges. `follow` redoes the
    /// drag for where the pointer is, each time the canvas pans under it.
    private func beginDrag(_ g: NSPanGestureRecognizer, in canvas: CanvasView, follow: @escaping () -> Void) {
        let now = canvas.pointer, t = g.translation(in: canvas.document)
        dragStart = CGPoint(x: now.x - t.x, y: now.y - t.y)
        canvas.beginEdgePan(moved: follow)
    }

    /// How far the pointer is from where the drag began, on the canvas. Unlike the gesture's
    /// own translation, this counts what the canvas has panned under the pointer.
    private var dragTravel: CGPoint {
        guard let now = canvas?.pointer else { return .zero }
        return CGPoint(x: now.x - dragStart.x, y: now.y - dragStart.y)
    }

    private func moveToPointer() {
        canvas?.drag(dragOrigins, primary: card.id, by: dragTravel)
    }

    private func resizeToPointer() {
        let t = dragTravel
        var width = dragSize.width + t.x, height = dragSize.height + t.y
        // The corner being dragged settles on the grid. Option lets it rest anywhere.
        if !NSEvent.modifierFlags.contains(.option) {
            let step = CanvasGeometry.gridStep
            width = ((card.x + width) / step).rounded() * step - card.x
            height = ((card.y + height) / step).rounded() * step - card.y
        }
        canvas?.controller?.resizeCard(card.id, width: width, height: height)
    }

    @objc private func handleResize(_ g: NSPanGestureRecognizer) {
        guard let canvas else { return }
        switch g.state {
        case .began:
            dragSize = CGSize(width: card.width, height: card.height)
            beginDrag(g, in: canvas) { [weak self] in self?.resizeToPointer() }
            canvas.controller?.beginGesture()
        case .changed, .ended:
            resizeToPointer()
            if g.state == .ended {
                canvas.endEdgePan()
                canvas.controller?.endGesture("Resize")
            }
        case .cancelled, .failed:
            canvas.endEdgePan()
            canvas.controller?.endGesture("Resize")
        default: break
        }
    }

    @objc private func handleLinkDrag(_ g: NSPanGestureRecognizer) {
        guard let canvas, let dot = g.view as? PortDotView else { return }
        let start = CanvasGeometry.outputPoint(of: card, port: dot.port)
        let now = g.location(in: canvas.document)
        switch g.state {
        case .began:
            let id = card.id, port = dot.port
            canvas.beginEdgePan { [weak canvas] in
                guard let canvas else { return }
                canvas.showPendingLink(from: id, port: port, start: start, to: canvas.pointer)
            }
            fallthrough
        case .changed:
            canvas.showPendingLink(from: card.id, port: dot.port, start: start, to: now)
        case .ended:
            canvas.endEdgePan()
            canvas.clearPendingLink()
            canvas.finishLink(from: card.id, port: dot.port, at: now)
        default:
            canvas.endEdgePan()
            canvas.clearPendingLink()
        }
    }
}

/// What a card view needs to know beyond its own card.
struct CardContext: Equatable {
    var isSelected = false
    var isFocused = false
    /// The card is where the run is right now: an agent at work or waiting on a hand-off.
    var isLive = false
    var linkedInputs = false
    var linkedPorts: Set<String> = []
    var warning: String?
    var inputCount = 0
    var result: String?
    /// What the card's session cost in the run on show, like "$0.02". Nil when nothing was used.
    var cost: String?
    /// What a card holding a message is waiting on, in a few words.
    var waiting: String?
    var sessionState: SessionState = .notStarted
    /// The session was started a while ago and hasn't said it is ready.
    var isSlowToStart = false
    /// The card's settings have changed since its session started.
    var needsRestart = false
    /// A run is under way. Marks left by a run that has ended say where it went, not what is live.
    var isRunning = false
    /// A Start card's schedule is one the person has turned on.
    var isArmed = false
    var mark = RunMark()
}

/// A press that begins the instant the button goes down, used to close the hand over something
/// that can be dragged. It runs alongside the click and drag gestures and never replaces them,
/// and it owns the pointer for as long as the button is down: cursor regions are switched off,
/// or the handle moving under the pointer would keep asking for the open hand back.
enum GrabGesture {
    static func make(target: AnyObject, action: Selector, delegate: NSGestureRecognizerDelegate) -> NSPressGestureRecognizer {
        let press = NSPressGestureRecognizer(target: target, action: action)
        press.minimumPressDuration = 0
        // However far the pointer then moves, it is still the same grab.
        press.allowableMovement = .greatestFiniteMagnitude
        press.delegate = delegate
        return press
    }

    static func follow(_ press: NSPressGestureRecognizer, in window: NSWindow?, handle: NSView?) {
        switch press.state {
        case .began:
            window?.disableCursorRects()
            NSCursor.closedHand.set()
        case .ended, .cancelled, .failed:
            window?.enableCursorRects()
            if let handle { window?.invalidateCursorRects(for: handle) }
            // Still over the handle, so the open hand comes straight back.
            NSCursor.openHand.set()
        default:
            break
        }
    }
}

/// Runs a closure when its menu item is picked, for menus built on the spot.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// A menu item that runs `run`.
func menuItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(run)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
    item.target = action
    // A menu item doesn't keep its target alive, so it carries it.
    item.representedObject = action
    return item
}

/// The cover a card wears at low zoom. It only takes clicks while it is showing.
final class OverviewView: NSView {
    var isShowing = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isShowing ? super.hitTest(point).map { _ in self } : nil }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The corner you drag to resize a card: three short diagonal strokes.
final class ResizeGripView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.inkSecondary.setStroke()
        let path = NSBezierPath()
        for inset in stride(from: CGFloat(5), through: 11, by: 3) {
            path.move(to: NSPoint(x: bounds.maxX - 3, y: bounds.maxY - inset))
            path.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.maxY - 3))
        }
        path.lineWidth = 1
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
    }
}
