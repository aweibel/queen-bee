import AppKit
import Observation
import QueenBeeCore
import SwiftTerm

/// The surface cards sit on: the panel's colour with a dot matrix. Flipped so a card's y grows
/// downward, as the flow file stores it.
final class CanvasDocumentView: NSView {
    /// What the add-card palette puts on the pasteboard when a row is dragged. Nothing else
    /// in the app, the terminals included, accepts it, so the drop always lands on the canvas.
    static let cardKindType = NSPasteboard.PasteboardType("dev.queenbee.card-kind")

    weak var canvas: CanvasView?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.Canvas.paper.setFill()
        dirtyRect.fill()

        // Zoomed out, dots crowd together and shrink below a pixel. Every second or fourth
        // dot is kept, drawn larger, so the matrix looks the same density on screen.
        let zoom = max(canvas?.scrollView.magnification ?? 1, 0.01)
        var step = CanvasGeometry.gridStep
        while step * zoom < 14 { step *= 2 }
        let size = max(1.6, 1.6 / zoom)
        Theme.Canvas.dot.setFill()
        var y = (dirtyRect.minY / step).rounded(.down) * step
        while y <= dirtyRect.maxY {
            var x = (dirtyRect.minX / step).rounded(.down) * step
            while x <= dirtyRect.maxX {
                NSBezierPath(ovalIn: NSRect(x: x - size / 2, y: y - size / 2, width: size, height: size)).fill()
                x += step
            }
            y += step
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let controller = canvas?.controller else { return super.keyDown(with: event) }
        // Option moves by a single point; without it a card moves a grid step.
        let step = event.modifierFlags.contains(.option) ? 1 : Double(CanvasGeometry.gridStep)
        switch event.keyCode {
        case 51, 117: controller.deleteSelection() // Delete and forward delete
        case 53: controller.select(.none) // Escape
        case 123 where !controller.selection.cardIDs.isEmpty: controller.nudgeSelection(dx: -step, dy: 0)
        case 124 where !controller.selection.cardIDs.isEmpty: controller.nudgeSelection(dx: step, dy: 0)
        case 125 where !controller.selection.cardIDs.isEmpty: controller.nudgeSelection(dx: 0, dy: step)
        case 126 where !controller.selection.cardIDs.isEmpty: controller.nudgeSelection(dx: 0, dy: -step)
        default: super.keyDown(with: event)
        }
    }

    // MARK: The Edit menu

    @objc func copy(_ sender: Any?) { canvas?.controller?.copySelection() }

    @objc func cut(_ sender: Any?) {
        canvas?.controller?.copySelection()
        canvas?.controller?.deleteSelection()
    }

    @objc func paste(_ sender: Any?) { canvas?.controller?.paste() }

    override func selectAll(_ sender: Any?) { canvas?.controller?.selectAll() }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let canvas, let controller = canvas.controller else { return nil }
        canvas.takeFocus()
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let link = canvas.link(at: point) {
            controller.select(.link(link))
            menu.addItem(menuItem("Delete Link") { [weak controller] in controller?.deleteSelection() })
            return menu
        }
        let add = NSMenuItem(title: "Add Card", action: nil, keyEquivalent: "")
        add.submenu = NSMenu()
        for kind in CardKindMenu.kinds {
            add.submenu?.addItem(menuItem(kind.label) { [weak controller] in controller?.addCard(kind, at: point) })
        }
        menu.addItem(add)
        if controller.canPaste {
            menu.addItem(menuItem("Paste") { [weak controller] in controller?.paste(at: point) })
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Select All") { [weak controller] in controller?.selectAll() })
        menu.addItem(menuItem("Tidy Up") { [weak controller] in controller?.tidy() })
        menu.addItem(menuItem("Zoom to Fit") { [weak canvas] in canvas?.zoomToFit() })
        return menu
    }

    // MARK: Cards dropped from the palette

    /// The kind of card being dragged from the palette, and the saved role when it is one:
    /// a role travels as "agent@" and its id.
    private func kind(in info: NSDraggingInfo) -> (kind: CardKind, role: AgentRole?)? {
        let board = info.draggingPasteboard
        guard let raw = board.string(forType: Self.cardKindType)
            ?? board.data(forType: Self.cardKindType).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let parts = raw.split(separator: "@", maxSplits: 1).map(String.init)
        guard let kind = parts.first.flatMap(CardKind.init(rawValue:)) else { return nil }
        let role = parts.count > 1 ? AppServices.shared.roles.first { $0.id == parts[1] } : nil
        return (kind, role)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = draggingUpdated(sender)
        if operation != [] { canvas?.beginEdgePan() }
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(Self.cardKindType) == true ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        canvas?.endEdgePan()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        canvas?.endEdgePan()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canvas?.endEdgePan()
        guard let dropped = kind(in: sender) else { return false }
        canvas?.controller?.addCard(dropped.kind, at: convert(sender.draggingLocation, from: nil), role: dropped.role)
        return true
    }
}

/// What is drawn over the cards while something is being dragged: the lines that show a card
/// is lined up with another, and the box that selects cards. It never takes a click.
final class CanvasOverlayView: NSView {
    var guides: [Snapping.Guide] = [] { didSet { if guides != oldValue { needsDisplay = true } } }
    var marquee: CGRect? { didSet { if marquee != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // A hairline on screen at any zoom.
        let hairline = 1 / max(convert(CGSize(width: 1, height: 1), to: nil).width, 0.01)
        ctx.setStrokeColor(Theme.Canvas.accent.cgColor)
        ctx.setLineWidth(hairline)
        for guide in guides {
            let pad = 12 * hairline
            if guide.isVertical {
                ctx.move(to: CGPoint(x: guide.position, y: guide.start - pad))
                ctx.addLine(to: CGPoint(x: guide.position, y: guide.end + pad))
            } else {
                ctx.move(to: CGPoint(x: guide.start - pad, y: guide.position))
                ctx.addLine(to: CGPoint(x: guide.end + pad, y: guide.position))
            }
        }
        ctx.strokePath()
        if let marquee {
            ctx.setFillColor(Theme.Canvas.accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(marquee)
            ctx.stroke(marquee)
        }
    }
}

/// The zoomable canvas of one flow. An NSScrollView with magnification holds one large
/// document view; cards are its subviews, so a card's terminal is a real view that takes
/// clicks and keys at any zoom.
final class CanvasView: NSView, NSGestureRecognizerDelegate {
    static let documentSize = CGSize(width: 14000, height: 11000)
    /// Room to pan left of and above the canvas's origin. Without it a card at the origin
    /// could never be moved out from under the palette, which floats over that corner.
    static let margin: CGFloat = 3000
    /// The height of the window's title bar, which floats over the canvas's top edge.
    static let titleBarHeight: CGFloat = 52

    let scrollView = NSScrollView()
    let document = CanvasDocumentView()
    private let linkLayer = LinkLayerView()
    /// Drawn over the cards: alignment guides and the selection box.
    private let overlay = CanvasOverlayView()
    private var marqueeStart: CGPoint?
    private var marqueeBase: Set<String> = []
    private var cardViews: [String: CardView] = [:]
    private var groupViews: [String: GroupFrameView] = [:]
    private(set) weak var controller: FlowController?
    private var scrollMonitor: Any?
    /// Watches for Space and for the mouse buttons that pan the canvas by dragging.
    private var panMonitor: Any?
    /// Space is down and the canvas has taken it: a drag with the main button pans.
    private var isSpaceHeld = false
    /// A pan by dragging is under way, with Space or with the middle button.
    private var isHandPanning = false
    private var responderObservation: NSKeyValueObservation?
    private var didInitialScroll = false
    /// False until the flow's saved cards are on screen, so only cards added later draw in.
    private var didFirstSync = false
    /// Notifications the canvas listens to while it is in a window: its own scrolling, and the window and app
    /// losing the keyboard. Taken away when it leaves the window, so switching flows doesn't pile them up.
    private var observers: [NSObjectProtocol] = []
    /// Saves where the canvas is looking a moment after it stops moving.
    private var placeSave: Task<Void, Never>?

    init(controller: FlowController) {
        self.controller = controller
        super.init(frame: .zero)

        document.canvas = self
        document.frame = CGRect(origin: .zero, size: CanvasView.documentSize)
        document.bounds.origin = CGPoint(x: -CanvasView.margin, y: -CanvasView.margin)
        // The link layer covers the whole document and shares its coordinates, so a link is
        // drawn with the same numbers its cards are placed with.
        linkLayer.frame = document.bounds
        linkLayer.bounds.origin = document.bounds.origin
        document.addSubview(linkLayer)
        overlay.frame = document.bounds
        overlay.bounds.origin = document.bounds.origin
        document.addSubview(overlay)

        document.registerForDraggedTypes([CanvasDocumentView.cardKindType])
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.minZoom
        scrollView.maxMagnification = 3
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        scrollView.drawsBackground = false
        // The canvas runs under the window's transparent title bar, so it must not push its
        // content down to make room for one.
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleBackgroundClick(_:)))
        click.delegate = self
        document.addGestureRecognizer(click)
        // A drag that starts on bare canvas draws a box, and the cards it touches are selected.
        let marquee = NSPanGestureRecognizer(target: self, action: #selector(handleMarquee(_:)))
        marquee.delegate = self
        document.addGestureRecognizer(marquee)

        scrollView.contentView.postsBoundsChangedNotifications = true

        observe()
    }

    /// As far out as a pinch, the wheel or the zoom buttons go.
    private static let minZoom: CGFloat = 0.2
    /// As far out as fitting a flow goes, so a wide one still fits whole.
    private static let fitFloor: CGFloat = 0.05
    /// Counts fits. A fit's animation may be on its way below `minZoom`, and one that ends
    /// while a later one is still moving must not end that one too.
    private var fitCount = 0
    private var fitInFlight: Int?
    /// As far out as the wheel and the zoom buttons go: 20%, or where a fit has left the canvas if that is further out.
    private var handFloor: CGFloat { min(Self.minZoom, scrollView.magnification) }

    private func publishZoom() {
        // A fit may have gone below the usual floor. Once the zoom is back above it, the floor returns.
        if fitInFlight == nil, scrollView.minMagnification < Self.minZoom, scrollView.magnification >= Self.minZoom {
            scrollView.minMagnification = Self.minZoom
        }
        // The minimap draws where the window is looking, so panning is published as well as zooming.
        if let controller, !controller.viewport.equalTo(scrollView.documentVisibleRect) {
            controller.viewport = scrollView.documentVisibleRect
            // A card's browser only streams its page while the card is in view.
            cardViews.values.forEach { ($0 as? AgentCardView)?.updateBrowserVisibility() }
            if didInitialScroll { savePlaceSoon() }
        }
        let zoom = Double(scrollView.magnification)
        if let controller, abs(controller.zoom - zoom) > 0.004 {
            controller.zoom = zoom
            document.needsDisplay = true
            cardViews.values.forEach { $0.zoom = scrollView.magnification }
            // A group's name strip grows as the canvas zooms out, which moves its frame.
            if !groupViews.isEmpty { syncGroups(controller.flow, controller) }
        }
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
        guard let controller else { return }
        let flow = controller.flow
        // Wiring warnings, plus the ones about Flow cards, which need the whole project and so are worked out once.
        let warnings = controller.warnings.merging(controller.nestingWarnings) { own, _ in own }
        linkLayer.flow = flow
        linkLayer.passes = controller.linkPasses
        linkLayer.liveLinkIDs = controller.liveLinkIDs
        if case .link(let id) = controller.selection { linkLayer.selectedLinkID = id } else { linkLayer.selectedLinkID = nil }

        // Who feeds each card and which outputs each card uses, worked out once rather than once per card.
        var senders: [String: Set<String>] = [:], usedPorts: [String: Set<String>] = [:]
        for link in flow.links {
            senders[link.to, default: []].insert(link.from)
            usedPorts[link.from, default: []].insert(link.port)
        }
        var seen = Set<String>()
        for card in flow.cards {
            seen.insert(card.id)
            let view: CardView
            if let existing = cardViews[card.id], type(of: existing) == viewClass(for: card) {
                view = existing
            } else {
                cardViews[card.id]?.removeFromSuperview()
                view = card.kind == .agent ? AgentCardView(card: card) : LogicCardView(card: card)
                view.canvas = self
                view.zoom = scrollView.magnification
                document.addSubview(view, positioned: .below, relativeTo: overlay)
                cardViews[card.id] = view
                if didFirstSync { view.playDrawIn() }
            }
            var context = CardContext()
            context.isSelected = controller.selection.cardIDs.contains(card.id)
            context.isFocused = controller.focusedCardID == card.id
            context.linkedInputs = senders[card.id] != nil
            context.linkedPorts = usedPorts[card.id] ?? []
            context.warning = warnings[card.id]
            context.inputCount = senders[card.id]?.count ?? 0
            context.result = controller.results[card.id]
            if flow.isSubflow == true, context.result == nil {
                // In a sub-flow the Start and End are its way in and its way out.
                if card.kind == .start, (card.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    context.result = "Gets the Flow card's message"
                } else if card.kind == .end, (card.saveTo ?? "").isEmpty {
                    context.result = "Goes back to the Flow card"
                }
            }
            if card.kind == .flow, context.result == nil {
                // What the card runs is another flow's name, which the card itself doesn't hold.
                let spent = controller.isRunning ? nil : controller.runUsage(forCard: card.id).flatMap { $0.isZero ? nil : $0.price }
                context.result = controller.innerFlow(of: card).map { "Runs \($0.flow.name)\n\(spent.map { "\($0) in this run" } ?? "Double-click to open it")" }
            }
            if let hold = controller.holds.first(where: { $0.cardID == card.id }) {
                context.isLive = true
                context.waiting = hold.kind == .approval ? "Waiting for you to approve"
                    : hold.kind == .flow ? "Running \(hold.command)…"
                    : hold.needsAllow ? "Waiting for you to let its command run" : "Running its command…"
            }
            context.mark = controller.marks[card.id] ?? RunMark()
            context.isRunning = controller.isRunning
            if card.kind == .agent, let agentView = view as? AgentCardView {
                let session = controller.session(forCard: card.id)
                context.sessionState = session.state
                context.isSlowToStart = session.isSlowToStart
                context.needsRestart = !controller.settingsAwaitingRestart(forCard: card.id).isEmpty
                context.isLive = session.state == .working || session.state == .needsYou
                    || (controller.isRunning && context.mark.arrivals > context.mark.passes)
                if controller.awaitingAnswer.contains(card.id) { context.waiting = "awaiting answer" }
                if let used = controller.runUsage(forCard: card.id), !used.isZero { context.cost = used.price }
                agentView.attach(terminal: session.view)
                agentView.attach(browser: controller.browserTab(forCard: card.id))
            }
            if card.kind == .start { context.isArmed = controller.isArmed(card) }
            if !view.isCurrent(card: card, context: context) { view.update(card: card, context: context) }
        }
        for (id, view) in cardViews where !seen.contains(id) {
            view.removeFromSuperview()
            cardViews[id] = nil
        }
        syncGroups(flow, controller)
        didFirstSync = true
    }

    /// Frames for the flow's groups, and the folding away of cards that are inside a folded one.
    private func syncGroups(_ flow: Flow, _ controller: FlowController) {
        let groups = flow.groups ?? []
        var folded: Set<String> = []
        let waiting = groups.isEmpty ? [] : Set(controller.cardsNeedingYou.map(\.id))
        for group in groups {
            guard let frame = GroupFrameView.frame(of: group, in: flow, zoom: scrollView.magnification) else { continue }
            let view: GroupFrameView
            if let existing = groupViews[group.id] {
                view = existing
            } else {
                view = GroupFrameView(group: group)
                view.canvas = self
                groupViews[group.id] = view
            }
            // A frame sits behind its cards. Folded, the one card sits where cards do.
            if view.superview == nil || view.group.isFolded != group.isFolded {
                document.addSubview(view, positioned: group.isFolded ? .below : .above, relativeTo: group.isFolded ? overlay : linkLayer)
            }
            if group.isFolded { folded.formUnion(group.cardIDs) }
            let members = flow.cards.filter { group.cardIDs.contains($0.id) }
            let failed = members.contains { controller.marks[$0.id]?.failed == true }
            let live = members.contains { card in
                waiting.contains(card.id) || controller.holds.contains { $0.cardID == card.id }
                    || (card.kind == .agent && [.working, .needsYou].contains(controller.sessions[card.id]?.state ?? .notStarted))
            }
            let needs = members.filter { waiting.contains($0.id) }.count
            let detail = needs > 0 ? "\(needs) need\(needs == 1 ? "s" : "") you" : live ? "working" : "\(members.count) cards"
            view.zoom = scrollView.magnification
            view.update(group: group, frame: frame, tone: failed ? .fail : live ? .live : .plain,
                        isSelected: Set(group.cardIDs) == controller.selection.cardIDs, detail: detail)
        }
        for (id, view) in groupViews where !groups.contains(where: { $0.id == id }) {
            view.removeFromSuperview()
            groupViews[id] = nil
        }
        for (id, view) in cardViews where view.isHidden != folded.contains(id) { view.isHidden = folded.contains(id) }
    }

    private func viewClass(for card: Card) -> CardView.Type {
        card.kind == .agent ? AgentCardView.self : LogicCardView.self
    }

    // MARK: Window hooks

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        endEdgePan()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        if let panMonitor { NSEvent.removeMonitor(panMonitor) }
        panMonitor = nil
        endHand()
        responderObservation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else {
            savePlace()
            return
        }
        if TestHarness.isEnabled, LaunchArguments.floats {
            window.level = .floating
            window.orderFrontRegardless()
        }

        // Scrolling over a terminal you haven't clicked into pans the canvas. Only a focused
        // terminal scrolls its own history.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Command or Control with the wheel zooms about the pointer, as drawing tools do.
            if self.zoomWithWheel(event) { return nil }
            return self.panInsteadOfScrolling(event, atWindowPoint: event.locationInWindow) ? nil : event
        }

        // Holding Space turns the pointer into a hand that drags the canvas, and so does the
        // middle mouse button. Both are for a mouse, which has no two-finger scroll.
        let panEvents: NSEvent.EventTypeMask = [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                                .otherMouseDown, .otherMouseDragged, .otherMouseUp]
        panMonitor = NSEvent.addLocalMonitorForEvents(matching: panEvents) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handPan(event) ? nil : event
        }

        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            Task { @MainActor in self?.firstResponderChanged(in: window) }
        }
        // Space let go while another window or app had the keyboard would never be seen here.
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.endHand() }
            })
        }
        // The zoom pill shows the zoom level, however it was changed: pinch, menu or button.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.publishZoom() }
        })
    }

    // MARK: Where the canvas was left

    private var placeID: String? {
        controller.map { CanvasPlaces.id(flow: $0.flow.id, project: $0.project.root) }
    }

    private func savePlaceSoon() {
        placeSave?.cancel()
        placeSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.savePlace()
        }
    }

    /// Remembers where the canvas is looking and how far it is zoomed, for the next time this flow is shown.
    func savePlace() {
        placeSave?.cancel()
        placeSave = nil
        guard didInitialScroll, let placeID else { return }
        CanvasPlaces.save(.init(origin: scrollView.documentVisibleRect.origin, zoom: scrollView.magnification), for: placeID)
    }

    /// Puts the canvas back where it was left, if it has been shown before. False for a flow seen for the first time.
    private func restorePlace() -> Bool {
        guard let placeID, let place = CanvasPlaces.place(for: placeID) else { return false }
        let zoom = min(scrollView.maxMagnification, max(Self.fitFloor, place.zoom))
        // A fit may have left it below the usual floor; publishZoom raises the floor again once it is back above.
        if zoom < scrollView.minMagnification { scrollView.minMagnification = zoom }
        scrollView.magnification = zoom
        document.scroll(place.origin)
        document.needsDisplay = true
        cardViews.values.forEach { $0.zoom = zoom }
        return true
    }

    override func layout() {
        super.layout()
        if !didInitialScroll, bounds.width > 0 {
            if !restorePlace() {
                // Start with the canvas's origin just clear of the panels floating over its left edge.
                document.scroll(CGPoint(x: -(AppServices.shared.canvasObstruction.left + 20), y: -(CanvasView.titleBarHeight + 16)))
            }
            didInitialScroll = true
        }
        // A canvas that has just appeared, or whose window changed size, hasn't scrolled, so
        // nothing else would tell the zoom control and the map where it is looking.
        publishZoom()
    }

    // MARK: Mouse and keyboard navigation

    private func isOverCanvas(_ point: NSPoint) -> Bool {
        guard let content = window?.contentView,
              let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    /// Whether the keyboard is in something that is typed into: a terminal, or a text box.
    private var isTyping: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSText { return true }
        var view = responder as? NSView
        while let v = view {
            if v is TerminalView || v is BrowserPageView { return true }
            view = v.superview
        }
        return false
    }

    /// Command or Control with the scroll wheel zooms in and out about the pointer.
    private func zoomWithWheel(_ event: NSEvent, atWindowPoint given: NSPoint? = nil) -> Bool {
        let spot = given ?? event.locationInWindow
        let wants = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        guard wants, isOverCanvas(spot) else { return false }
        // A trackpad reports fine movement, a wheel reports clicks. Each is scaled to feel alike.
        let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.005 : event.scrollingDeltaY * 0.08
        guard amount != 0 else { return true }
        let target = min(scrollView.maxMagnification, max(handFloor, scrollView.magnification * exp(amount)))
        let point = scrollView.contentView.convert(spot, from: nil)
        zoomTarget = nil
        scrollView.setMagnification(target, centeredAt: point)
        publishZoom()
        document.needsDisplay = true
        return true
    }

    /// Space-and-drag and middle-button drag. Returns whether the event was the canvas's to keep.
    private func handPan(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown where event.keyCode == 49:
            // Space typed into a terminal or a text box is a space.
            if isSpaceHeld { return true }
            guard !isTyping, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  isOverCanvas(window?.mouseLocationOutsideOfEventStream ?? .zero) else { return false }
            isSpaceHeld = true
            window?.disableCursorRects()
            NSCursor.openHand.set()
            return true
        case .keyUp where event.keyCode == 49:
            guard isSpaceHeld else { return false }
            endHand()
            return true
        case .leftMouseDown where isSpaceHeld && isOverCanvas(event.locationInWindow):
            isHandPanning = true
            NSCursor.closedHand.set()
            return true
        case .otherMouseDown where event.buttonNumber == 2 && isOverCanvas(event.locationInWindow):
            isHandPanning = true
            window?.disableCursorRects()
            NSCursor.closedHand.set()
            return true
        case .leftMouseDragged where isSpaceHeld && isHandPanning, .otherMouseDragged where isHandPanning:
            let zoom = max(scrollView.magnification, 0.01)
            let origin = scrollView.documentVisibleRect.origin
            document.scroll(CGPoint(x: origin.x - event.deltaX / zoom, y: origin.y - event.deltaY / zoom))
            return true
        case .leftMouseUp where isSpaceHeld && isHandPanning:
            isHandPanning = false
            NSCursor.openHand.set()
            return true
        case .otherMouseUp where isHandPanning:
            if isSpaceHeld {
                isHandPanning = false
                NSCursor.openHand.set()
            } else {
                endHand()
            }
            return true
        default:
            return false
        }
    }

    /// Puts the pointer back to normal after a hand pan.
    private func endHand() {
        guard isSpaceHeld || isHandPanning else { return }
        isSpaceHeld = false
        isHandPanning = false
        window?.enableCursorRects()
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
    }

    /// A scroll over a terminal or a card's browser that doesn't have the keyboard pans the canvas. Returns
    /// whether it did; when it didn't, the event goes on to whatever is under it.
    private func panInsteadOfScrolling(_ event: NSEvent, atWindowPoint point: NSPoint) -> Bool {
        guard let terminal = terminal(atWindowPoint: point), !isFocused(terminal) else { return false }
        scrollView.scrollWheel(with: event)
        return true
    }

    private func terminal(atWindowPoint point: NSPoint) -> NSView? {
        guard let content = window?.contentView else { return nil }
        // hitTest takes a point in the superview's coordinates. The content view is flipped, so
        // converting into its own coordinates would look for the terminal at the mirrored spot.
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let v = view {
            if v is TerminalView || v is BrowserPageView { return v }
            view = v.superview
        }
        return nil
    }

    private func isFocused(_ terminal: NSView) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === terminal || responder.isDescendant(of: terminal)
    }

    private func firstResponderChanged(in window: NSWindow) {
        guard let controller else { return }
        var focused: String?
        if let responder = window.firstResponder as? NSView {
            for (id, view) in cardViews where responder.isDescendant(of: view) && !(responder is CardView) {
                focused = id
            }
        }
        if controller.focusedCardID != focused { controller.focusedCardID = focused }
        // Clicking into a terminal is for typing, so it doesn't open that card's settings. It
        // does put away another card's, which would otherwise sit beside the wrong terminal.
        if let focused, controller.selection != .card(focused) { controller.select(.none) }
    }

    /// Takes the keyboard away from whichever terminal has it.
    func takeFocus() {
        window?.makeFirstResponder(document)
    }

    // MARK: Background clicks

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Only clicks on the bare canvas: a click on a card belongs to the card.
        guard let host = document.superview else { return false }
        return document.hitTest(host.convert(event.locationInWindow, from: nil)) === document
    }

    @objc private func handleBackgroundClick(_ g: NSClickGestureRecognizer) {
        takeFocus()
        if let id = linkLayer.linkID(at: g.location(in: document)) {
            controller?.select(.link(id))
        } else {
            controller?.select(.none)
        }
    }

    func link(at point: CGPoint) -> String? { linkLayer.linkID(at: point) }

    @objc private func handleMarquee(_ g: NSPanGestureRecognizer) {
        guard let controller else { return }
        let now = g.location(in: document)
        switch g.state {
        case .began:
            takeFocus()
            // The gesture begins a few points into the drag: go back to where the button went down.
            let t = g.translation(in: document)
            marqueeStart = CGPoint(x: now.x - t.x, y: now.y - t.y)
            marqueeBase = NSEvent.modifierFlags.contains(.shift) ? controller.selection.cardIDs : []
            beginEdgePan { [weak self] in
                guard let self else { return }
                self.stretchMarquee(to: self.pointer)
            }
            fallthrough
        case .changed:
            stretchMarquee(to: now)
        default:
            endEdgePan()
            marqueeStart = nil
            overlay.marquee = nil
        }
    }

    private func stretchMarquee(to now: CGPoint) {
        guard let controller, let start = marqueeStart else { return }
        let box = CGRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
        overlay.marquee = box
        // Cards folded away in a group can't be seen, so a box drawn over where they were doesn't take them.
        let inside = controller.flow.cards.filter { cardViews[$0.id]?.isHidden != true && CanvasGeometry.frame(of: $0).intersects(box) }.map(\.id)
        controller.select(.of(marqueeBase.union(inside)))
    }

    // MARK: Edge panning

    /// How near the canvas's edge, in points on screen, a drag starts to pan it.
    private static let edgePanZone: CGFloat = 40
    /// How fast a drag pans the canvas, in points on screen a second: just inside the zone,
    /// and pushed to the edge or past it.
    private static let edgePanSpeeds: (slow: CGFloat, fast: CGFloat) = (120, 1400)
    private var edgePanTimer: Timer?
    private var edgePanMoved: (() -> Void)?
    /// How deep in each edge's zone the drag has to get before that edge pans. A drag that
    /// starts beside an edge, as a card's title bar often is, pans only when pushed further.
    private var edgePanSlack: [CGFloat] = []
    private var edgePanLast: TimeInterval = 0

    /// Where the pointer is on the canvas right now, whether or not it has moved.
    var pointer: CGPoint {
        document.convert(testPointer ?? window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
    }

    /// Where a check says the pointer is, in the window, in place of the real one.
    private var testPointer: NSPoint?

    /// From now until `endEdgePan`, holding the pointer at the canvas's edge pans the canvas
    /// that way. `moved` runs after each step, for the drag to catch up with the canvas that
    /// has slid under a pointer that may be standing still.
    func beginEdgePan(moved: @escaping () -> Void = {}) {
        endEdgePan()
        edgePanMoved = moved
        edgePanSlack = edgeDepths().map { min(max($0, 0), Self.edgePanZone) }
        edgePanLast = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.edgePanStep() }
        }
        // Common modes, so it also fires while a card is dragged in from the palette.
        RunLoop.main.add(timer, forMode: .common)
        edgePanTimer = timer
    }

    func endEdgePan() {
        edgePanTimer?.invalidate()
        edgePanTimer = nil
        edgePanMoved = nil
    }

    /// How far into the zone along each edge the pointer is, in points on screen: the left
    /// edge, the right, the top, the bottom. Past the zone's width it is outside the canvas.
    private func edgeDepths() -> [CGFloat] {
        let visible = scrollView.documentVisibleRect, zoom = scrollView.magnification, at = pointer
        return [at.x - visible.minX, visible.maxX - at.x, at.y - visible.minY, visible.maxY - at.y]
            .map { Self.edgePanZone - $0 * zoom }
    }

    private func edgePanStep() {
        guard edgePanTimer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = CGFloat(min(now - edgePanLast, 0.1))
        edgePanLast = now
        let zoom = max(scrollView.magnification, 0.01)
        var steps = edgeDepths()
        for (edge, depth) in steps.enumerated() {
            // Pulling back from an edge gives up the allowance the drag started with there.
            edgePanSlack[edge] = min(edgePanSlack[edge], max(depth, 0))
            let slack = edgePanSlack[edge]
            let push = min(max(depth - slack, 0) / max(Self.edgePanZone - slack, 1), 1)
            let speed = push > 0 ? Self.edgePanSpeeds.slow + push * push * (Self.edgePanSpeeds.fast - Self.edgePanSpeeds.slow) : 0
            // The same speed on screen at any zoom.
            steps[edge] = speed * elapsed / zoom
        }
        let visible = scrollView.documentVisibleRect, limits = document.bounds
        let wanted = CGPoint(
            x: min(max(visible.minX + steps[1] - steps[0], limits.minX), max(limits.maxX - visible.width, limits.minX)),
            y: min(max(visible.minY + steps[3] - steps[2], limits.minY), max(limits.maxY - visible.height, limits.minY)))
        guard wanted != visible.origin else { return }
        document.scroll(wanted)
        if scrollView.documentVisibleRect.origin != visible.origin { edgePanMoved?() }
    }

    // MARK: Dragging cards

    /// Moves the cards a drag carries to their origins plus `translation`, settled against the
    /// other cards and the grid by where the card under the pointer lands. Option turns that off.
    func drag(_ origins: [String: CGPoint], primary: String, by translation: CGPoint) {
        guard let controller, let card = controller.flow.card(primary), let start = origins[primary] else { return }
        var offset = CGSize(width: translation.x, height: translation.y)
        if NSEvent.modifierFlags.contains(.option) {
            overlay.guides = []
        } else {
            let moving = CGRect(x: start.x + translation.x, y: start.y + translation.y, width: card.width, height: card.height)
            let others = controller.flow.cards.filter { origins[$0.id] == nil && cardViews[$0.id]?.isHidden != true }.map(CanvasGeometry.frame(of:))
            // Six points on screen, whatever the zoom.
            let reach = 6 / max(scrollView.magnification, 0.01)
            let settled = Snapping.snap(moving, to: others, grid: CanvasGeometry.gridStep, tolerance: reach)
            offset = CGSize(width: settled.origin.x - start.x, height: settled.origin.y - start.y)
            overlay.guides = settled.guides
        }
        controller.moveCards(from: origins, by: offset)
    }

    func clearGuides() {
        overlay.guides = []
    }

    // MARK: Linking

    /// A link is being dragged out of a port. The card under the pointer shows whether the
    /// link would be taken there.
    func showPendingLink(from cardID: String, port: String, start: CGPoint, to point: CGPoint) {
        guard let flow = controller?.flow, let source = flow.card(cardID) else { return }
        let target = card(at: point).flatMap { $0.id == cardID ? nil : $0 }
        let accepts = target.map { flow.linkProblem(from: cardID, port: port, to: $0.id) == nil } ?? false
        for (id, view) in cardViews {
            view.linkDrop = id == target?.id ? (accepts ? .accepts : .refuses) : .none
        }
        // The preview takes the route the link will have. Over a card that would take the
        // link it lands on that card's input; anywhere else it follows the pointer.
        let end = accepts ? target.map(CanvasGeometry.inputPoint(of:)) ?? point : point
        let landing = accepts ? target.map(CanvasGeometry.frame(of:)) ?? CGRect(origin: point, size: .zero) : CGRect(origin: point, size: .zero)
        linkLayer.pending = LinkRouter.route(from: start, to: end, source: CanvasGeometry.frame(of: source), target: landing)
    }

    func clearPendingLink() {
        linkLayer.pending = nil
        cardViews.values.forEach { $0.linkDrop = .none }
    }

    private func card(at point: CGPoint) -> Card? {
        // A card folded away in a group can't be dropped on.
        controller?.flow.cards.last { cardViews[$0.id]?.isHidden != true && CanvasGeometry.frame(of: $0).insetBy(dx: -CardView.gutter, dy: 0).contains(point) }
    }

    func finishLink(from cardID: String, port: String, at point: CGPoint) {
        guard let controller, let target = card(at: point), target.id != cardID else { return }
        controller.link(from: cardID, port: port, to: target.id)
    }

    // MARK: Test support

    #if DEBUG

    /// A click at a point in a card's browser half and then some typing, sent as the events a mouse and
    /// keyboard would send.
    func testBrowserInput(cardID: String, at point: CGPoint?, typing text: String) -> Bool {
        guard let page = (cardViews[cardID] as? AgentCardView)?.browserPane?.page, let window else { return false }
        let spot = page.convert(point ?? .zero, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] where point != nil {
            guard let event = NSEvent.mouseEvent(with: type, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            if type == .leftMouseDown { page.mouseDown(with: event) } else { page.mouseUp(with: event) }
        }
        for character in text {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: String(character),
                                                   charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0) else { return false }
                if type == .keyDown { page.keyDown(with: event) } else { page.keyUp(with: event) }
            }
        }
        return window.firstResponder === page
    }

    func testFocus(cardID: String?) {
        if let cardID, let terminal = controller?.sessions[cardID]?.view {
            window?.makeFirstResponder(terminal)
        } else {
            takeFocus()
        }
    }

    /// Drags a link out of a card to an edge of the canvas and holds it there, as the canvas
    /// pans, until the pointer is over the card it is meant for. Then lets go.
    func testEdgeLink(from cardID: String, port: String, to targetID: String, edge: String) async {
        guard let source = controller?.flow.card(cardID) else { return }
        let start = CanvasGeometry.outputPoint(of: source, port: port)
        testPointer = document.convert(start, to: nil)
        beginEdgePan { [weak self] in
            guard let self else { return }
            self.showPendingLink(from: cardID, port: port, start: start, to: self.pointer)
        }
        // Five points inside the edge, level with the port.
        let visible = scrollView.documentVisibleRect, inset = 5 / max(scrollView.magnification, 0.01)
        let held: CGPoint = switch edge {
        case "left": CGPoint(x: visible.minX + inset, y: start.y)
        case "top": CGPoint(x: start.x, y: visible.minY + inset)
        case "bottom": CGPoint(x: start.x, y: visible.maxY - inset)
        default: CGPoint(x: visible.maxX - inset, y: start.y)
        }
        testPointer = document.convert(held, to: nil)
        for _ in 0..<200 where card(at: pointer)?.id != targetID {
            try? await Task.sleep(for: .milliseconds(50))
        }
        endEdgePan()
        clearPendingLink()
        finishLink(from: cardID, port: port, at: pointer)
        testPointer = nil
    }

    func testSetMagnification(_ value: Double) {
        scrollView.setMagnification(CGFloat(value), centeredAt: inClip(visibleCenter))
        document.needsDisplay = true
    }

    var testViewState: JSONValue {
        let r = scrollView.documentVisibleRect
        let covered = AppServices.shared.canvasObstruction, zoom = scrollView.magnification
        return ["magnification": .number(Double(zoom)), "x": .number(Double(r.minX)), "y": .number(Double(r.minY)),
                "width": .number(Double(r.width)), "height": .number(Double(r.height)),
                // The part of the canvas the floating panels leave in view, left to right.
                "clearFrom": .number(Double(r.minX + covered.left / zoom)), "clearTo": .number(Double(r.maxX - covered.right / zoom))]
    }

    /// Scrolls the wheel over a card's terminal, or over bare canvas. "system" hands a real
    /// event to this process, so it travels the whole road: the event queue, the monitor,
    /// the view under the pointer. "direct" skips the queue and gives the event to the same
    /// decision the monitor makes, for when the system won't deliver to a window that is
    /// behind others.
    func testScroll(cardID: String?, dy: Double, mode: String, withCommand: Bool = false) -> String? {
        guard let window, let controller else { return nil }
        let target: CGPoint
        if let cardID, let card = controller.flow.card(cardID) {
            target = CGPoint(x: card.x + card.width / 2, y: card.y + card.height / 2)
        } else {
            // A spot on the visible canvas that no card covers.
            let r = scrollView.documentVisibleRect
            let frames = controller.flow.cards.map { CanvasGeometry.frame(of: $0).insetBy(dx: -20, dy: -20) }
            // Away from the corners, where the palette, zoom control and status line float.
            var spot = CGPoint(x: r.midX, y: r.maxY - 90 / max(scrollView.magnification, 0.01))
            var tries = 0
            while tries < 40, frames.contains(where: { $0.contains(spot) }) {
                spot.x -= 40
                tries += 1
            }
            target = spot
        }
        let inWindow = document.convert(target, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        guard let primary = NSScreen.screens.first,
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return nil }
        cg.location = CGPoint(x: onScreen.x, y: primary.frame.height - onScreen.y)
        // Set either way: left alone, the event takes on whatever keys the person at the Mac is holding.
        cg.flags = withCommand ? .maskCommand : []
        if mode == "system" {
            cg.postToPid(getpid())
            return "system"
        }
        guard let event = NSEvent(cgEvent: cg) else { return nil }
        if zoomWithWheel(event, atWindowPoint: inWindow) { return "zoom" }
        if !panInsteadOfScrolling(event, atWindowPoint: inWindow) {
            let under = window.contentView.flatMap { $0.hitTest($0.superview?.convert(inWindow, from: nil) ?? inWindow) }
            (under ?? scrollView).scrollWheel(with: event)
        }
        return "direct"
    }

    #endif

    // MARK: Zoom

    // The scroll view's zoom calls take the clip view's coordinates. Those differ from the
    // canvas's own because the canvas's origin is set in from the document's corner.
    private func inClip(_ point: CGPoint) -> CGPoint { scrollView.contentView.convert(point, from: document) }
    private func inClip(_ rect: CGRect) -> CGRect { scrollView.contentView.convert(rect, from: document) }

    /// The middle of what is on screen, in canvas points: where a new card goes.
    var visibleCenter: CGPoint {
        let r = scrollView.documentVisibleRect
        // The middle of what the floating panels leave uncovered, not of the whole window.
        let covered = AppServices.shared.canvasObstruction
        let zoom = max(scrollView.magnification, 0.01)
        return CGPoint(x: r.midX + (covered.left - covered.right) / 2 / zoom, y: r.midY)
    }

    /// Pans so `point` is in the middle of what the floating panels leave uncovered.
    func center(on point: CGPoint) {
        let visible = scrollView.documentVisibleRect
        let middle = visibleCenter
        document.scroll(CGPoint(x: visible.minX + point.x - middle.x, y: visible.minY + point.y - middle.y))
    }

    func zoom(by factor: CGFloat) {
        // From where the zoom is headed, so quick presses add up instead of restarting.
        let from = zoomTarget ?? scrollView.magnification
        travel(to: min(scrollView.maxMagnification, max(handFloor, from * factor)))
    }

    func zoomToActualSize() {
        travel(to: 1)
    }

    /// Where an animated zoom is headed, while it is under way.
    private var zoomTarget: CGFloat?

    private func travel(to magnification: CGFloat) {
        let centre = inClip(visibleCenter)
        zoomTarget = magnification
        Theme.Motion.travel {
            scrollView.animator().setMagnification(magnification, centeredAt: centre)
        } then: { [weak self] in
            Task { @MainActor in self?.travelEnded(at: magnification) }
        }
    }

    private func travelEnded(at magnification: CGFloat) {
        if zoomTarget == magnification { zoomTarget = nil }
        publishZoom()
        document.needsDisplay = true
    }

    /// Shows the whole flow. `atMost` stops a flow of a few small cards being blown up to fill the window.
    func zoomToFit(atMost: CGFloat? = nil) {
        guard let cards = controller?.flow.cards, !cards.isEmpty else { return }
        let box = cards.map(CanvasGeometry.frame(of:)).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -40, dy: -40)
        fit(box, atMost: atMost)
    }

    /// Zooms so `box` fills the part of the canvas the floating panels leave uncovered.
    /// The panels are a fixed size on screen, so the zoom is worked out from the room they
    /// leave, and the rectangle shown is `box` plus what they cover at that zoom.
    private func fit(_ box: CGRect, atMost: CGFloat? = nil) {
        let covered = AppServices.shared.canvasObstruction
        // The see-through title bar and its buttons sit over the canvas's top; the status
        // line and zoom control over its foot.
        let top = CanvasView.titleBarHeight, foot: CGFloat = 50
        let screen = scrollView.contentView.frame.size
        let room = CGSize(width: max(80, screen.width - covered.left - covered.right), height: max(80, screen.height - top - foot))
        let needed = min(room.width / box.width, room.height / box.height)
        // Fitting is the one zoom allowed below the usual floor: all of a wide flow matters more
        // here than its cards staying readable, and below 40% they show only a name and a state anyway.
        let floor = min(Self.minZoom, max(Self.fitFloor, needed))
        // Only ever lowered here. Raised before the animation, it would snap a canvas that is below it.
        scrollView.minMagnification = min(scrollView.minMagnification, floor)
        fitCount += 1
        let thisFit = fitCount
        fitInFlight = thisFit
        let zoom = min(atMost ?? scrollView.maxMagnification, scrollView.maxMagnification, max(floor, needed))
        // Held below a full fit, the box is shown in the middle of the room with space round it.
        let shown = CGSize(width: max(box.width, room.width / zoom), height: max(box.height, room.height / zoom))
        let centred = CGRect(x: box.midX - shown.width / 2, y: box.midY - shown.height / 2, width: shown.width, height: shown.height)
        let wanted = CGRect(x: centred.minX - covered.left / zoom, y: centred.minY - top / zoom,
                            width: centred.width + (covered.left + covered.right) / zoom,
                            height: centred.height + (top + foot) / zoom)
        zoomTarget = nil
        Theme.Motion.travel {
            scrollView.animator().magnify(toFit: inClip(wanted))
        } then: { [weak self] in
            Task { @MainActor in
                guard let self, self.fitInFlight == thisFit else { return }
                self.fitInFlight = nil
                self.publishZoom()
                self.document.needsDisplay = true
            }
        }
    }

    func zoom(toCard id: String) {
        guard let card = controller?.flow.card(id) else { return }
        fit(CanvasGeometry.frame(of: card).insetBy(dx: -40, dy: -40))
    }
}
