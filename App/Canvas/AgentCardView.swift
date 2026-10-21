import AppKit
import QueenBeeCore

/// An agent's card: its live terminal under the title, its session's state beside the name,
/// and a Start button while no session is running.
final class AgentCardView: CardView {
    private let stateBadge = BadgeLabel()
    /// Shown when the card's settings have changed and the running session doesn't have them yet.
    private let restartBadge = BadgeLabel()
    /// What the session cost in the run on show.
    private let costBadge = BadgeLabel()
    private let startButton = NSButton(title: "Start agent", target: nil, action: nil)
    private let terminalHolder = FlippedView()
    private weak var terminal: NSView?
    private var stateText = ""
    /// The card's browser half, while its Browser switch is on.
    private(set) var browserPane: BrowserPaneView?
    private let browserRule = NSView()

    override var overviewText: String { stateText }

    override init(card: Card) {
        super.init(card: card)
        titleBar.addSubview(stateBadge)
        titleBar.addSubview(restartBadge)
        titleBar.addSubview(costBadge)
        costBadge.toolTip = "An estimate of what this agent's work cost in the run on show"
        restartBadge.toolTip = "You changed this agent's settings while it was running. Restart it from its settings to use them."

        terminalHolder.wantsLayer = true
        content.addSubview(terminalHolder)

        startButton.bezelStyle = .rounded
        startButton.font = Theme.mono(Theme.Size.body)
        startButton.target = self
        startButton.action = #selector(startSession)
        content.addSubview(startButton)

        browserRule.wantsLayer = true
        browserRule.isHidden = true
        content.addSubview(browserRule)
    }

    /// Shows the card's browser beside its terminal, or takes it away. `tab` is nil when the card has none.
    func attach(browser tab: BrowserTab?) {
        guard browserPane?.tab !== tab else { return }
        browserPane?.letGo()
        browserPane?.removeFromSuperview()
        browserPane = tab.map { BrowserPaneView(tab: $0) }
        if let browserPane { content.addSubview(browserPane, positioned: .below, relativeTo: browserRule) }
        browserRule.isHidden = browserPane == nil
        needsLayout = true
        updateBrowserVisibility()
    }

    /// The canvas scrolled or zoomed. A browser that can't be seen, or is too small to read, stops streaming.
    func updateBrowserVisibility() {
        guard let browserPane else { return }
        browserPane.isInView = zoom >= Self.overviewBelow && !browserPane.visibleRect.isEmpty
    }

    override var zoom: CGFloat {
        didSet {
            updateBrowserVisibility()
            // Under the overview the terminal can't be seen, and drawing it is the costliest part of a card.
            // Its session runs on and keeps what it prints, so it is whole again when the canvas zooms back in.
            let covered = zoom < Self.overviewBelow
            if terminalHolder.isHidden != covered { terminalHolder.isHidden = covered }
        }
    }

    override func removeFromSuperview() {
        browserPane?.letGo()
        super.removeFromSuperview()
    }

    override var titleAccessories: [NSView] { [stateBadge, costBadge, restartBadge] }

    func attach(terminal view: NSView) {
        guard terminal !== view else { return }
        terminal?.removeFromSuperview()
        terminal = view
        terminalHolder.addSubview(view)
        needsLayout = true
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
        stateText = asked ?? (isWaiting ? "waiting" : context.isSlowToStart ? "starting is taking a while" : state.label.lowercased())
        stateBadge.set(stateText, tone: asked == nil ? tone : .live)
        stateBadge.toolTip = context.isSlowToStart
            ? "Claude Code hasn't said it's ready yet. Look in the terminal in case it's asking you something, such as whether to trust this folder. If it's stuck, press Retry."
            : nil
        restartBadge.set(context.needsRestart ? "restart to apply" : "", tone: .live)
        costBadge.set(context.cost ?? "", tone: .plain)
        let live = state != .notStarted && state != .exited
        startButton.isHidden = live && !context.isSlowToStart
        startButton.title = context.isSlowToStart ? "Retry" : state == .exited ? "Restart agent" : "Start agent"
        startButton.toolTip = context.isSlowToStart ? "Stop this agent's Claude Code and start it again" : nil
        isSlowToStart = context.isSlowToStart
        super.update(card: new, context: context)
    }

    /// While a slow start is shown, Retry sits at the foot of the terminal, which may be asking something.
    private var isSlowToStart = false

    override func layoutContent() {
        // With a browser the card is split down the middle: terminal on the left, page on the right.
        var left = content.bounds
        if let browserPane {
            left.size.width = (content.bounds.width / 2).rounded()
            browserRule.frame = CGRect(x: left.maxX, y: 0, width: 1, height: content.bounds.height)
            browserPane.frame = CGRect(x: left.maxX + 1, y: 0, width: content.bounds.width - left.maxX - 1, height: content.bounds.height)
        }
        terminalHolder.frame = left
        // A few points of padding so text doesn't touch the card's edge or the resize corner.
        terminal?.frame = terminalHolder.bounds.insetBy(dx: 6, dy: 4)
        startButton.sizeToFit()
        startButton.frame.origin = CGPoint(x: left.minX + (left.width - startButton.frame.width) / 2,
                                           y: isSlowToStart ? max(0, left.height - startButton.frame.height - Theme.Space.m)
                                                            : (left.height - startButton.frame.height) / 2)
        updateBrowserVisibility()
    }

    override func updateContentLayers() {
        terminalHolder.layer?.backgroundColor = Theme.terminal.cgColor
        browserRule.layer?.backgroundColor = Theme.hairline.cgColor
    }

    @objc private func startSession() {
        canvas?.controller?.startSession(forCard: card.id)
    }
}
