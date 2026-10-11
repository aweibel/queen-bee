import Observation
import QueenBeeCore
import SwiftUI
import UIKit

/// The zoomable canvas of the open flow, drawn to match the Mac's `CanvasView`: the same paper, the same
/// cards in the same places, the same links. A scroll view holds one large surface; cards are its subviews.
///
/// Nothing on it can be moved or changed from here. A finger pans, two fingers zoom, a tap selects, and a
/// double tap on bare paper shows the whole flow. A tap on a button drawn on a card presses it.
final class CanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// As far out and as far in as a pinch goes. The Mac's limits.
    static let minZoom: CGFloat = 0.2
    static let maxZoom: CGFloat = 3
    /// As far out as fitting a flow goes, so a wide one still fits whole.
    private static let fitFloor: CGFloat = 0.05

    private let client: RemoteClient
    private var model: CanvasModel { client.canvas }
    private let paper = PaperView()
    let scrollView = UIScrollView()
    /// The surface cards sit on. Its own coordinates are the flow file's: a card at x 60 is at 60 here.
    let document = UIView()
    private let linkLayer = LinkLayerView()
    private var cardViews: [String: CardView] = [:]
    private var groupViews: [String: GroupFrameView] = [:]

    /// What is drawn now, and what it was worked out from, so a message that changes none of it costs nothing.
    private var content = CanvasContent()
    private var inputs: Inputs?
    private struct Inputs: Equatable {
        var flow: Flow
        var run: RemoteRunState
        var lastRun: RunRecord?
        var siblings: [RemoteFlowSummary]
        var selection: CanvasModel.Selection
        var viewed: RunRecord?
        /// The buttons each card offers. They come and go with "Can control", the connection and each command's answer.
        var buttons: [String: [PressButton]]
    }

    /// Room at the canvas's edges that something floats over, on top of the bars the system puts there.
    var clearance = UIEdgeInsets.zero { didSet { if clearance != oldValue { setNeedsLayout() } } }
    /// The flow is still as it was last fitted, so it is fitted again when the room changes. `fitCap` is the most that fit may zoom in.
    private var isFitted = false
    private var fitCap: CGFloat?
    /// A flow has arrived and hasn't been put in view yet, because the canvas had no size when it came.
    private var awaitsPlacing = false
    /// False until the flow's own cards are on screen, so only cards added later draw in.
    private var didFirstSync = false
    /// The canvas point in the middle of the clear part of the screen, kept so it can stay there when the screen changes shape.
    private var centre = CGPoint.zero
    private var laidOut: (size: CGSize, clear: UIEdgeInsets)?
    private var journey: Journey?
    private var sharpness: CGFloat = 1

    init(client: RemoteClient) {
        self.client = client
        super.init(frame: .zero)
        addSubview(paper)

        document.frame = CGRect(origin: .zero, size: CanvasGeometry.documentSize)
        document.bounds.origin = CGPoint(x: -CanvasGeometry.margin, y: -CanvasGeometry.margin)
        // The link layer covers the whole surface and shares its coordinates, so a link is drawn with the
        // same numbers its cards are placed with.
        linkLayer.frame = document.bounds
        linkLayer.bounds.origin = document.bounds.origin
        document.addSubview(linkLayer)
        linkLayer.onActivate = { [weak self] id in self?.model.select(.link(id)) }

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.contentSize = CanvasGeometry.documentSize
        scrollView.minimumZoomScale = Self.minZoom
        scrollView.maximumZoomScale = Self.maxZoom
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        // The canvas runs under the bars, and works out for itself what they cover.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.addSubview(document)
        addSubview(scrollView)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        double.delegate = self
        scrollView.addGestureRecognizer(double)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        // A double tap only ever starts on bare paper, so a tap on a card or a link isn't kept waiting for one.
        tap.require(toFail: double)
        scrollView.addGestureRecognizer(tap)

        observe()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Model to views

    /// Re-syncs whenever anything `sync` read changes, then watches again.
    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        guard let snapshot = client.mirror.snapshot else {
            // No flow, or one that has been asked for and not sent yet.
            if inputs != nil {
                saveViewport()
                clear()
            }
            return
        }
        if let inputs, inputs.flow.id != snapshot.flow.id {
            saveViewport()
            clear()
        }
        let selection = model.selection, viewed = Self.stillOnShow(model.viewedRun, in: snapshot)
        if viewed != model.viewedRun { model.view(viewed) }
        let abilities = Abilities(canControl: client.mirror.canControl, isConnected: client.state == .connected, snapshot: snapshot,
                                  viewed: viewed, waiting: Array(client.mirror.waiting.values))
        let now = Inputs(flow: snapshot.flow, run: snapshot.run, lastRun: snapshot.runs.last,
                         siblings: client.openFlow?.project.flows ?? [], selection: selection, viewed: viewed, buttons: abilities.cards)
        // Most of what the Mac sends is terminal output and log lines, which change nothing here.
        guard now != inputs else { return }
        let isNew = inputs == nil
        inputs = now
        apply(CanvasContent(snapshot, siblings: now.siblings, selection: selection, viewed: viewed, buttons: now.buttons))
        if isNew {
            awaitsPlacing = true
            setNeedsLayout()
        }
        // What was selected may have been deleted on the Mac.
        switch selection {
        case .card(let id) where snapshot.flow.card(id) == nil: model.select(.none)
        case .link(let id) where !snapshot.flow.links.contains { $0.id == id }: model.select(.none)
        case .group(let id) where !(snapshot.flow.groups ?? []).contains { $0.id == id }: model.select(.none)
        default: break
        }
        #if DEBUG
        model.didChangeWhatIsShown()
        #endif
    }

    /// The earlier run being looked at, as the Mac has it now. Nil once it is no longer the thing to show: the
    /// Mac has dropped it from its history, or a new run has begun, which goes on show as it does on the Mac.
    private static func stillOnShow(_ viewed: RunRecord?, in snapshot: RemoteFlowSnapshot) -> RunRecord? {
        guard let viewed, !snapshot.run.isRunning else { return nil }
        return snapshot.runs.first { $0.id == viewed.id }
    }

    /// Takes everything off the canvas, for another flow to be put on it.
    private func clear() {
        journey?.stop()
        journey = nil
        cardViews.values.forEach { $0.removeFromSuperview() }
        groupViews.values.forEach { $0.removeFromSuperview() }
        cardViews = [:]
        groupViews = [:]
        linkLayer.update([])
        content = CanvasContent()
        inputs = nil
        didFirstSync = false
        awaitsPlacing = false
        isFitted = false
        model.select(.none)
        model.view(nil)
        #if DEBUG
        model.didChangeWhatIsShown()
        #endif
    }

    /// Changes only the views whose card, link or group is drawn differently now.
    private func apply(_ new: CanvasContent) {
        let zoom = scrollView.zoomScale
        var created = false
        for card in new.cards {
            let view: CardView
            if let existing = cardViews[card.id], (existing is AgentCardView) == (card.kind == .agent) {
                view = existing
            } else {
                cardViews[card.id]?.removeFromSuperview()
                view = card.kind == .agent ? AgentCardView(card: card) : LogicCardView(card: card)
                let id = card.id
                view.onActivate = { [weak self] in self?.model.select(.card(id)) }
                view.onPress = { [weak self] in self?.model.onPress?($0) }
                (view as? AgentCardView)?.onExpand = { [weak self] in self?.model.expandTerminal?(id) }
                view.zoom = zoom
                document.addSubview(view)
                cardViews[card.id] = view
                if didFirstSync { view.playDrawIn() }
                created = true
            }
            let context = new.contexts[card.id] ?? CardContext()
            if !view.isCurrent(card: card, context: context) { view.update(card: card, context: context) }
            let hidden = new.folded.contains(card.id)
            if view.isHidden != hidden { view.isHidden = hidden }
        }
        if cardViews.count != new.cards.count {
            let seen = Set(new.cards.map(\.id))
            for (id, view) in cardViews where !seen.contains(id) {
                view.removeFromSuperview()
                cardViews[id] = nil
            }
        }
        linkLayer.update(new.links)
        content = new
        layoutGroups()
        didFirstSync = true
        if created {
            attachTerminals()
            if sharpness != 1 { sharpen(force: true) }
        }
    }

    /// Frames for the flow's groups. A frame's name strip grows as the canvas zooms out, which moves the frame.
    private func layoutGroups() {
        guard !content.groups.isEmpty || !groupViews.isEmpty else { return }
        let zoom = scrollView.zoomScale
        for look in content.groups {
            guard let frame = CanvasGeometry.groupFrame(of: look.group, cards: content.cards, zoom: zoom) else { continue }
            let view: GroupFrameView
            if let existing = groupViews[look.group.id] {
                view = existing
            } else {
                view = GroupFrameView(look: look)
                let id = look.group.id
                view.onActivate = { [weak self] in self?.model.select(.group(id)) }
                groupViews[look.group.id] = view
            }
            // A frame sits behind its cards. Folded, the one card sits where cards do.
            if view.superview == nil || view.look.group.isFolded != look.group.isFolded {
                if look.group.isFolded { document.addSubview(view) } else { document.insertSubview(view, aboveSubview: linkLayer) }
            }
            view.zoom = zoom
            if view.look != look || view.frame != frame { view.update(look, frame: frame) }
        }
        for (id, view) in groupViews where !content.groups.contains(where: { $0.group.id == id }) {
            view.removeFromSuperview()
            groupViews[id] = nil
        }
    }

    // MARK: Terminals

    /// The place in an agent's card where its terminal goes, by session key, which is the card's id.
    /// Nil for a key with no card here, as the orchestrator's has none.
    func terminalContainer(for key: String) -> UIView? {
        (cardViews[key] as? AgentCardView)?.terminalHolder
    }

    /// Puts each session's terminal in its card, and takes out any that has gone.
    func attachTerminals() {
        for (id, view) in cardViews {
            guard let view = view as? AgentCardView else { continue }
            view.attach(terminal: model.terminalSource?(id))
        }
        // One may have come from the full-screen view, drawn for that view's zoom.
        sharpenTerminals()
        #if DEBUG
        model.didChangeWhatIsShown()
        #endif
    }

    /// The agent card whose "open full screen" mark a tap at a canvas point is on, if any: the nearest,
    /// when two cards' marks are both within reach.
    private func expandTarget(at point: CGPoint) -> String? {
        let zoom = scrollView.zoomScale
        var nearest: (id: String, distance: CGFloat)?
        for (id, view) in cardViews {
            guard let target = (view as? AgentCardView)?.expandTarget(zoom: zoom), target.contains(point) else { continue }
            let distance = hypot(target.midX - point.x, target.midY - point.y)
            if distance < nearest?.distance ?? .greatestFiniteMagnitude { nearest = (id, distance) }
        }
        return nearest?.id
    }

    /// The button on a card that a tap at a canvas point is on, if any. Cards take no touches, so the canvas
    /// asks each for where its buttons are, a finger's width on screen whatever the zoom, and takes the nearest.
    private func pressTarget(at point: CGPoint) -> Press? {
        let zoom = scrollView.zoomScale
        var nearest: (press: Press, distance: CGFloat)?
        for (id, view) in cardViews where !content.folded.contains(id) {
            for target in view.pressTargets(zoom: zoom) where target.reach.contains(point) {
                let drawn = target.drawn
                let distance = hypot(max(drawn.minX - point.x, 0, point.x - drawn.maxX), max(drawn.minY - point.y, 0, point.y - drawn.maxY))
                if distance < nearest?.distance ?? .greatestFiniteMagnitude { nearest = (target.press, distance) }
            }
        }
        return nearest?.press
    }

    // MARK: Where the canvas is looking

    /// What floats over each edge of the canvas: the system's bars, and whatever `clearance` adds.
    private var covered: UIEdgeInsets {
        let safe = safeAreaInsets
        return UIEdgeInsets(top: safe.top + clearance.top, left: safe.left + clearance.left,
                            bottom: safe.bottom + clearance.bottom, right: safe.right + clearance.right)
    }

    /// The part of the screen nothing floats over, never smaller than a card's title.
    private var room: CGRect {
        let c = covered
        return CGRect(x: c.left, y: c.top, width: max(80, bounds.width - c.left - c.right), height: max(80, bounds.height - c.top - c.bottom))
    }

    private var middleOfRoom: CGPoint { CGPoint(x: room.midX, y: room.midY) }

    /// The canvas point under a point of this view.
    private func canvasPoint(at screen: CGPoint) -> CGPoint {
        let zoom = max(scrollView.zoomScale, 0.01), offset = scrollView.contentOffset
        return CGPoint(x: (offset.x + screen.x) / zoom - CanvasGeometry.margin, y: (offset.y + screen.y) / zoom - CanvasGeometry.margin)
    }

    /// The part of the canvas on screen, in canvas points.
    private var visible: CGRect {
        let zoom = max(scrollView.zoomScale, 0.01), origin = canvasPoint(at: .zero)
        return CGRect(origin: origin, size: CGSize(width: bounds.width / zoom, height: bounds.height / zoom))
    }

    /// Sets the zoom, and scrolls so a canvas point sits at a point of this view.
    private func place(zoom: CGFloat, point: CGPoint, at screen: CGPoint) {
        if scrollView.zoomScale != zoom { scrollView.zoomScale = zoom }
        let inset = scrollView.contentInset, size = scrollView.contentSize
        let wanted = CGPoint(x: (point.x + CanvasGeometry.margin) * zoom - screen.x, y: (point.y + CanvasGeometry.margin) * zoom - screen.y)
        scrollView.contentOffset = CGPoint(
            x: min(max(wanted.x, -inset.left), max(size.width - bounds.width + inset.right, -inset.left)),
            y: min(max(wanted.y, -inset.top), max(size.height - bounds.height + inset.bottom, -inset.top)))
        moved()
    }

    /// Run after any scroll or zoom: the paper's dots follow the canvas.
    private func moved() {
        let zoom = scrollView.zoomScale, offset = scrollView.contentOffset
        paper.show(origin: CGPoint(x: CanvasGeometry.margin * zoom - offset.x, y: CanvasGeometry.margin * zoom - offset.y), zoom: zoom)
        centre = canvasPoint(at: middleOfRoom)
    }

    private func zoomed() {
        let zoom = scrollView.zoomScale
        model.noteZoom(zoom)
        cardViews.values.forEach { $0.zoom = zoom }
        layoutGroups()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let was = laidOut
        guard was?.size != bounds.size || was?.clear != covered || awaitsPlacing else { return }
        laidOut = (bounds.size, covered)
        paper.frame = bounds
        // Half a screen of give on every side, so a flow smaller than the screen can still be put in the
        // middle of the clear part of it.
        let give = UIEdgeInsets(top: bounds.height / 2, left: bounds.width / 2, bottom: bounds.height / 2, right: bounds.width / 2)
        let kept = centre
        if scrollView.frame != bounds { scrollView.frame = bounds }
        if scrollView.contentInset != give { scrollView.contentInset = give }

        if awaitsPlacing {
            awaitsPlacing = false
            placeNewFlow()
        } else if isFitted {
            // The screen turned, or a panel came or went: what was fitted is fitted to the new room.
            zoomToFit(atMost: fitCap, animated: false)
        } else {
            place(zoom: scrollView.zoomScale, point: kept, at: middleOfRoom)
            // A screen that has changed shape shows other cards.
            sharpenTerminals()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// A flow opened for the first time starts fitted. One that was open before goes back to where it was left.
    private func placeNewFlow() {
        journey?.stop()
        journey = nil
        scrollView.minimumZoomScale = Self.minZoom
        if let saved = model.viewports[content.flowID], !saved.isFitted {
            scrollView.minimumZoomScale = min(Self.minZoom, saved.zoom)
            place(zoom: saved.zoom, point: saved.centre, at: middleOfRoom)
            zoomed()
        } else if content.cards.isEmpty {
            // An empty flow shows the canvas's own corner, just clear of what floats over it, as on the Mac.
            place(zoom: 1, point: .zero, at: CGPoint(x: room.minX + 20, y: room.minY + 16))
            zoomed()
        } else {
            // A flow of a few small cards isn't blown up to fill the screen.
            zoomToFit(atMost: 1, animated: false)
        }
        sharpen()
        sharpenTerminals()
        #if DEBUG
        DebugLaunch.arrange(self, model: model, flow: inputs?.flow)
        model.didChangeWhatIsShown()
        #endif
    }

    /// Remembers where the open flow is being looked at, for the next time it is opened.
    func saveViewport() {
        guard !content.flowID.isEmpty, laidOut != nil, !awaitsPlacing else { return }
        model.viewports[content.flowID] = .init(zoom: scrollView.zoomScale, centre: centre, isFitted: isFitted)
    }

    // MARK: Zoom

    /// Shows the whole flow. `atMost` stops a flow of a few small cards being blown up to fill the screen.
    func zoomToFit(atMost: CGFloat? = nil, animated: Bool = true) {
        guard !content.cards.isEmpty else { return }
        let box = content.cards.map(CanvasGeometry.frame(of:)).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -40)
        fit(box, atMost: atMost, animated: animated)
        isFitted = true
        fitCap = atMost
    }

    /// Zooms so one card fills the clear part of the canvas.
    func zoom(toCard id: String, animated: Bool = true) {
        guard let card = content.cards.first(where: { $0.id == id }) else { return }
        fit(CanvasGeometry.frame(of: card).insetBy(dx: -40, dy: -40), atMost: nil, animated: animated)
    }

    /// Pans so a card is in the middle of the clear part of the canvas, at the zoom it is at.
    func centre(onCard id: String, animated: Bool = true) {
        guard let card = content.cards.first(where: { $0.id == id }) else { return }
        let frame = CanvasGeometry.frame(of: card)
        isFitted = false
        travel(to: scrollView.zoomScale, point: CGPoint(x: frame.midX, y: frame.midY), animated: animated)
    }

    /// Zooms so `box` fills the part of the canvas nothing floats over. The Mac's `fit(_:atMost:)`: what
    /// floats is a fixed size on screen, so the zoom is worked out from the room it leaves.
    private func fit(_ box: CGRect, atMost: CGFloat?, animated: Bool) {
        let room = room
        let needed = min(room.width / box.width, room.height / box.height)
        // Fitting is the one zoom allowed below the usual floor: all of a wide flow matters more here than
        // its cards staying readable, and below 40% they show only a name and a state anyway.
        let floor = min(Self.minZoom, max(Self.fitFloor, needed))
        scrollView.minimumZoomScale = min(scrollView.minimumZoomScale, floor)
        let zoom = min(atMost ?? Self.maxZoom, Self.maxZoom, max(floor, needed))
        isFitted = false
        travel(to: zoom, point: CGPoint(x: box.midX, y: box.midY), animated: animated)
    }

    /// Moves the canvas until `point` is in the middle of the clear part of the screen at `zoom`. It is
    /// stepped by hand, frame by frame, so the paper, the cards' overviews and the groups' names keep up.
    private func travel(to zoom: CGFloat, point: CGPoint, animated: Bool) {
        journey?.stop()
        journey = nil
        let from = (zoom: scrollView.zoomScale, point: canvasPoint(at: middleOfRoom))
        guard animated, Theme.Motion.isAllowed, window != nil, from.zoom != zoom || from.point != point else {
            place(zoom: zoom, point: point, at: middleOfRoom)
            arrived()
            return
        }
        journey = Journey(duration: Theme.Motion.travelDuration) { [weak self] progress, isLast in
            guard let self else { return }
            // Ease in and out. The zoom moves by ratio, so it looks as even going out as coming in.
            let t = progress * progress * (3 - 2 * progress)
            self.place(zoom: from.zoom * pow(zoom / from.zoom, t),
                       point: CGPoint(x: from.point.x + (point.x - from.point.x) * t, y: from.point.y + (point.y - from.point.y) * t),
                       at: self.middleOfRoom)
            self.zoomed()
            if isLast {
                self.journey = nil
                self.arrived()
            }
        }
    }

    /// The canvas has stopped somewhere new.
    private func arrived() {
        zoomed()
        // A fit may have gone below the usual floor. Once the zoom is back above it, the floor returns.
        if scrollView.minimumZoomScale < Self.minZoom, scrollView.zoomScale >= Self.minZoom { scrollView.minimumZoomScale = Self.minZoom }
        sharpen()
        // Every time, and not only when the zoom has changed: a pan brings other cards into view.
        sharpenTerminals()
        #if DEBUG
        model.didChangeWhatIsShown()
        #endif
    }

    /// Text and lines are drawn at the screen's own fineness, then stretched by the zoom. Zoomed in, that
    /// would blur them, so once the canvas has stopped they are drawn again as finely as they are shown.
    private func sharpen(force: Bool = false) {
        let wanted = max(1, min(scrollView.zoomScale, Self.maxZoom)).rounded(.up)
        guard force || wanted != sharpness else { return }
        sharpness = wanted
        linkLayer.sharpness = wanted
        let scale = traitCollection.displayScale * wanted
        func draw(_ view: UIView) {
            // A terminal looks after its own fineness: it is also shown outside the canvas.
            if view is TerminalMount { return }
            if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
            for case let shape as CAShapeLayer in view.layer.sublayers ?? [] { shape.contentsScale = scale }
            view.subviews.forEach(draw)
        }
        cardViews.values.forEach(draw)
        groupViews.values.forEach(draw)
    }

    /// Terminals are the costly thing to draw finely, so only the ones in view are, and no finer than twice
    /// over. The rest stay at the screen's own fineness until the canvas stops with them in view.
    private func sharpenTerminals() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visible = visible
        for card in content.cards {
            guard let mount = (cardViews[card.id] as? AgentCardView)?.terminal as? TerminalMount else { continue }
            let inView = !content.folded.contains(card.id) && CanvasGeometry.frame(of: card).intersects(visible)
            mount.magnify(inView ? sharpness : 1, atMost: TerminalMount.finestAmongMany)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { document }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if journey == nil { moved() }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if journey == nil {
            moved()
            zoomed()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { tookHold() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { tookHold() }

    /// A finger has taken the canvas: it goes where the finger says from here.
    private func tookHold() {
        journey?.stop()
        journey = nil
        isFitted = false
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { arrived() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { arrived() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { arrived() }
    }

    // MARK: Taps

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: document)
        if let key = expandTarget(at: point) {
            model.expandTerminal?(key)
        } else if let press = pressTarget(at: point) {
            model.onPress?(press)
        } else {
            model.select(item(at: point))
        }
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        zoomToFit()
    }

    /// A double tap is for bare paper. On a card or a link it would only hold up the tap that selects it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: document)
        return item(at: point) == .none && expandTarget(at: point) == nil && pressTarget(at: point) == nil
    }

    /// What a tap at a canvas point is on. Something the finger is squarely on wins: a card, then a group's
    /// name, then a link, as on the Mac. Failing that, the nearest thing within reach: zoomed out, a card or
    /// a link is far smaller than a fingertip, so each is given a target at least 44 points across on screen
    /// however small it is drawn.
    func item(at point: CGPoint) -> CanvasModel.Selection {
        func distance(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
        }
        // A card folded away in a group can't be tapped. The card on top is the one added last.
        let cards = content.cards.filter { !content.folded.contains($0.id) }.map { (id: $0.id, distance: distance(CardView.frame(for: $0))) }
        let groups = groupViews.values.map { (id: $0.look.group.id, distance: distance($0.handle)) }
        let link = linkLayer.nearestLink(to: point)
        if let card = cards.last(where: { $0.distance == 0 }) { return .card(card.id) }
        if let group = groups.first(where: { $0.distance == 0 }) { return .group(group.id) }
        if let link, link.distance <= 6 { return .link(link.id) }

        let reach = Theme.Touch.target / 2 / max(scrollView.zoomScale, 0.01)
        var nearest: (item: CanvasModel.Selection, distance: CGFloat) = (.none, reach)
        for card in cards where card.distance <= nearest.distance { nearest = (.card(card.id), card.distance) }
        for group in groups where group.distance < nearest.distance { nearest = (.group(group.id), group.distance) }
        if let link, link.distance < nearest.distance { nearest = (.link(link.id), link.distance) }
        return nearest.item
    }

    // MARK: Test support

    #if DEBUG
    /// Sets the zoom about the middle of the clear part of the canvas.
    func debugSetZoom(_ zoom: CGFloat) {
        isFitted = false
        scrollView.minimumZoomScale = min(Self.minZoom, zoom)
        travel(to: zoom, point: canvasPoint(at: middleOfRoom), animated: false)
    }

    /// What the canvas is showing, read from the views themselves, for a script that can't see the screen.
    var debugState: [String: Any] {
        func rect(_ r: CGRect) -> [String: Any] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        let zoom = max(scrollView.zoomScale, 0.01)
        let cards: [[String: Any]] = content.cards.compactMap { card in
            guard let view = cardViews[card.id] else { return nil }
            // The card's own rectangle is the view's, less the gutter the dots sit in.
            let frame = CGRect(x: view.center.x - view.bounds.width / 2 + CardView.gutter, y: view.center.y - view.bounds.height / 2,
                               width: view.bounds.width - CardView.gutter * 2, height: view.bounds.height)
            var entry = rect(frame)
            entry["id"] = card.id
            entry["name"] = card.name
            entry["hidden"] = view.isHidden
            entry["selected"] = view.context.isSelected
            entry["badges"] = view.badgeTexts
            entry["text"] = (view as? LogicCardView)?.summaryText ?? NSNull()
            entry["hasTerminalPlace"] = terminalContainer(for: card.id) != nil
            // The buttons drawn on the card, with the middle of each on screen, for a test to tap. Laid out
            // first: this can be asked for after a card was given its buttons and before it has placed them.
            view.layoutIfNeeded()
            entry["buttons"] = view.buttonsShown.map { button -> [String: Any] in
                let frame = document.convert(button.drawn, to: nil)
                return ["title": button.title, "enabled": button.isEnabled, "x": frame.midX, "y": frame.midY, "width": frame.width, "height": frame.height]
            }
            if let agent = view as? AgentCardView {
                entry["hasTerminal"] = agent.terminal != nil
                // Where the card's terminal goes, on screen, to set against where the terminal is drawn.
                // Before the card is first laid out there is no such place, and no number for it.
                let place = agent.terminalFrame
                if !place.isNull, !place.isEmpty { entry["terminalPlace"] = rect(agent.terminalHolder.convert(place, to: nil)) }
                // The middle of the mark that opens the terminal full screen, on screen, for a test to tap.
                if let target = agent.expandTarget(zoom: zoom) {
                    let middle = document.convert(CGPoint(x: target.midX, y: target.midY), to: nil)
                    entry["expandAt"] = ["x": middle.x, "y": middle.y]
                }
            }
            return entry
        }
        let selected: Any = switch model.selection {
        case .none: NSNull()
        case .card(let id): ["card": id]
        case .link(let id): ["link": id]
        case .group(let id): ["group": id]
        }
        let room = room
        return [
            "flow": content.flowID,
            "cards": cards,
            "links": linkLayer.count,
            // How many times each link has fired in the run on show, and the links a message is on now.
            "passes": Dictionary(uniqueKeysWithValues: content.links.filter { $0.look.count > 0 }.map { ($0.id, $0.look.count) }),
            "live": content.links.filter(\.look.isLive).map(\.id),
            "groups": groupViews.count,
            "zoom": zoom,
            "fitted": isFitted,
            "contentSize": ["width": scrollView.contentSize.width / zoom, "height": scrollView.contentSize.height / zoom],
            "visible": rect(visible),
            // The part of the canvas nothing floats over.
            "clear": rect(CGRect(origin: canvasPoint(at: room.origin), size: CGSize(width: room.width / zoom, height: room.height / zoom))),
            "selected": selected,
        ]
    }
    #endif
}

/// Steps something from 0 to 1 over a length of time, once per frame of the screen.
private final class Journey {
    private var link: CADisplayLink?
    private let duration: TimeInterval
    private let step: (_ progress: CGFloat, _ isLast: Bool) -> Void
    private var began: CFTimeInterval?

    init(duration: TimeInterval, step: @escaping (_ progress: CGFloat, _ isLast: Bool) -> Void) {
        self.duration = duration
        self.step = step
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let start = began ?? link.timestamp
        began = start
        let progress = min(1, CGFloat((link.targetTimestamp - start) / duration))
        if progress >= 1 { stop() }
        step(progress, progress >= 1)
    }
}

/// Hosts the canvas in the SwiftUI screen. The canvas watches the flow itself, so SwiftUI only has to make it
/// and say how much of its foot is covered.
struct CanvasRepresentable: UIViewRepresentable {
    let client: RemoteClient
    /// Room at the top and the foot of the canvas that something floats over.
    var top: CGFloat = 0
    var foot: CGFloat = 0

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(client: client)
        client.canvas.view = view
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        view.clearance = UIEdgeInsets(top: top, left: 0, bottom: foot, right: 0)
    }

    static func dismantleUIView(_ view: CanvasView, coordinator: ()) {
        view.saveViewport()
    }
}
