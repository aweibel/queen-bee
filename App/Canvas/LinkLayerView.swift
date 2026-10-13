import AppKit
import QueenBeeCore

/// Draws every link as a right-angled route under the cards. It never takes a click itself,
/// so it can't block a card or a gesture: the canvas asks it which link a point is on.
///
/// Links at rest are drawn in ink. A link the run has travelled is green and carries its
/// pass count. A link a message is travelling right now gets orange dashes that march
/// toward the card it is headed for.
final class LinkLayerView: NSView {
    var flow: Flow? { didSet { refresh() } }
    var selectedLinkID: String? { didSet { needsDisplay = true } }
    /// How many times each link has fired in the run on show.
    var passes: [String: Int] = [:] { didSet { needsDisplay = true } }
    /// Links a message is travelling now.
    var liveLinkIDs: Set<String> = [] { didSet { if liveLinkIDs != oldValue { refresh() } } }
    /// The route of a link being dragged out of a port, not made yet.
    var pending: [CGPoint]? { didSet { needsDisplay = true } }

    private let marching = CAShapeLayer()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        marching.fillColor = nil
        marching.lineWidth = 2
        marching.lineCap = .butt
        marching.lineDashPattern = [6, 6]
        layer?.addSublayer(marching)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func path(of link: Link) -> CGPath? {
        guard let flow, let points = CanvasGeometry.route(of: link, in: flow) else { return nil }
        return LinkRouter.path(through: points)
    }

    /// Rebuilds the marching layer and asks for a redraw of the rest.
    private func refresh() {
        needsDisplay = true
        let live = CGMutablePath()
        for link in flow?.links ?? [] where liveLinkIDs.contains(link.id) {
            if let path = path(of: link) { live.addPath(path) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer is only as large as the links it draws, and keeps the view's own coordinates. One the size
        // of the whole canvas is too large to be drawn at all, and the live links went missing.
        let box = live.isEmpty ? .zero : live.boundingBoxOfPath.insetBy(dx: -4, dy: -4)
        marching.anchorPoint = .zero
        marching.bounds = box
        marching.position = box.origin
        marching.path = live.isEmpty ? nil : live
        marching.strokeColor = Theme.live.cg(in: effectiveAppearance)
        CATransaction.commit()

        let key = "march"
        if live.isEmpty || !Theme.Motion.isAllowed {
            marching.removeAnimation(forKey: key)
            // With motion off, a live link is a solid orange line.
            marching.lineDashPattern = Theme.Motion.isAllowed ? [6, 6] : nil
        } else if marching.animation(forKey: key) == nil {
            let march = CABasicAnimation(keyPath: "lineDashPhase")
            march.fromValue = 0
            march.toValue = -12
            march.duration = Theme.Motion.march
            march.repeatCount = .infinity
            marching.add(march, forKey: key)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.round)
        for link in flow?.links ?? [] {
            guard let flow, let points = CanvasGeometry.route(of: link, in: flow) else { continue }
            let selected = link.id == selectedLinkID
            let live = liveLinkIDs.contains(link.id)
            let count = passes[link.id] ?? 0
            let color = selected ? Theme.select : live ? Theme.live : count > 0 ? Theme.passInk : Theme.ink
            // The marching layer draws a live link's line; here it only gets its arrowhead.
            if !live || selected {
                ctx.addPath(LinkRouter.path(through: points))
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(selected ? Theme.Stroke.selected : Theme.Stroke.link)
                ctx.strokePath()
            }
            if let tip = points.last { arrowhead(at: tip, in: ctx, color: color) }
            if count > 0 { label("\(count)", at: LinkRouter.labelPoint(of: points)) }
        }
        if let pending {
            ctx.saveGState()
            ctx.addPath(LinkRouter.path(through: pending))
            ctx.setStrokeColor(Theme.select.cgColor)
            ctx.setLineWidth(Theme.Stroke.link)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// A small triangle pointing into the target's input dot.
    private func arrowhead(at tip: CGPoint, in ctx: CGContext, color: NSColor) {
        let x = tip.x - CanvasGeometry.portRadius - 1
        ctx.move(to: CGPoint(x: x, y: tip.y))
        ctx.addLine(to: CGPoint(x: x - 8, y: tip.y - 4.5))
        ctx.addLine(to: CGPoint(x: x - 8, y: tip.y + 4.5))
        ctx.closePath()
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    /// A pass count on a small green plate, so it reads against the line under it.
    private func label(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.mono(Theme.Size.caption, .medium), .foregroundColor: Theme.passInk]
        let size = (text as NSString).size(withAttributes: attributes)
        let plate = CGRect(x: point.x - size.width / 2 - 4, y: point.y - size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
        Theme.passTint.setFill()
        NSBezierPath(roundedRect: plate, xRadius: Theme.Radius.badge, yRadius: Theme.Radius.badge).fill()
        (text as NSString).draw(at: CGPoint(x: plate.minX + 4, y: plate.minY + 1), withAttributes: attributes)
    }

    /// The link whose route passes within a few points of `point`.
    func linkID(at point: CGPoint) -> String? {
        for link in (flow?.links ?? []).reversed() {
            guard let path = path(of: link) else { continue }
            let band = path.copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 1)
            if band.contains(point) { return link.id }
        }
        return nil
    }
}
