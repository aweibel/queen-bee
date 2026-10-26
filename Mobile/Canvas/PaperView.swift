import UIKit

/// The ground behind the canvas, with its dot matrix. It stays still while the canvas scrolls over
/// it, and moves its dots to where the canvas's grid is, so it looks as if the paper scrolls and zooms too.
///
/// The Mac paints the dots onto the canvas itself. A canvas this size can't be painted on here, and
/// repainting a screen of dots on every step of a pinch would be slow. So one dot is drawn and the rest are
/// copies of it, which the graphics chip lays out.
final class PaperView: UIView {
    private let dot = CALayer()
    private let row = CAReplicatorLayer()
    private let rows = CAReplicatorLayer()
    private var shown: (step: CGFloat, size: CGFloat, across: Int, down: Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = Theme.paper
        clipsToBounds = true
        row.addSublayer(dot)
        rows.addSublayer(row)
        layer.addSublayer(rows)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PaperView, _) in
            view.dot.backgroundColor = Theme.dot.cg(in: view)
        }
        dot.backgroundColor = Theme.dot.cg(in: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Puts the dots where the canvas's grid is.
    /// - Parameter origin: where the canvas's own origin is on screen, in this view.
    /// - Parameter zoom: how big one canvas point is on screen.
    func show(origin: CGPoint, zoom: CGFloat) {
        let zoom = max(zoom, 0.01)
        // Zoomed out, dots crowd together and shrink below a pixel. Every second or fourth dot is kept,
        // drawn larger, so the matrix looks the same density on screen. The Mac's `CanvasDocumentView.draw`.
        var step = Theme.Grid.step
        while step * zoom < 14 { step *= 2 }
        let onScreen = step * zoom
        let size = max(Theme.Grid.dot, Theme.Grid.dot / zoom) * zoom
        let across = Int(bounds.width / onScreen) + 2, down = Int(bounds.height / onScreen) + 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shown?.step != onScreen || shown?.size != size || shown?.across != across || shown?.down != down {
            shown = (onScreen, size, across, down)
            dot.frame = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
            dot.cornerRadius = size / 2
            row.instanceCount = across
            row.instanceTransform = CATransform3DMakeTranslation(onScreen, 0, 0)
            rows.instanceCount = down
            rows.instanceTransform = CATransform3DMakeTranslation(0, onScreen, 0)
        }
        // The first dot on screen in each direction: the grid line at or just before this view's edge.
        func first(_ at: CGFloat) -> CGFloat {
            let phase = at.truncatingRemainder(dividingBy: onScreen)
            return phase > 0 ? phase - onScreen : phase
        }
        rows.frame.origin = CGPoint(x: first(origin.x), y: first(origin.y))
        CATransaction.commit()
    }
}
