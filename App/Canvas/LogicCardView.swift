import AppKit
import QueenBeeCore

/// One named output of a card: its name and how many times the run has left by it.
/// The output taken last is tinted, so the run's latest turn is visible at a glance.
private final class PortRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var isLatest = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        nameLabel.font = Theme.mono(Theme.Size.caption, .medium)
        nameLabel.alignment = .right
        nameLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = Theme.mono(Theme.Size.caption)
        addSubview(nameLabel)
        addSubview(countLabel)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(name: String, count: Int, isLatest: Bool) {
        nameLabel.stringValue = name
        countLabel.stringValue = count > 0 ? "\(count)" : ""
        self.isLatest = isLatest
        nameLabel.textColor = isLatest ? Theme.liveInk : Theme.ink
        countLabel.textColor = isLatest ? Theme.liveInk : Theme.inkSecondary
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        countLabel.frame = NSRect(x: 10, y: 4, width: 40, height: 14)
        nameLabel.frame = NSRect(x: 52, y: 4, width: max(0, bounds.width - 52 - 14), height: 14)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = isLatest ? Theme.liveTint.cgColor : NSColor.clear.cgColor
    }
}

/// A logic card: a line saying what it is set to, a row for each named output,
/// and a warning when its wiring would leave a run stuck.
final class LogicCardView: CardView {
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")
    private var portRows: [PortRowView] = []

    override init(card: Card) {
        super.init(card: card)
        summaryLabel.font = Theme.sans(Theme.Size.body)
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(summaryLabel)
        warningLabel.font = Theme.mono(Theme.Size.caption, .medium)
        warningLabel.textColor = Theme.failInk
        warningLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(warningLabel)
    }

    override func update(card new: Card, context: CardContext) {
        super.update(card: new, context: context)
        let progress = context.waiting ?? runProgress(of: new, context: context)
        var summary = CardSummary.text(for: new, inputs: context.inputCount)
        // A schedule that came in the file, or came back with an undo, is off until the person turns it on.
        if new.kind == .start, new.trigger != nil, !context.isArmed { summary += " · off" }
        summaryLabel.stringValue = progress ?? context.result ?? summary
        summaryLabel.textColor = progress != nil ? Theme.liveInk : context.result != nil ? Theme.ink : Theme.inkSecondary
        warningLabel.stringValue = context.warning ?? ""
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
        needsLayout = true
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
        let summaryHeight = max(0, content.bounds.height - foot - warningHeight - 12)
        summaryLabel.frame = NSRect(x: 10, y: 6, width: w - 20, height: summaryHeight)
        warningLabel.frame = NSRect(x: 10, y: 6 + summaryHeight, width: w - 20, height: 15)
        for (i, row) in portRows.enumerated() {
            row.frame = NSRect(x: 1, y: content.bounds.height - foot + CGFloat(i) * CanvasGeometry.portRowHeight,
                               width: w - 2, height: CanvasGeometry.portRowHeight)
        }
    }
}

/// One line about what a logic card is set to.
enum CardSummary {
    static func text(for card: Card, inputs: Int) -> String {
        switch card.kind {
        case .agent: return ""
        case .start:
            let first = (card.command ?? "").split(separator: "\n").first.map(String.init) ?? ""
            let command = first.isEmpty ? "Write the command" : first
            return card.trigger.map { "\(command)\n\($0.summary)" } ?? command
        case .ifElse: return check(card)
        case .switchCard: return "Claude picks one of \((card.branches ?? []).count) branches"
        case .and: return "Waits for all \(inputs) linked cards"
        case .or: return "Passes on the first of \(inputs) to answer"
        case .prompt:
            let first = (card.template ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return first.isEmpty ? "Passes the message on" : first
        case .loop: return "\(check(card)), up to \(card.maxTries ?? 3) tries"
        case .end:
            let file = card.saveTo ?? ""
            return file.isEmpty ? "The final answer shows here" : "Saves to \(file)"
        case .note: return card.text ?? ""
        case .approval:
            let ask = (card.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (ask.isEmpty ? "Waits for you to approve" : ask) + timeLimit(card)
        case .forEach:
            let most = card.maxItems ?? 20
            return (card.split ?? .auto) == .lines ? "Each line in turn, up to \(most)" : "Each item in turn, up to \(most)"
        case .flow:
            return "Double-click to build what it does"
        case .script:
            let first = (card.command ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return (first.isEmpty ? "Write the command" : first) + timeLimit(card)
        }
    }

    /// A second line for a card that answers for the person when they don't, such as "Rejects after 8 hours".
    private static func timeLimit(_ card: Card) -> String {
        guard let minutes = card.waitMinutes, minutes > 0 else { return "" }
        let after = HoldTimeLimit.describe(minutes: minutes)
        switch HoldTimeLimit.port(for: card) {
        case "approved": return "\nApproves after \(after)"
        case "rejected": return "\nRejects after \(after)"
        default: return "\nSkipped if not allowed in \(after)"
        }
    }

    private static func check(_ card: Card) -> String {
        let value = (card.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Say what to check" }
        switch card.check ?? .judge {
        case .judge: return "\(value)?"
        case .contains: return "Has \"\(value)\""
        case .notContains: return "No \"\(value)\""
        case .regex: return "Matches /\(value)/"
        }
    }
}
