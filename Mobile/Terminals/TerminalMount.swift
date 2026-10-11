import SwiftTerm
import UIKit

/// Holds one session's terminal and shows it at whatever size the mount is given. The terminal itself is
/// always exactly as many columns and rows as the Mac's, in the Mac's type at the Mac's size, and is
/// stretched or shrunk as a picture to fit. So a line breaks where it breaks on the Mac, whatever the size
/// of the space here.
///
/// There is one mount for each session. A card, the panel beside the canvas and the full-screen view each
/// take it in turn. Two terminals for one session would each need the whole stream.
final class TerminalMount: UIView {
    let terminal = MirrorTerminalView()
    /// Stretched in place of the terminal. The terminal works out where to draw from its own frame, which
    /// a stretch of its own would change.
    private let scaler = UIView()
    /// The terminal's size in points at its own type size, and the size of one character.
    private(set) var natural = CGSize.zero
    private(set) var cell = CGSize.zero
    /// How much the terminal is stretched to fit the mount: 1 is the Mac's own size.
    private(set) var scale: CGFloat = 1
    /// How much whatever holds the mount enlarges it: the canvas's zoom, or the full-screen view's. Shown
    /// larger than life, the text is drawn again that finely and not blown up from the screen's own fineness.
    private var magnification: CGFloat = 1
    /// The most times the screen's own fineness the text is drawn at. Each step is that many times the memory.
    private var finest: CGFloat = TerminalMount.finestAlone
    /// For a terminal that has the screen to itself, and for one of many on the canvas. On a real screen a
    /// terminal drawn three times as finely can take a hundred megabytes, and a flow has one for every agent.
    static let finestAlone: CGFloat = 3
    static let finestAmongMany: CGFloat = 2

    /// Says how much the mount is enlarged where it now is, and how finely it may be drawn there.
    func magnify(_ magnification: CGFloat, atMost finest: CGFloat = TerminalMount.finestAlone) {
        guard magnification != self.magnification || finest != self.finest else { return }
        self.magnification = magnification
        self.finest = finest
        applySharpness()
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        scaler.addSubview(terminal)
        addSubview(scaler)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (mount: TerminalMount, _) in mount.applyTheme() }
        applyTheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Makes the terminal `cols` by `rows`. Its frame is what SwiftTerm works the size out from, so the
    /// frame is set to fit exactly, with a point to spare so rounding can't cost a row or a column.
    func size(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        let fit = terminal.getOptimalFrameSize().size
        cell = CGSize(width: fit.width / CGFloat(max(cols, 1)), height: fit.height / CGFloat(max(rows, 1)))
        natural = CGSize(width: fit.width + 1, height: fit.height + 1)
        scaler.bounds = CGRect(origin: .zero, size: natural)
        terminal.frame = scaler.bounds
        // Now, so the terminal has taken its frame in before anything is fed to it.
        terminal.layoutIfNeeded()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard natural.width > 1, natural.height > 1, bounds.width > 0, bounds.height > 0 else { return }
        let spare = CGSize(width: bounds.width - natural.width, height: bounds.height - natural.height)
        let fit = min(bounds.width / natural.width, bounds.height / natural.height)
        // The Mac cuts its terminal to whole columns and rows out of this same space, so here it comes
        // out up to one character smaller than the space. Left at its own size it is the Mac's picture
        // exactly, and the sharpest: stretching it that last little bit would only soften it.
        let isLifeSize = spare.width >= 0 && spare.height >= 0 && spare.width <= cell.width + 1 && spare.height <= cell.height + 1
        let new = isLifeSize ? 1 : fit
        if new != scale {
            scale = new
            applySharpness()
            #if DEBUG
            onChange?()
            #endif
        }
        scaler.transform = CGAffineTransform(scaleX: scale, y: scale)
        // From the top left, where a terminal starts.
        scaler.center = CGPoint(x: natural.width * scale / 2, y: natural.height * scale / 2)
    }

    /// The terminal is told plain colours, so it is told again whenever light and dark swap. The Mac's `applyTheme`.
    private func applyTheme() {
        terminal.nativeBackgroundColor = Theme.terminal.resolvedColor(with: traitCollection)
        terminal.nativeForegroundColor = Theme.terminalInk.resolvedColor(with: traitCollection)
        backgroundColor = Theme.terminal
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A view has no screen to go by until it is on one.
        if window != nil { applySharpness() }
    }

    private func applySharpness() {
        // Whole steps, and no finer than whatever holds the mount allows.
        let wanted = traitCollection.displayScale * min(finest, max(1, (magnification * scale).rounded(.up)))
        guard terminal.contentScaleFactor != wanted else { return }
        terminal.contentScaleFactor = wanted
        terminal.setNeedsDisplay()
        #if DEBUG
        onChange?()
        #endif
    }

    #if DEBUG
    /// Called when how the terminal is shown has changed, so the state a test reads is written again.
    var onChange: (() -> Void)?
    /// How many times the screen's own fineness the terminal is drawn at now.
    var sharpness: CGFloat { terminal.contentScaleFactor / max(traitCollection.displayScale, 1) }
    #endif
}
