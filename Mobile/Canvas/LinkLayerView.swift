import QueenBeeCore
import QueenBeeDesign
import UIKit

/// Draws every link as a right-angled route under the cards, as the Mac's `LinkLayerView` does, and the
/// link that is being dragged out of a card. It never takes a touch: the canvas asks it which link a point is on.
///
/// Links at rest are drawn in ink. A link the run has travelled is green and carries its pass count. A link
/// a message is travelling right now gets orange dashes that march toward the card it is headed for.
///
/// The Mac paints all of them in one pass. Here each link has its own layers, so a change to one link
/// touches only that link, and nothing has to hold a picture the size of the whole canvas.
final class LinkLayerView: UIView {
    /// One link's layers: its line, the dashes that march while it is live, its arrowhead and its count.
    private final class Strand {
        var look: LinkLook
        let line = CAShapeLayer()
        let marching = CAShapeLayer()
        let arrow = CAShapeLayer()
        var plate: UILabel?
        var path: CGPath

        init(look: LinkLook) {
            self.look = look
            path = LinkRouter.path(through: look.points)
            for layer in [line, marching] {
                layer.fillColor = nil
                layer.lineCap = .butt
                layer.lineJoin = .round
            }
            marching.lineWidth = 2
        }
    }

    private var strands: [String: Strand] = [:]
    private var order: [String] = []
    /// What VoiceOver is given for each link, since a line on a layer is nothing it can find by itself.
    private var spoken: [String: LinkElement] = [:]
    /// Selects a link, when VoiceOver's double tap lands on it.
    var onActivate: ((_ id: String) -> Void)?
    /// The flow is being edited from here, so VoiceOver can delete a link. Set before `update`.
    var isEditing = false
    var onEdit: ((EditAction) -> Void)?
    /// A link that is being dragged out of a card and hasn't landed: the route it would take. The Mac's
    /// dashes, in the colour of what is selected.
    var pending: [CGPoint]? { didSet { if pending != oldValue { drawPending() } } }
    private let pendingLine = CAShapeLayer()
    /// How finely the layers are drawn, which the canvas raises when it is zoomed in so lines stay sharp.
    var sharpness: CGFloat = 1 { didSet { if sharpness != oldValue { strands.values.forEach(sharpen) } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pendingLine.fillColor = nil
        pendingLine.lineWidth = Theme.Stroke.link
        pendingLine.lineDashPattern = [5, 4]
        pendingLine.lineJoin = .round
        // Over every link, whenever those are added.
        pendingLine.zPosition = 1
        pendingLine.isHidden = true
        layer.addSublayer(pendingLine)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: LinkLayerView, _) in
            view.strands.values.forEach { view.restyle($0) }
            view.drawPending()
        }
        // The dashes stop when the app leaves the screen, and nothing restarts them by itself. Asked for by
        // name, and not with a block: this way the asking ends with the view, and an iPhone makes a new canvas
        // every time a flow is opened.
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func becameActive() {
        strands.values.forEach(march)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var count: Int { order.count }

    private func drawPending() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pendingLine.isHidden = pending == nil
        pendingLine.path = pending.map { LinkRouter.path(through: $0) }
        pendingLine.strokeColor = Theme.select.cg(in: self)
        pendingLine.contentsScale = traitCollection.displayScale * sharpness
        CATransaction.commit()
    }

    /// Brings the layers in line with the links. A link whose look hasn't changed is left alone.
    func update(_ links: [(id: String, look: LinkLook)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let wanted = Set(links.map(\.id))
        for (id, strand) in strands where !wanted.contains(id) {
            [strand.line, strand.marching, strand.arrow].forEach { $0.removeFromSuperlayer() }
            strand.plate?.removeFromSuperview()
            strands[id] = nil
        }
        for (id, look) in links {
            if let strand = strands[id] {
                guard strand.look != look else { continue }
                let rerouted = strand.look.points != look.points
                strand.look = look
                if rerouted { strand.path = LinkRouter.path(through: look.points) }
                apply(strand, rerouted: rerouted)
            } else {
                let strand = Strand(look: look)
                strands[id] = strand
                [strand.line, strand.marching, strand.arrow].forEach(layer.addSublayer)
                sharpen(strand)
                apply(strand, rerouted: true)
            }
        }
        order = links.map(\.id)
        CATransaction.commit()
        speak(links)
    }

    /// One element for each link, kept from one update to the next so VoiceOver doesn't lose its place.
    private func speak(_ links: [(id: String, look: LinkLook)]) {
        var kept: [String: LinkElement] = [:]
        for (id, look) in links {
            let element = spoken[id] ?? LinkElement(accessibilityContainer: self)
            element.activate = { [weak self] in self?.onActivate?(id) }
            element.accessibilityLabel = look.spoken
            element.accessibilityValue = look.isLive ? "A message is going along it now"
                : look.count == 1 ? "Carried 1 message in the run on show" : look.count > 1 ? "Carried \(look.count) messages in the run on show" : nil
            element.accessibilityTraits = look.isSelected ? [.button, .selected] : .button
            element.accessibilityHint = "Shows what it carried."
            element.accessibilityCustomActions = !isEditing ? nil : [UIAccessibilityCustomAction(name: "Delete Link") { [weak self] _ in
                self?.onEdit?(.delete(cards: [], links: [id]))
                return self?.onEdit != nil
            }]
            // Room for a finger around a route that runs dead straight.
            element.accessibilityFrameInContainerSpace = (strands[id]?.path.boundingBoxOfPath ?? .zero).insetBy(dx: -12, dy: -12)
            kept[id] = element
        }
        spoken = kept
    }

    #if DEBUG
    /// What VoiceOver can do on each link, in the links' order, for a test to read.
    var debugActions: [[String]] { order.map { (spoken[$0]?.accessibilityCustomActions ?? []).map(\.name) } }
    #endif

    override var isAccessibilityElement: Bool { get { false } set {} }
    override var accessibilityElements: [Any]? {
        get { order.compactMap { spoken[$0] } }
        set {}
    }

    private func apply(_ strand: Strand, rerouted: Bool) {
        let look = strand.look
        if rerouted {
            strand.line.path = strand.path
            strand.marching.path = strand.path
            // A small triangle pointing into the target's input dot.
            if let tip = look.points.last {
                let x = tip.x - CanvasGeometry.portRadius - 1
                let head = CGMutablePath()
                head.move(to: CGPoint(x: x, y: tip.y))
                head.addLine(to: CGPoint(x: x - 8, y: tip.y - 4.5))
                head.addLine(to: CGPoint(x: x - 8, y: tip.y + 4.5))
                head.closeSubpath()
                strand.arrow.path = head
            }
        }
        // The marching layer draws a live link's line. Selected, the line is drawn as well.
        strand.line.isHidden = look.isLive && !look.isSelected
        strand.line.lineWidth = look.isSelected ? Theme.Stroke.selected : Theme.Stroke.link
        strand.marching.isHidden = !look.isLive
        restyle(strand)
        march(strand)

        // A pass count on a small green plate, so it reads against the line under it.
        if look.count > 0 {
            let plate = strand.plate ?? {
                let label = UILabel()
                label.font = Theme.mono(Theme.Size.caption, .medium)
                label.textColor = Theme.passInk
                label.backgroundColor = Theme.passTint
                label.textAlignment = .center
                label.layer.cornerRadius = 8
                label.layer.masksToBounds = true
                label.contentScaleFactor = traitCollection.displayScale * sharpness
                addSubview(label)
                strand.plate = label
                return label
            }()
            plate.text = "\(look.count)"
            let size = plate.intrinsicContentSize, point = LinkRouter.labelPoint(of: look.points)
            plate.frame = CGRect(x: point.x - size.width / 2 - 4, y: point.y - size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
        } else {
            strand.plate?.removeFromSuperview()
            strand.plate = nil
        }
    }

    private func restyle(_ strand: Strand) {
        let look = strand.look
        let color = (look.isSelected ? Theme.select : look.isLive ? Theme.live : look.count > 0 ? Theme.passInk : Palette.textFaint.platform).cg(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strand.line.strokeColor = color
        strand.arrow.fillColor = color
        strand.marching.strokeColor = Theme.live.cg(in: self)
        CATransaction.commit()
    }

    private func march(_ strand: Strand) {
        let key = "march"
        if !strand.look.isLive || !Theme.Motion.isAllowed {
            strand.marching.removeAnimation(forKey: key)
            // With motion off, a live link is a solid orange line.
            strand.marching.lineDashPattern = Theme.Motion.isAllowed ? [6, 6] : nil
        } else if strand.marching.animation(forKey: key) == nil {
            strand.marching.lineDashPattern = [6, 6]
            let march = CABasicAnimation(keyPath: "lineDashPhase")
            march.fromValue = 0
            march.toValue = -12
            march.duration = Theme.Motion.march
            march.repeatCount = .infinity
            strand.marching.add(march, forKey: key)
        }
    }

    private func sharpen(_ strand: Strand) {
        let scale = traitCollection.displayScale * sharpness
        [strand.line, strand.marching, strand.arrow].forEach { $0.contentsScale = scale }
        strand.plate?.contentScaleFactor = scale
    }

    /// The link whose route passes nearest `point`, and how far off it is. Of two as near, the one drawn last.
    func nearestLink(to point: CGPoint) -> (id: String, distance: CGFloat)? {
        var best: (id: String, distance: CGFloat)?
        for id in order {
            guard let points = strands[id]?.look.points, points.count > 1 else { continue }
            for (a, b) in zip(points, points.dropFirst()) {
                // How far the point is from this straight run of the route.
                let run = CGPoint(x: b.x - a.x, y: b.y - a.y), length = run.x * run.x + run.y * run.y
                let along = length > 0 ? min(max(((point.x - a.x) * run.x + (point.y - a.y) * run.y) / length, 0), 1) : 0
                let distance = hypot(point.x - (a.x + run.x * along), point.y - (a.y + run.y * along))
                if distance <= best?.distance ?? .infinity { best = (id, distance) }
            }
        }
        return best
    }
}

/// One link, as VoiceOver finds it.
private final class LinkElement: UIAccessibilityElement {
    var activate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        activate?()
        return activate != nil
    }
}
