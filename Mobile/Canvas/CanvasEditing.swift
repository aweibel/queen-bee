import QueenBeeCore
import UIKit

/// What is drawn over the cards while something is being dragged: the lines that show a card is lined up
/// with another, and the box that selects cards. The Mac's `CanvasOverlayView`. It never takes a touch.
final class CanvasOverlayView: UIView {
    private let lines = CAShapeLayer()
    private let box = CAShapeLayer()
    private var guides: [Snapping.Guide] = []
    private var marquee: CGRect?
    /// The canvas's zoom, so the lines are a hairline on screen whatever it is.
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { redraw() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        lines.fillColor = nil
        layer.addSublayer(box)
        layer.addSublayer(lines)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CanvasOverlayView, _) in view.redraw() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(guides: [Snapping.Guide], marquee: CGRect?) {
        guard guides != self.guides || marquee != self.marquee else { return }
        self.guides = guides
        self.marquee = marquee
        redraw()
    }

    private func redraw() {
        let hairline = 1 / max(zoom, 0.01), pad = 12 * hairline
        let path = CGMutablePath()
        for guide in guides {
            if guide.isVertical {
                path.move(to: CGPoint(x: guide.position, y: guide.start - pad))
                path.addLine(to: CGPoint(x: guide.position, y: guide.end + pad))
            } else {
                path.move(to: CGPoint(x: guide.start - pad, y: guide.position))
                path.addLine(to: CGPoint(x: guide.end + pad, y: guide.position))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lines.path = path
        lines.lineWidth = hairline
        lines.strokeColor = Theme.select.cg(in: self)
        box.path = marquee.map { CGPath(rect: $0, transform: nil) }
        box.lineWidth = hairline
        box.strokeColor = Theme.select.cg(in: self)
        box.fillColor = Theme.select.withAlphaComponent(0.08).cg(in: self)
        CATransaction.commit()
    }
}

/// Editing the flow by touch. Editing is a mode: with it off, none of this takes a touch, and the canvas is
/// the watching canvas it always was.
///
/// Cards take no touches, so the canvas works out what a finger came down on, with `TouchEdit.down`: a
/// card's corner resizes it, one of its output dots starts a link, its title bar moves it, and anything else
/// is the canvas's own to pan. That is settled the moment the finger comes down, in
/// `gestureRecognizer(_:shouldReceive:)`: the recogniser here is given the touch only when it is an edit's,
/// and the scroll view's own pan waits for this one to fail. So exactly one of them ever follows a finger,
/// and which one never depends on how fast the finger moves.
///
/// Everything a recogniser does goes through `beginDrag`, `continueDrag` and `endDrag`, `tap` and
/// `showMenu`, in canvas points. A test calls the same ones.
extension CanvasView {
    var edit: EditModel { client.edit }

    func setUpEditing() {
        editPan.addTarget(self, action: #selector(editPanned(_:)))
        // A second finger is a pinch, and a pinch is never an edit.
        editPan.maximumNumberOfTouches = 1
        editPan.delegate = self
        scrollView.addGestureRecognizer(editPan)
        scrollView.panGestureRecognizer.require(toFail: editPan)
        longPress.addTarget(self, action: #selector(longPressed(_:)))
        longPress.delegate = self
        scrollView.addGestureRecognizer(longPress)
    }

    /// Whether one of the recognisers that edit takes a touch at a canvas point. Nil for any other recogniser.
    func editingTakes(_ recogniser: UIGestureRecognizer, at point: CGPoint) -> Bool? {
        if recogniser === editPan { return takesDrag(at: point) }
        if recogniser === longPress { return client.isEditing }
        return nil
    }

    /// Makes a change VoiceOver asked for on a card, a link or a group.
    func perform(_ action: EditAction) {
        Task { await client.act(action) }
    }

    /// The middle of the part of the canvas nothing floats over, in canvas points: where a card added from the bar goes.
    var middleOfWhatShows: CGPoint { canvasPoint(at: middleOfRoom) }

    // MARK: What a finger came down on

    /// Where each card on show can be taken hold of, the one drawn last at the end.
    private var cardTargets: [TouchEdit.CardTargets] {
        let side = CanvasGeometry.resizeHandle
        return content.cards.filter { !content.folded.contains($0.id) }.map { card in
            let frame = CanvasGeometry.frame(of: card)
            return TouchEdit.CardTargets(
                id: card.id, frame: frame, titleHeight: CanvasGeometry.titleHeight,
                grip: CGRect(x: frame.maxX - side, y: frame.maxY - side, width: side, height: side),
                outputs: ports(of: card).map { .init(port: $0, point: CanvasGeometry.outputPoint(of: card, port: $0)) })
        }
    }

    private var groupTargets: [TouchEdit.GroupTarget] {
        groupViews.values.sorted { $0.look.group.id < $1.look.group.id }.map { TouchEdit.GroupTarget(id: $0.look.group.id, handle: $0.handle) }
    }

    /// What a drag that starts at a canvas point is for, at the zoom the canvas is at.
    func down(at point: CGPoint) -> TouchEdit.Down {
        TouchEdit.down(at: point, zoom: scrollView.zoomScale, cards: cardTargets, groups: groupTargets)
    }

    /// Whether a drag from a canvas point edits the flow. When it doesn't, the canvas pans as it always has.
    func takesDrag(at point: CGPoint) -> Bool {
        guard client.isEditing, edit.gesture == nil else { return false }
        switch down(at: point) {
        // Bare canvas pans, unless cards are being selected, when it draws the box.
        case .empty: return edit.isSelecting
        // The inside of a card moves nothing: a terminal is never dragged by accident.
        case .body: return false
        // The cards of the last drag are still the Mac's to place until it has answered.
        case .move, .moveGroup, .resize: return edit.carried == nil
        case .link: return true
        }
    }

    // MARK: Drags

    @objc private func editPanned(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: document)
        switch pan.state {
        case .began:
            finger = pan.location(in: self)
            // The gesture begins a few points into the drag: go back to where the finger came down.
            let travel = pan.translation(in: document)
            if beginDrag(at: CGPoint(x: point.x - travel.x, y: point.y - travel.y)) { continueDrag(to: point) }
        case .changed:
            finger = pan.location(in: self)
            continueDrag(to: point)
        case .ended:
            endDrag(at: point)
        case .cancelled, .failed:
            // Taken away by the system. The Mac has the cards where the last step put them, and is told the drag is over.
            endDrag()
        default:
            break
        }
    }

    /// A finger has come down on something that edits, and moved. Returns false when nothing began.
    /// `finger` says where it is on screen, for panning from the edges.
    @discardableResult
    func beginDrag(at point: CGPoint) -> Bool {
        guard takesDrag(at: point), let flow = client.mirror.snapshot?.flow else { return false }
        func frames(_ ids: Set<String>) -> [String: CGRect] {
            Dictionary(uniqueKeysWithValues: flow.cards.filter { ids.contains($0.id) }.map { ($0.id, CanvasGeometry.frame(of: $0)) })
        }
        switch down(at: point) {
        case .move(let id):
            // Dragging one of several selected cards moves them all. Dragging any other card moves it alone.
            // It doesn't select, so a card's details don't open under the finger on the way.
            let picked = model.selection.cardIDs
            edit.begin(.move(frames: frames(picked.contains(id) ? picked : [id]), lead: id), at: point)
        case .moveGroup(let id):
            guard let group = (flow.groups ?? []).first(where: { $0.id == id }) else { return false }
            let all = frames(Set(group.cardIDs))
            // The group settles by where its top-left card lands.
            guard let lead = all.min(by: { ($0.value.minX, $0.value.minY) < ($1.value.minX, $1.value.minY) })?.key else { return false }
            edit.begin(.move(frames: all, lead: lead), at: point)
        case .resize(let id):
            guard let card = flow.card(id) else { return false }
            edit.begin(.resize(cardID: id, start: CanvasGeometry.frame(of: card)), at: point)
        case .link(let card, let port):
            edit.begin(.link(card: card, port: port), at: point)
        case .empty:
            // What is already selected is kept, and the box adds to it, as with Shift on the Mac.
            edit.begin(.box(base: model.selection.cardIDs), at: point)
        case .body:
            return false
        }
        // The canvas is held still under a drag: it isn't carried on by an earlier flick, or zoomed by a second finger.
        tookHold()
        scrollView.pinchGestureRecognizer?.isEnabled = false
        beginEdgePan()
        return true
    }

    /// The finger of a drag is over a canvas point now: because it moved, or because the canvas panned under it.
    func continueDrag(to point: CGPoint) {
        guard let gesture = edit.gesture, let flow = client.mirror.snapshot?.flow else { return }
        let start = edit.grabbedAt, travel = CGPoint(x: point.x - start.x, y: point.y - start.y)
        switch gesture {
        case .move(let frames, let lead):
            guard let leading = frames[lead] else { return }
            // Settled against the cards on show that aren't being dragged, where the Mac has them now.
            let others = flow.cards.filter { frames[$0.id] == nil && !content.folded.contains($0.id) }.map(CanvasGeometry.frame(of:))
            let moved = TouchEdit.moved(frames.mapValues(\.origin), lead: leading, by: travel, others: others,
                                        grid: CanvasGeometry.gridStep, zoom: scrollView.zoomScale)
            var now = frames
            for (id, place) in moved.places { now[id]?.origin = place }
            edit.carry(now, drag: .move, in: flow.id, guides: moved.guides)
            client.dragMoved()
        case .resize(let id, let start):
            guard var card = flow.card(id) else { return }
            card.x = start.minX
            card.y = start.minY
            let size = TouchEdit.resized(card, from: start.size, by: travel, grid: CanvasGeometry.gridStep)
            edit.carry([id: CGRect(origin: start.origin, size: size)], drag: .resize(cardID: id), in: flow.id)
            client.dragMoved()
        case .link(let cardID, let port):
            showPendingLink(from: cardID, port: port, to: point, in: flow)
        case .box(let base):
            let box = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(travel.x), height: abs(travel.y))
            edit.marquee = box
            // Cards folded away in a group can't be seen, so a box drawn over where they were doesn't take them.
            let inside = flow.cards.filter { !content.folded.contains($0.id) && CanvasGeometry.frame(of: $0).intersects(box) }.map(\.id)
            model.select(.of(base.union(inside)))
        }
    }

    /// The finger has lifted, at a canvas point if it is known where. Returns the telling of the Mac, when
    /// there is something to tell it, for a test to wait on.
    @discardableResult
    func endDrag(at point: CGPoint? = nil) -> Task<String?, Never>? {
        guard let gesture = edit.gesture else { return nil }
        if let point { continueDrag(to: point) }
        releaseCanvas()
        switch gesture {
        case .move, .resize:
            edit.dropGesture()
            return Task { await client.dragEnded() }
        case .link(let cardID, let port):
            // Let go over a card, the Mac is asked for the link, and says why not if it can't be made. Anywhere else, nothing is.
            let target = edit.pendingLink?.over
            edit.dropGesture()
            guard let target else { return nil }
            return Task { await client.act(.link(from: cardID, port: port, to: target)) }
        case .box:
            edit.dropGesture()
            return nil
        }
    }

    /// Lets go of a drag without telling the Mac, because this device may no longer tell it anything.
    func letGoOfDrag() {
        releaseCanvas()
        // A recogniser that is switched off and on again gives up the touch it was following.
        if editPan.state == .began || editPan.state == .changed {
            editPan.isEnabled = false
            editPan.isEnabled = true
        }
        edit.dropGesture()
    }

    private func releaseCanvas() {
        endEdgePan()
        scrollView.pinchGestureRecognizer?.isEnabled = true
        finger = nil
    }

    // MARK: Linking

    /// A link is being dragged out of a card's output. The card under the finger shows whether it would
    /// take the link, by the Mac's own rules, and the link is drawn along the route it would have.
    private func showPendingLink(from cardID: String, port: String, to point: CGPoint, in flow: Flow) {
        guard let source = flow.card(cardID) else { return }
        let start = CanvasGeometry.outputPoint(of: source, port: port)
        let target = dropCard(at: point, in: flow).flatMap { $0.id == cardID ? nil : $0 }
        let accepts = target.map { flow.linkProblem(from: cardID, port: port, to: $0.id) == nil } ?? false
        // Over a card that would take the link it lands on that card's input. Anywhere else it follows the finger.
        let end = accepts ? target.map(CanvasGeometry.inputPoint(of:)) ?? point : point
        let landing = accepts ? target.map(CanvasGeometry.frame(of:)) ?? CGRect(origin: point, size: .zero) : CGRect(origin: point, size: .zero)
        let route = LinkRouter.route(from: start, to: end, source: CanvasGeometry.frame(of: source), target: landing)
        let pending = EditModel.PendingLink(from: cardID, port: port, points: route, over: target?.id, accepts: accepts)
        if edit.pendingLink != pending { edit.pendingLink = pending }
    }

    /// The card a link let go of at a canvas point lands on: the one on top, and never one folded away in a
    /// group. A card drawn smaller than a finger is a finger's width to land on.
    private func dropCard(at point: CGPoint, in flow: Flow) -> Card? {
        let cards = flow.cards.filter { !content.folded.contains($0.id) }
        if let on = cards.last(where: { CanvasGeometry.frame(of: $0).insetBy(dx: -CardView.gutter, dy: 0).contains(point) }) { return on }
        let least = TouchEdit.target / max(scrollView.zoomScale, 0.01)
        return cards.last { card in
            let frame = CanvasGeometry.frame(of: card)
            return frame.insetBy(dx: min(0, (frame.width - least) / 2), dy: min(0, (frame.height - least) / 2)).contains(point)
        }
    }

    // MARK: Panning from the edges

    /// The part of this view a drag pans from the edges of: all of it but what the system's bars cover.
    var panBounds: CGRect { bounds.inset(by: safeAreaInsets) }

    /// From now until `endEdgePan`, holding the finger near the canvas's edge pans the canvas that way, and
    /// the drag catches up with the canvas that has slid under a finger that may be standing still.
    private func beginEdgePan() {
        endEdgePan()
        guard let finger else { return }
        edgePan = TouchEdit.EdgePan(depths: TouchEdit.EdgePan.depths(of: finger, in: panBounds))
        edgeLast = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(edgePanStep(_:)))
        link.add(to: .main, forMode: .common)
        edgeLink = link
    }

    private func endEdgePan() {
        edgeLink?.invalidate()
        edgeLink = nil
        edgePan = nil
    }

    @objc private func edgePanStep(_ link: CADisplayLink) {
        guard var pan = edgePan, let finger else { return }
        let now = CACurrentMediaTime(), elapsed = min(now - edgeLast, 0.1), zoom = max(scrollView.zoomScale, 0.01)
        edgeLast = now
        let step = pan.step(depths: TouchEdit.EdgePan.depths(of: finger, in: panBounds), elapsed: elapsed, zoom: zoom)
        edgePan = pan
        guard step != .zero else { return }
        let inset = scrollView.contentInset, size = scrollView.contentSize, was = scrollView.contentOffset
        scrollView.contentOffset = CGPoint(
            x: min(max(was.x + step.x * zoom, -inset.left), max(size.width - bounds.width + inset.right, -inset.left)),
            y: min(max(was.y + step.y * zoom, -inset.top), max(size.height - bounds.height + inset.bottom, -inset.top)))
        if scrollView.contentOffset != was { continueDrag(to: canvasPoint(at: finger)) }
    }

    // MARK: Menus

    @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        showMenu(at: press.location(in: document))
    }

    /// What holding a finger at a canvas point puts up: the menu of the card, link or group there, or on
    /// bare canvas the kinds of card that can be added at that point.
    func showMenu(at point: CGPoint) {
        guard client.isEditing, edit.gesture == nil else { return }
        let item = item(at: point)
        switch item {
        // Held on a card outside what is selected, it is about that card alone, as a right-click is on the Mac.
        case .card(let id): if !model.selection.cardIDs.contains(id) { model.select(item) }
        case .link, .group: model.select(item)
        case .none, .cards: break
        }
        guard var menu = client.menu(for: item, at: point) else { return }
        menu.anchor = document.convert(point, to: nil)
        edit.menu = menu
    }
}
