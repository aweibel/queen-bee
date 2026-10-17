import QueenBeeCore
import UIKit

extension UIColor {
    /// The colour for a layer, which can't follow light and dark by itself.
    func cg(in view: UIView) -> CGColor { resolvedColor(with: view.traitCollection).cgColor }
}

/// A round dot on a card's edge that a link starts from or lands on. The Mac's `PortDotView`.
final class PortDotView: UIView {
    let port: String
    var isLinked = false { didSet { if isLinked != oldValue { restyle() } } }
    private let dot = CAShapeLayer()

    init(port: String) {
        self.port = port
        let d = CanvasGeometry.portRadius * 2 + 6
        super.init(frame: CGRect(x: 0, y: 0, width: d, height: d))
        isUserInteractionEnabled = false
        let r = CanvasGeometry.portRadius
        dot.frame = bounds
        dot.path = CGPath(ellipseIn: CGRect(x: bounds.midX - r, y: bounds.midY - r, width: r * 2, height: r * 2), transform: nil)
        dot.lineWidth = Theme.Stroke.card
        layer.addSublayer(dot)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PortDotView, _) in view.restyle() }
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.strokeColor = Theme.ink.cg(in: self)
        dot.fillColor = (isLinked ? Theme.ink : Theme.surface).cg(in: self)
        CATransaction.commit()
    }
}

/// A small tinted label in a card's title bar: a state, a count, a check. The Mac's `BadgeLabel`.
final class BadgeLabel: UIView {
    enum Tone { case plain, live, pass, fail }

    private let label = UILabel()
    private(set) var text = ""

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        layer.cornerRadius = Theme.Radius.badge
        label.font = Theme.mono(Theme.Size.caption, .medium)
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, tone: Tone) {
        self.text = text
        if label.text != text { label.text = text }
        isHidden = text.isEmpty
        label.textColor = switch tone {
        case .plain: Theme.inkSecondary
        case .live: Theme.liveInk
        case .pass: Theme.passInk
        case .fail: Theme.failInk
        }
        backgroundColor = switch tone {
        case .plain: .clear
        case .live: Theme.liveTint
        case .pass: Theme.passTint
        case .fail: Theme.failTint
        }
        let size = label.intrinsicContentSize
        bounds.size = CGSize(width: ceil(size.width) + 10, height: 16)
        label.frame = CGRect(x: 5, y: (16 - size.height) / 2, width: ceil(size.width), height: size.height)
    }
}

/// A button drawn on a card, at the card's own scale: "Approve", "Start agent". It takes no touches, as
/// nothing on a card does. The canvas works out that a tap landed on it, and gives it a finger's width.
final class CardButtonView: UIView {
    static let height: CGFloat = 22
    private let label = UILabel()
    private(set) var button: PressButton

    init(_ button: PressButton) {
        self.button = button
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = Theme.Radius.card
        layer.borderWidth = Theme.Stroke.card
        label.font = Theme.mono(Theme.Size.body, .medium)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CardButtonView, _) in view.restyle() }
        set(button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ new: PressButton) {
        button = new
        label.text = new.title
        restyle()
    }

    /// As wide as its name and a little room either side.
    var wanted: CGFloat { ceil(label.intrinsicContentSize.width) + 16 }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 4, dy: 0)
    }

    /// The Mac's panel buttons: an ink outline, or the live colours for the answer a card is waiting for.
    private func restyle() {
        backgroundColor = button.isMain ? Theme.liveTint : Theme.surface
        label.textColor = button.isMain ? Theme.liveInk : Theme.ink
        layer.borderColor = (button.isMain ? Theme.live : Theme.ink).cg(in: self)
        // Faint while its command is on its way to the Mac.
        alpha = button.isEnabled ? 1 : 0.45
    }
}

/// A card on the canvas, drawn as the Mac's `CardView` draws it: a title bar, dots for its links, the corner
/// the Mac resizes it by. Its frame is the card's rectangle widened by `gutter` on each side, so the dots that
/// straddle the card's edges stay inside the view. The view takes no touches: the canvas works out what a tap
/// or a drag landed on, the card's buttons, its title bar, its dots and its corner included.
class CardView: UIView {
    static let gutter: CGFloat = CanvasGeometry.portRadius + 3
    /// Below this zoom a card shows its overview.
    static let overviewBelow: CGFloat = 0.4

    private(set) var card: Card
    private(set) var context = CardContext()

    let body = UIView()
    let titleBar = UIView()
    let content = UIView()
    private let titleRule = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let runBadge = BadgeLabel()
    private let grip = CAShapeLayer()
    /// Covers the card when the canvas is zoomed too far out to read: the name, large, and a word on what
    /// the card is doing.
    private let overview = UIView()
    private let overviewName = UILabel()
    private let overviewDetail = UILabel()
    /// The canvas's zoom, set by the canvas.
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { applyZoom(from: oldValue) } } }
    private var inputDot: PortDotView?
    private var outputDots: [PortDotView] = []
    /// The buttons the card offers when this device may answer for it. A subclass says where they go.
    private(set) var buttonViews: [CardButtonView] = []
    /// Does what one of the card's buttons is for. The canvas calls it for a finger, and VoiceOver for its actions.
    var onPress: ((Press) -> Void)?
    /// Makes a change to the flow, for VoiceOver's actions while the flow is being edited. A finger's drags
    /// and its menu are the canvas's.
    var onEdit: ((EditAction) -> Void)?
    /// What the view last showed, so an update that changes nothing for this card costs nothing.
    private var shown: (card: Card, context: CardContext)?
    private var laidOut = CGSize.zero

    init(card: Card) {
        self.card = card
        super.init(frame: CardView.frame(for: card))
        isUserInteractionEnabled = false

        body.layer.cornerRadius = Theme.Radius.card
        body.layer.masksToBounds = true
        body.backgroundColor = Theme.surface
        addSubview(body)

        titleBar.backgroundColor = Theme.bar
        titleRule.backgroundColor = Theme.hairline
        body.addSubview(titleBar)
        body.addSubview(content)
        body.addSubview(titleRule)

        iconView.contentMode = .center
        iconView.tintColor = Theme.ink
        titleBar.addSubview(iconView)
        nameLabel.font = Theme.mono(Theme.Size.body, .medium)
        nameLabel.textColor = Theme.ink
        nameLabel.lineBreakMode = .byTruncatingTail
        titleBar.addSubview(nameLabel)
        titleBar.addSubview(runBadge)

        overview.alpha = 0
        overviewName.textAlignment = .center
        overviewName.textColor = Theme.ink
        overviewName.numberOfLines = 2
        overviewName.lineBreakMode = .byTruncatingTail
        overviewDetail.textAlignment = .center
        overviewDetail.textColor = Theme.inkSecondary
        overviewDetail.lineBreakMode = .byTruncatingTail
        overview.addSubview(overviewName)
        overview.addSubview(overviewDetail)
        body.addSubview(overview)

        grip.fillColor = nil
        grip.lineWidth = 1
        layer.addSublayer(grip)

        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CardView, _) in view.restyle(animated: false) }
        rebuildPorts()
        applyCard()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func frame(for card: Card) -> CGRect {
        CanvasGeometry.frame(of: card).insetBy(dx: -gutter, dy: 0)
    }

    /// Whether `update` would change anything. A card dragged on the Mac re-syncs the whole canvas many
    /// times a second; the cards that didn't move skip the work.
    func isCurrent(card new: Card, context: CardContext) -> Bool {
        guard let shown else { return false }
        return shown.card == new && shown.context == context
    }

    /// Brings the view in line with the model. Subclasses add their own state on top.
    func update(card new: Card, context: CardContext) {
        let isFirst = shown == nil
        shown = (new, context)
        let portsChanged = ports(of: new) != ports(of: card) || acceptsInput(new) != acceptsInput(card)
        card = new
        self.context = context
        // By its middle and its size, which hold good while the card is still growing into place.
        let target = CardView.frame(for: new), middle = CGPoint(x: target.midX, y: target.midY)
        if bounds.size != target.size { bounds.size = target.size }
        if center != middle { center = middle }
        if portsChanged { rebuildPorts() }
        syncButtons()
        applyCard()

        inputDot?.isLinked = context.linkedInputs
        for dot in outputDots { dot.isLinked = context.linkedPorts.contains(dot.port) }

        if context.mark.failed {
            runBadge.set("✕", tone: .fail)
        } else if runCount > 0 {
            runBadge.set(runCount > 1 ? "✓ \(runCount)" : "✓", tone: .pass)
        } else {
            runBadge.set("", tone: .plain)
        }
        overviewName.text = new.name
        // A card still called by its kind's name doesn't need telling twice.
        let said = overviewText.caseInsensitiveCompare(new.name) == .orderedSame ? nil : overviewText
        let count = runCount > 0 ? (runCount > 1 ? "✓ \(runCount)" : "✓") : nil
        overviewDetail.text = [said, count].compactMap { $0 }.joined(separator: " · ")
        speak()
        restyle(animated: !isFirst)
        // A card that only moved keeps its size, so nothing would lay it out again by itself.
        setNeedsLayout()
    }

    /// Called when the overview has closed over the card, and when it is about to lift. What it covers
    /// stops being drawn: with the whole canvas faded, as it is while the Mac is away, a title bar or a
    /// terminal under the overview would otherwise show through it.
    private func setCovered(_ isCovered: Bool) {
        for view in [titleBar, content, titleRule] where view.isHidden != isCovered { view.isHidden = isCovered }
    }

    /// What the overview says under the name. Subclasses say what the card is doing.
    var overviewText: String { card.kind.label }

    /// What the title bar's badges say, left to right, for a test to read.
    var badgeTexts: [String] { (titleAccessories.reversed() + [runBadge]).filter { !$0.isHidden }.map(\.text) }

    private func applyZoom(from old: CGFloat) {
        let shows = zoom < Self.overviewBelow
        if shows != (old < Self.overviewBelow) || (shows && overview.alpha == 0) {
            // What the overview covers is put back before it starts to fade, and taken away once it has closed over it.
            if !shows { setCovered(false) }
            UIView.animate(withDuration: Theme.Motion.isAllowed ? Theme.Motion.standardDuration : 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.overview.alpha = shows ? 1 : 0
            } completion: { _ in
                if self.zoom < Self.overviewBelow { self.setCovered(true) }
            }
        }
        // The overview's type is sized to read the same on screen whatever the zoom.
        if shows { setNeedsLayout() }
    }

    /// How many times the run has passed through this card. An End counts what reached it; every other
    /// card counts what left it.
    var runCount: Int {
        card.kind == .end ? context.mark.arrivals : context.mark.passes
    }

    private func applyCard() {
        if nameLabel.text != card.name { nameLabel.text = card.name }
        iconView.image = UIImage(systemName: CanvasGeometry.icon(for: card.kind),
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        accessibilityLabel = "\(card.kind.label) card \(card.name)"
        accessibilityIdentifier = "card-\(card.id)"
        speak()
    }

    /// What VoiceOver says after the card's name: what it is doing, whether it is waiting on the person,
    /// where the run went, and anything wrong with how it is set up. The same things the badges, the tint
    /// and the warning line say to the eye.
    /// Says again what the card is doing, when something a subclass speaks of has changed.
    func refreshSpoken() { speak() }

    private func speak() {
        var parts = spokenState
        if context.mark.failed {
            parts.append("The run stopped here")
        } else if runCount > 0 {
            parts.append(runCount == 1 ? "The run passed through once" : "The run passed through \(runCount) times")
        }
        if let warning = context.warning { parts.append(warning) }
        accessibilityValue = parts.joined(separator: ". ")
        accessibilityTraits = context.isSelected ? [.button, .selected] : .button
    }

    /// What the card is doing, and whether it is waiting on the person. Subclasses say more.
    var spokenState: [String] { context.waiting.map { [$0.prefix(1).uppercased() + $0.dropFirst()] } ?? [] }

    /// Selects the card, when VoiceOver's double tap lands on it. A finger's tap is the canvas's to work out.
    var onActivate: (() -> Void)?

    // MARK: Buttons

    private func syncButtons() {
        let wanted = context.buttons
        if buttonViews.map(\.button) != wanted {
            if buttonViews.count == wanted.count {
                for (view, button) in zip(buttonViews, wanted) { view.set(button) }
            } else {
                buttonViews.forEach { $0.removeFromSuperview() }
                buttonViews = wanted.map { button in
                    let view = CardButtonView(button)
                    // Drawn as finely as the rest of the card is being drawn at this zoom.
                    view.contentScaleFactor = nameLabel.contentScaleFactor
                    view.subviews.forEach { $0.contentScaleFactor = nameLabel.contentScaleFactor }
                    content.addSubview(view)
                    return view
                }
            }
        }
        refreshActions()
    }

    /// What VoiceOver can do on the card besides selecting it: each of its buttons, and what a subclass adds.
    func refreshActions() {
        let presses = context.buttons.filter(\.isEnabled).map { button in
            UIAccessibilityCustomAction(name: button.title) { [weak self] _ in
                self?.onPress?(button.press)
                return self?.onPress != nil
            }
        }
        let all = extraActions + presses
        accessibilityCustomActions = all.isEmpty ? nil : all
    }

    /// Said before the buttons': while the flow is being edited, what a finger does by dragging and holding.
    /// A subclass adds its own.
    var extraActions: [UIAccessibilityCustomAction] {
        guard context.isEditing else { return [] }
        let id = card.id, step = Double(CanvasGeometry.gridStep)
        func action(_ name: String, _ edit: EditAction) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.onEdit?(edit)
                return self?.onEdit != nil
            }
        }
        var all = [action("Move left", .nudge([id], dx: -step, dy: 0)), action("Move right", .nudge([id], dx: step, dy: 0)),
                   action("Move up", .nudge([id], dx: 0, dy: -step)), action("Move down", .nudge([id], dx: 0, dy: step))]
        if !ports(of: card).isEmpty { all.append(action("Link to…", .showLinks(from: id))) }
        all.append(action("Duplicate", .duplicate([id])))
        all.append(action("Copy", .copy([id])))
        all.append(action("Cut", .cut([id])))
        all.append(action("Delete", .delete(cards: [id], links: [])))
        return all
    }

    /// Lays the buttons out in one row inside `row`, from its left edge, or in its middle. A row too
    /// narrow for them shares what there is.
    func layoutButtons(in row: CGRect, centred: Bool = false) {
        guard !buttonViews.isEmpty else { return }
        let gap: CGFloat = 6
        var widths = buttonViews.map(\.wanted)
        let room = max(0, row.width - gap * CGFloat(widths.count - 1))
        if widths.reduce(0, +) > room { widths = widths.map { _ in room / CGFloat(widths.count) } }
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        var x = centred ? row.midX - total / 2 : row.minX
        for (view, width) in zip(buttonViews, widths) {
            view.frame = CGRect(x: x, y: row.midY - CardButtonView.height / 2, width: width, height: CardButtonView.height)
            x += width + gap
        }
    }

    /// Each button with where it is drawn, in the canvas's own points.
    var buttonsShown: [(title: String, isEnabled: Bool, drawn: CGRect)] {
        guard !isHidden, zoom >= Self.overviewBelow else { return [] }
        return buttonViews.map { view in
            (view.button.title, view.button.isEnabled,
             view.frame.offsetBy(dx: card.x, dy: card.y + CanvasGeometry.titleHeight))
        }
    }

    /// Where a tap presses each button, in the canvas's own points: where it is drawn, and the reach
    /// around it that makes it a finger's width on screen whatever the zoom. Nothing when the card is too
    /// far out to read, where the banner and the details have the same buttons at full size.
    func pressTargets(zoom: CGFloat) -> [(press: Press, drawn: CGRect, reach: CGRect)] {
        guard !isHidden, zoom >= Self.overviewBelow else { return [] }
        let least = Theme.Touch.target / max(zoom, 0.01)
        return buttonViews.filter(\.button.isEnabled).map { view in
            let drawn = view.frame.offsetBy(dx: card.x, dy: card.y + CanvasGeometry.titleHeight)
            let reach = drawn.insetBy(dx: min(0, (drawn.width - least) / 2), dy: min(0, (drawn.height - least) / 2))
            return (view.button.press, drawn, reach)
        }
    }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return onActivate != nil
    }

    private func rebuildPorts() {
        inputDot?.removeFromSuperview()
        outputDots.forEach { $0.removeFromSuperview() }
        inputDot = nil
        outputDots = []
        if acceptsInput(card) {
            let dot = PortDotView(port: "in")
            addSubview(dot)
            inputDot = dot
        }
        for port in ports(of: card) {
            let dot = PortDotView(port: port)
            addSubview(dot)
            outputDots.append(dot)
        }
    }

    /// The Mac's `layout()`, with the same numbers.
    override func layoutSubviews() {
        super.layoutSubviews()
        let g = CardView.gutter, title = CanvasGeometry.titleHeight
        body.frame = CGRect(x: g, y: 0, width: bounds.width - g * 2, height: bounds.height)
        titleBar.frame = CGRect(x: 0, y: 0, width: body.bounds.width, height: title)
        titleRule.frame = CGRect(x: 0, y: title - 1, width: body.bounds.width, height: 1)
        content.frame = CGRect(x: 0, y: title, width: body.bounds.width, height: max(0, body.bounds.height - title))
        iconView.frame = CGRect(x: 9, y: 7, width: 14, height: 14)

        // Badges sit at the title's right, the run badge outermost; the name takes what is left.
        var right = titleBar.bounds.width - titleTrailing
        for badge in [runBadge] + titleAccessories where !badge.isHidden {
            badge.frame.origin = CGPoint(x: right - badge.bounds.width, y: (title - badge.bounds.height) / 2)
            right = badge.frame.minX - 5
        }
        nameLabel.frame = CGRect(x: 29, y: 6, width: max(0, right - 29), height: 16)

        overview.frame = body.bounds
        if zoom < Self.overviewBelow {
            let scale = 1 / max(zoom, 0.01)
            overviewName.font = Theme.mono(min(44, 13 * scale), .medium)
            overviewDetail.font = Theme.mono(min(32, 10 * scale))
            let width = max(0, overview.bounds.width - 24)
            let nameHeight = min(overviewName.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height, overview.bounds.height * 0.6)
            let detailHeight = overviewDetail.intrinsicContentSize.height
            let top = max(4, (overview.bounds.height - nameHeight - detailHeight - 4) / 2)
            overviewName.frame = CGRect(x: 12, y: top, width: width, height: nameHeight)
            overviewDetail.frame = CGRect(x: 12, y: top + nameHeight + 4, width: width, height: detailHeight)
        }

        let origin = CGPoint(x: card.x - g, y: card.y)
        if let dot = inputDot { place(dot, at: CanvasGeometry.inputPoint(of: card), origin: origin) }
        for dot in outputDots { place(dot, at: CanvasGeometry.outputPoint(of: card, port: dot.port), origin: origin) }

        if laidOut != bounds.size {
            laidOut = bounds.size
            // The Mac's `ResizeGripView`: three short diagonal strokes in the corner.
            let s = CanvasGeometry.resizeHandle
            let corner = CGRect(x: bounds.width - g - s, y: bounds.height - s, width: s, height: s)
            let strokes = CGMutablePath()
            for inset in stride(from: CGFloat(5), through: 11, by: 3) {
                strokes.move(to: CGPoint(x: corner.maxX - 3, y: corner.maxY - inset))
                strokes.addLine(to: CGPoint(x: corner.maxX - inset, y: corner.maxY - 3))
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            grip.path = strokes
            CATransaction.commit()
        }
        layoutContent()
    }

    /// Extra badges a subclass shows in the title bar, right to left after the run badge.
    var titleAccessories: [BadgeLabel] { [] }

    /// How far from the title bar's right edge the badges start. A subclass with something of its own in
    /// that corner asks for more.
    var titleTrailing: CGFloat { 8 }

    /// Subclasses lay out what sits under the title.
    func layoutContent() {}

    private func place(_ dot: PortDotView, at point: CGPoint, origin: CGPoint) {
        dot.frame.origin = CGPoint(x: point.x - origin.x - dot.bounds.width / 2, y: point.y - origin.y - dot.bounds.height / 2)
    }

    // MARK: Colour

    /// The outline says the most pressing thing about the card: a link is about to land, it is selected, it
    /// failed, it is live, or nothing in particular.
    var outline: (color: UIColor, width: CGFloat) {
        switch context.linkDrop {
        case .accepts: return (Theme.live, Theme.Stroke.selected)
        case .refuses: return (Theme.failInk, Theme.Stroke.selected)
        case .none: break
        }
        if context.isSelected { return (Theme.select, Theme.Stroke.selected) }
        if context.mark.failed { return (Theme.failInk, Theme.Stroke.link) }
        if context.isLive { return (Theme.live, Theme.Stroke.link) }
        return (Theme.ink, Theme.Stroke.card)
    }

    /// Layer colours are set by hand, because a layer doesn't follow a change between light and dark.
    private func restyle(animated: Bool) {
        let outline = outline
        // The outline eases, so selecting doesn't snap.
        ease(body.layer, "borderColor", to: outline.color.cg(in: self), animated: animated)
        ease(body.layer, "borderWidth", to: outline.width, animated: animated)
        // From far out, the overview's tint is what says a card is live or where a run stopped.
        overview.backgroundColor = context.mark.failed ? Theme.failTint : context.isLive ? Theme.liveTint : Theme.surface
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grip.strokeColor = Theme.inkSecondary.cg(in: self)
        CATransaction.commit()
    }

    /// The Mac's `CALayer.ease`: sets a value and, if it changed, slides to it from what is on screen.
    private func ease(_ layer: CALayer, _ keyPath: String, to value: Any, animated: Bool) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard animated, Theme.Motion.isAllowed, let from, !CFEqual(from as CFTypeRef, value as CFTypeRef) else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = Theme.Motion.quickDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: keyPath)
    }

    // MARK: Appearing

    /// A new card settles into place: it fades in while growing the last few percent.
    func playDrawIn() {
        guard Theme.Motion.isAllowed else { return }
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: Theme.Motion.standardDuration, delay: 0, options: [.curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        }
    }
}

/// One named output of a card: its name and how many times the run has left by it. The output taken last is
/// tinted, so the run's latest turn is visible at a glance. The Mac's `PortRowView`.
private final class PortRowView: UIView {
    private let nameLabel = UILabel()
    private let countLabel = UILabel()

    init() {
        super.init(frame: .zero)
        nameLabel.font = Theme.mono(Theme.Size.caption, .medium)
        nameLabel.textAlignment = .right
        nameLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = Theme.mono(Theme.Size.caption)
        addSubview(nameLabel)
        addSubview(countLabel)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(name: String, count: Int, isLatest: Bool) {
        nameLabel.text = name
        countLabel.text = count > 0 ? "\(count)" : ""
        nameLabel.textColor = isLatest ? Theme.liveInk : Theme.ink
        countLabel.textColor = isLatest ? Theme.liveInk : Theme.inkSecondary
        backgroundColor = isLatest ? Theme.liveTint : .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        countLabel.frame = CGRect(x: 10, y: 4, width: 40, height: 14)
        nameLabel.frame = CGRect(x: 52, y: 4, width: max(0, bounds.width - 52 - 14), height: 14)
    }
}

/// A logic card: a line saying what it is set to, a row for each named output, and a warning when its
/// wiring would leave a run stuck. The Mac's `LogicCardView`.
final class LogicCardView: CardView {
    private let summaryLabel = UILabel()
    private let warningLabel = UILabel()
    private var portRows: [PortRowView] = []

    override init(card: Card) {
        super.init(card: card)
        summaryLabel.font = Theme.sans(Theme.Size.body)
        summaryLabel.numberOfLines = 0
        summaryLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(summaryLabel)
        warningLabel.font = Theme.mono(Theme.Size.caption, .medium)
        warningLabel.textColor = Theme.failInk
        warningLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(warningLabel)
    }

    /// What the card says under its title, for a test to read.
    var summaryText: String { summaryLabel.text ?? "" }

    override func update(card new: Card, context: CardContext) {
        super.update(card: new, context: context)
        let progress = context.waiting ?? runProgress(of: new, context: context)
        let summary = CardSummary.text(for: new, inputs: context.inputCount)
        summaryLabel.text = progress ?? context.result ?? summary
        summaryLabel.textColor = progress != nil ? Theme.liveInk : context.result != nil ? Theme.ink : Theme.inkSecondary
        warningLabel.text = context.warning ?? ""
        warningLabel.isHidden = context.warning == nil

        let named = ports(of: new).count > 1 ? ports(of: new) : []
        if portRows.count != named.count {
            portRows.forEach { $0.removeFromSuperview() }
            portRows = named.map { _ in
                let row = PortRowView()
                content.addSubview(row)
                return row
            }
        }
        for (row, port) in zip(portRows, named) {
            row.set(name: portLabel(port), count: context.mark.ports[port] ?? 0, isLatest: context.mark.lastPort == port)
        }
    }

    /// What an And or an Or is doing in the run, in place of its usual summary.
    private func runProgress(of card: Card, context: CardContext) -> String? {
        let mark = context.mark
        switch card.kind {
        case .and where mark.holding > 0:
            return "Waiting: \(mark.holding) of \(context.inputCount) have answered"
        case .or where mark.passes > 0 && mark.holding > 0:
            return "Passed the first on, ignored \(mark.holding)"
        default:
            return nil
        }
    }

    override func layoutContent() {
        let w = content.bounds.width
        let foot = CGFloat(portRows.count) * CanvasGeometry.portRowHeight
        let warningHeight: CGFloat = warningLabel.isHidden ? 0 : 15
        // Buttons sit in a row under the summary, which gives up the room for them. On a card of the
        // usual height that leaves the summary one line, so it starts a little higher to fit it whole.
        let buttonRow: CGFloat = buttonViews.isEmpty ? 0 : CardButtonView.height + 2
        let summaryTop: CGFloat = buttonViews.isEmpty ? 6 : 4
        let summaryHeight = max(0, content.bounds.height - foot - warningHeight - 12 - buttonRow)
        let buttonsTop = content.bounds.height - foot - warningHeight - buttonRow
        layoutButtons(in: CGRect(x: 10, y: buttonsTop, width: max(0, w - 20), height: CardButtonView.height))
        // A label here centres its text in its frame, where the Mac's starts at the top. So the frame is
        // only as tall as the text, up to the room the Mac gives it.
        let needed = summaryLabel.sizeThatFits(CGSize(width: max(0, w - 20), height: .greatestFiniteMagnitude)).height
        let room = buttonViews.isEmpty ? summaryHeight : max(0, buttonsTop - summaryTop - 2)
        summaryLabel.frame = CGRect(x: 10, y: summaryTop, width: max(0, w - 20), height: min(ceil(needed), room))
        warningLabel.frame = CGRect(x: 10, y: buttonViews.isEmpty ? 6 + summaryHeight : buttonsTop + buttonRow, width: max(0, w - 20), height: 15)
        for (i, row) in portRows.enumerated() {
            row.frame = CGRect(x: 1, y: content.bounds.height - foot + CGFloat(i) * CanvasGeometry.portRowHeight,
                               width: w - 2, height: CanvasGeometry.portRowHeight)
        }
    }
}

/// An agent's card: its session's state beside the name, and the place its terminal goes under the title.
/// The Mac's `AgentCardView`. Its Start button is here when this device may control the Mac, and a line
/// saying where to start it when it may not. The "restart to apply" badge isn't: only the Mac knows which
/// settings a session is behind on.
final class AgentCardView: CardView {
    private let stateBadge = BadgeLabel()
    /// What the session cost in the run on show.
    private let costBadge = BadgeLabel()
    /// Where the terminal goes, in the terminal's own background colour.
    let terminalHolder = UIView()
    /// Stands where the Mac has its Start button, while no session is running.
    private let hintLabel = UILabel()
    private(set) weak var terminal: UIView?
    /// The mark in the title bar's corner that opens the terminal full screen. Only this app has it: on
    /// the Mac the terminal is read where it is.
    private let expandIcon = UIImageView()
    private static let expandSize: CGFloat = 14
    private var stateText = ""
    /// The card's browser half, while its Browser switch is on: terminal on the left, page on the right, as on the Mac.
    private(set) var browserHalf: BrowserHalfView?
    private let browserRule = UIView()

    override var overviewText: String { stateText }

    override var spokenState: [String] {
        let state = context.sessionState
        var parts = [stateText.prefix(1).uppercased() + stateText.dropFirst()]
        if state == .needsYou { parts.append("Waiting for you in its terminal") }
        if !hintLabel.isHidden { parts.append(hintLabel.text ?? "") }
        if let cost = context.cost { parts.append("Cost \(cost)") }
        if let browserHalf {
            // The page is a picture, and VoiceOver can only say what it is of.
            let page = browserHalf.shown.page
            if let notice = (page ?? RemoteBrowserPage()).notice {
                parts.append("Browser: \(notice.words)")
            } else if let page {
                let name = page.title.isEmpty ? (page.url.isEmpty ? "a blank page" : page.url) : page.title
                parts.append("Browser showing \(name), a picture of the page on your Mac")
            }
        }
        return parts.filter { !$0.isEmpty }
    }

    /// Opens the terminal full screen, for VoiceOver, which can't reach the mark in the title's corner.
    var onExpand: (() -> Void)?
    /// Opens the card's browser full screen, for VoiceOver, which can't reach the mark at the end of its bar.
    var onExpandBrowser: (() -> Void)?

    override init(card: Card) {
        super.init(card: card)
        titleBar.addSubview(stateBadge)
        titleBar.addSubview(costBadge)
        terminalHolder.backgroundColor = Theme.terminal
        terminalHolder.clipsToBounds = true
        content.addSubview(terminalHolder)
        hintLabel.font = Theme.mono(Theme.Size.body)
        hintLabel.textColor = Theme.terminalInk.withAlphaComponent(0.6)
        hintLabel.textAlignment = .center
        content.addSubview(hintLabel)
        expandIcon.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        expandIcon.contentMode = .center
        expandIcon.tintColor = Theme.ink
        expandIcon.isHidden = true
        titleBar.addSubview(expandIcon)
        browserRule.backgroundColor = Theme.hairline
        browserRule.isHidden = true
        content.addSubview(browserRule)
    }

    /// Where a tap opens the card's browser full screen, in the canvas's own points, or nil when it has none.
    /// Given a finger's width on screen whatever the zoom, as the terminal's mark is.
    func browserExpandTarget(zoom: CGFloat) -> CGRect? {
        guard let browserHalf, !isHidden, zoom >= Self.overviewBelow else { return nil }
        let mark = browserHalf.convert(browserHalf.expandFrame, to: superview)
        let reach = max(Self.expandSize / 2, Theme.Touch.target / 2 / max(zoom, 0.01))
        return CGRect(x: mark.midX - reach, y: mark.midY - reach, width: reach * 2, height: reach * 2)
    }

    /// Draws what the card's browser shows now.
    func showBrowser(page: RemoteBrowserPage?, picture: BrowserPicture?) {
        guard let browserHalf else { return }
        let hadPage = browserHalf.shown.page
        browserHalf.show(page: page, picture: picture)
        // What VoiceOver says only changes with the bar, not with each picture.
        if hadPage != page { refreshSpoken() }
    }

    override var titleAccessories: [BadgeLabel] { [stateBadge, costBadge] }
    override var titleTrailing: CGFloat { expandIcon.isHidden ? 8 : 8 + Self.expandSize + 6 }

    /// Where a tap opens the terminal full screen, in the canvas's own points, or nil when there is no
    /// terminal to open. The mark is small and the card takes no touches, so the canvas asks for this and
    /// gives it a finger's width on screen whatever the zoom.
    func expandTarget(zoom: CGFloat) -> CGRect? {
        guard terminal != nil, !isHidden, zoom >= Self.overviewBelow else { return nil }
        let centre = CGPoint(x: card.x + card.width - 8 - Self.expandSize / 2, y: card.y + CanvasGeometry.titleHeight / 2)
        let reach = max(Self.expandSize / 2, Theme.Touch.target / 2 / max(zoom, 0.01))
        return CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2)
    }

    /// Where a terminal sits inside `terminalHolder`: a few points of padding so text doesn't touch the
    /// card's edge or its corner.
    var terminalFrame: CGRect { terminalHolder.bounds.insetBy(dx: 6, dy: 4) }

    /// Puts a session's terminal in the card, or takes it out. The view is given `terminalFrame` whenever the card is laid out.
    func attach(terminal view: UIView?) {
        // The same view may have been away in the full-screen view and come back.
        guard terminal !== view || view?.superview !== terminalHolder else { return }
        // One that has already been taken elsewhere is left where it is.
        if let old = terminal, old !== view, old.superview === terminalHolder { old.removeFromSuperview() }
        terminal = view
        if let view { terminalHolder.addSubview(view) }
        expandIcon.isHidden = view == nil
        refreshActions()
        setNeedsLayout()
    }

    override var extraActions: [UIAccessibilityCustomAction] {
        (terminal == nil ? [] : [UIAccessibilityCustomAction(name: "Open the terminal full screen") { [weak self] _ in
            self?.onExpand?()
            return self?.onExpand != nil
        }]) + (browserHalf == nil ? [] : [UIAccessibilityCustomAction(name: "Open the browser full screen") { [weak self] _ in
            self?.onExpandBrowser?()
            return self?.onExpandBrowser != nil
        }]) + super.extraActions
    }

    override func update(card new: Card, context: CardContext) {
        let state = context.sessionState
        // In a run, an agent that has been handed work but hasn't started on it yet is waiting.
        let isWaiting = context.isRunning && context.mark.arrivals > context.mark.passes && state == .idle
        let tone: BadgeLabel.Tone = switch state {
        case .working, .needsYou: .live
        case .failed, .exited: .fail
        case .idle: isWaiting ? .live : .plain
        case .notStarted, .starting: .plain
        }
        // An agent that asked a question is idle, but the run is owed its reply.
        let asked = state == .idle ? context.waiting : nil
        stateText = asked ?? (isWaiting ? "waiting" : state.label.lowercased())
        stateBadge.set(stateText, tone: asked == nil ? tone : .live)
        costBadge.set(context.cost ?? "", tone: .plain)
        // With a button to start it from here, there is nothing to send the person to the Mac for.
        hintLabel.isHidden = (state != .notStarted && state != .exited) || !context.buttons.isEmpty
        hintLabel.text = state == .exited ? "Restart it on your Mac" : "Start it on your Mac"
        let wantsBrowser = new.browser == true
        if wantsBrowser != (browserHalf != nil) {
            browserHalf?.removeFromSuperview()
            browserHalf = wantsBrowser ? BrowserHalfView() : nil
            if let browserHalf { content.insertSubview(browserHalf, belowSubview: browserRule) }
            browserRule.isHidden = !wantsBrowser
            refreshActions()
        }
        super.update(card: new, context: context)
    }


    override func layoutContent() {
        // With a browser the card is split down the middle, as on the Mac: terminal on the left, page on the right.
        var left = content.bounds
        if let browserHalf {
            left.size.width = (content.bounds.width / 2).rounded()
            browserRule.frame = CGRect(x: left.maxX, y: 0, width: 1, height: content.bounds.height)
            browserHalf.frame = CGRect(x: left.maxX + 1, y: 0, width: content.bounds.width - left.maxX - 1, height: content.bounds.height)
        }
        terminalHolder.frame = left
        terminal?.frame = terminalFrame
        let size = Self.expandSize
        expandIcon.frame = CGRect(x: titleBar.bounds.width - 8 - size, y: (CanvasGeometry.titleHeight - size) / 2, width: size, height: size)
        hintLabel.frame = left.insetBy(dx: 10, dy: 0)
        layoutButtons(in: left.insetBy(dx: 10, dy: 0), centred: true)
        // A terminal put in the card later mustn't cover them.
        buttonViews.forEach(content.bringSubviewToFront)
    }
}
