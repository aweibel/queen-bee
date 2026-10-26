import AppKit
import QueenBeeDesign
import QueenBeeCore

/// A group of cards on the canvas. Unfolded, it is a named frame drawn behind its cards.
/// Folded, it is one small card that stands in for all of them.
final class GroupFrameView: NSView, NSGestureRecognizerDelegate {
    /// How far the frame stands off from its cards, and the room its name takes above them.
    static let padding: CGFloat = 18
    static let titleHeight: CGFloat = 24
    static let foldedSize = CGSize(width: 240, height: 72)

    enum Tone { case plain, live, fail }

    private(set) var group: CardGroup
    weak var canvas: CanvasView?
    private let handle = FlippedView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var tone = Tone.plain
    private var isSelected = false
    private var dragOrigins: [String: CGPoint] = [:]
    private var hasDrawn = false

    override var isFlipped: Bool { true }

    init(group: CardGroup) {
        self.group = group
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.l
        layer?.cornerCurve = .continuous
        handle.wantsLayer = true
        addSubview(handle)
        nameLabel.font = Theme.Canvas.name()
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = Theme.Canvas.label(11.5, .regular)
        detailLabel.lineBreakMode = .byTruncatingTail
        handle.addSubview(nameLabel)
        handle.addSubview(detailLabel)

        handle.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handleMove(_:))))
        handle.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:))))
        handle.addGestureRecognizer(GrabGesture.make(target: self, action: #selector(handleGrab(_:)), delegate: self))
        let double = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        double.numberOfClicksRequired = 2
        handle.addGestureRecognizer(double)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Where a group's view sits: round its cards when unfolded, a small card at their corner when folded.
    /// `zoom` only matters to an unfolded frame: zoomed out, its name strip grows so the name stays readable.
    static func frame(of group: CardGroup, in flow: Flow, zoom: CGFloat = 1) -> CGRect? {
        let frames = flow.cards.filter { group.cardIDs.contains($0.id) }.map(CanvasGeometry.frame(of:))
        guard let first = frames.first else { return nil }
        let box = frames.dropFirst().reduce(first) { $0.union($1) }
        if group.isFolded { return CGRect(origin: box.origin, size: foldedSize) }
        let strip = titleHeight * scale(for: zoom)
        return CGRect(x: box.minX - padding, y: box.minY - padding - strip,
                      width: box.width + padding * 2, height: box.height + padding * 2 + strip)
    }

    /// How much a group's name grows as the canvas zooms out, so it reads about the same on screen.
    static func scale(for zoom: CGFloat) -> CGFloat {
        zoom < 0.7 ? min(3.2, 0.7 / max(zoom, 0.01)) : 1
    }

    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { needsLayout = true } } }

    func update(group new: CardGroup, frame target: CGRect, tone: Tone, isSelected: Bool, detail: String) {
        group = new
        self.tone = tone
        self.isSelected = isSelected
        if frame != target { frame = target }
        nameLabel.stringValue = new.name
        detailLabel.stringValue = detail
        toolTip = new.isFolded ? "Double-click to unfold" : "Drag to move the group. Double-click to fold it into one card."
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let scale = Self.scale(for: zoom)
        if group.isFolded {
            // The folded card is a fixed size, so its type only grows as far as the card has room for.
            let grown = min(scale, 1.7)
            nameLabel.font = Theme.Canvas.name(13 * grown)
            detailLabel.font = Theme.Canvas.label(11.5 * grown, .regular)
            handle.frame = bounds
            let nameHeight = ceil(nameLabel.intrinsicContentSize.height), detailHeight = ceil(detailLabel.intrinsicContentSize.height)
            let top = max(4, (bounds.height - nameHeight - detailHeight - 2) / 2)
            nameLabel.frame = NSRect(x: 12, y: top, width: bounds.width - 24, height: nameHeight)
            detailLabel.frame = NSRect(x: 12, y: top + nameHeight + 2, width: bounds.width - 24, height: detailHeight)
        } else {
            nameLabel.font = Theme.Canvas.name(13 * scale)
            detailLabel.font = Theme.Canvas.label(11.5 * scale, .regular)
            let strip = Self.titleHeight * scale
            handle.frame = NSRect(x: 0, y: 0, width: bounds.width, height: strip)
            nameLabel.sizeToFit()
            let height = ceil(nameLabel.frame.height)
            nameLabel.frame = NSRect(x: 10 * scale, y: (strip - height) / 2, width: min(nameLabel.frame.width, bounds.width * 0.6), height: height)
            detailLabel.sizeToFit()
            detailLabel.frame = NSRect(x: nameLabel.frame.maxX + 8 * scale, y: (strip - ceil(detailLabel.frame.height)) / 2,
                                       width: max(0, bounds.width - nameLabel.frame.maxX - 18 * scale), height: ceil(detailLabel.frame.height))
        }
        window?.invalidateCursorRects(for: self)
    }

    /// The frame's inside is empty canvas: a click there goes through. Only the name strip,
    /// or the whole card when folded, is the group's to take.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func resetCursorRects() {
        addCursorRect(handle.frame, cursor: .openHand)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let folded = group.isFolded
        let fill: NSColor = folded ? (tone == .fail ? Theme.Canvas.failTint : tone == .live ? Theme.Canvas.liveTint : Theme.Canvas.card)
                                   : Theme.Canvas.groupFill
        let edge: NSColor = isSelected ? Theme.Canvas.accent : tone == .fail ? Theme.Canvas.fail : tone == .live ? Theme.Canvas.live : Theme.Canvas.outline
        layer?.ease("backgroundColor", to: fill.cgColor, animated: hasDrawn)
        layer?.ease("borderColor", to: edge.cgColor, animated: hasDrawn)
        layer?.borderWidth = isSelected ? DS.Stroke.focus : DS.Stroke.hairline
        nameLabel.textColor = Theme.Canvas.text
        detailLabel.textColor = tone == .live ? Theme.Canvas.liveText : tone == .fail ? Theme.Canvas.failText : Theme.Canvas.textMuted
        hasDrawn = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Gestures

    @objc private func handleGrab(_ g: NSPressGestureRecognizer) {
        GrabGesture.follow(g, in: window, handle: handle)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
        gestureRecognizer is NSPressGestureRecognizer || other is NSPressGestureRecognizer
    }

    @objc private func handleClick(_ g: NSClickGestureRecognizer) {
        canvas?.controller?.select(.of(Set(group.cardIDs)))
        canvas?.takeFocus()
    }

    @objc private func handleDoubleClick(_ g: NSClickGestureRecognizer) {
        canvas?.controller?.setFolded(!group.isFolded, group: group.id)
    }

    @objc private func handleMove(_ g: NSPanGestureRecognizer) {
        guard let canvas, let controller = canvas.controller else { return }
        switch g.state {
        case .began:
            dragOrigins = controller.dragOrigins(forGroup: group.id)
            controller.beginGesture()
        case .changed, .ended:
            // The group settles by where its top-left card lands.
            let lead = dragOrigins.min { ($0.value.x, $0.value.y) < ($1.value.x, $1.value.y) }?.key ?? group.cardIDs[0]
            canvas.drag(dragOrigins, primary: lead, by: g.translation(in: canvas.document))
            if g.state == .ended {
                canvas.clearGuides()
                controller.endGesture("Move Group")
            }
        case .cancelled, .failed:
            canvas.clearGuides()
            controller.endGesture("Move Group")
        default: break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller = canvas?.controller else { return nil }
        controller.select(.of(Set(group.cardIDs)))
        let id = group.id, folded = group.isFolded
        let menu = NSMenu()
        menu.addItem(menuItem(folded ? "Unfold" : "Fold into One Card") { [weak controller] in controller?.setFolded(!folded, group: id) })
        menu.addItem(menuItem("Ungroup") { [weak controller] in controller?.ungroupSelection() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Duplicate") { [weak controller] in controller?.duplicateSelection() })
        menu.addItem(menuItem("Delete \(group.cardIDs.count) Cards") { [weak controller] in controller?.deleteSelection() })
        return menu
    }
}
