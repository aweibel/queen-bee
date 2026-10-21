import QueenBeeCore
import UIKit

/// Where things sit on a card, in canvas points. This mirrors the Mac's `CanvasGeometry` in
/// `App/Canvas/CanvasGeometry.swift` number for number, so a link meets a card here exactly where it does there.
nonisolated enum CanvasGeometry {
    static let titleHeight: CGFloat = 28
    static let portRowHeight: CGFloat = 22
    static let portRadius: CGFloat = 5
    static let resizeHandle: CGFloat = 16
    static let gridStep: CGFloat = Theme.Grid.step

    /// The whole surface, and the room to pan left of and above its origin. The Mac's `CanvasView.documentSize` and `margin`.
    static let documentSize = CGSize(width: 14000, height: 11000)
    static let margin: CGFloat = 3000

    static func frame(of card: Card) -> CGRect {
        CGRect(x: card.x, y: card.y, width: card.width, height: card.height)
    }

    /// The input dot's centre, on the card's left edge beside its title.
    static func inputPoint(of card: Card) -> CGPoint {
        CGPoint(x: card.x, y: card.y + titleHeight / 2)
    }

    /// An output dot's centre on the card's right edge: one output sits beside the title; named outputs get
    /// a row each at the card's foot.
    static func outputPoint(of card: Card, port: String) -> CGPoint {
        let all = ports(of: card)
        guard all.count > 1, let i = all.firstIndex(of: port) else {
            return CGPoint(x: card.x + card.width, y: card.y + titleHeight / 2)
        }
        let fromBottom = CGFloat(all.count - i)
        return CGPoint(x: card.x + card.width, y: card.y + card.height - fromBottom * portRowHeight + portRowHeight / 2)
    }

    /// The corner points of a link's right-angled route. Links that leave the same card are given a lane
    /// each, so two that loop back don't run on top of one another.
    static func route(of link: Link, in flow: Flow) -> [CGPoint]? {
        guard let from = flow.card(link.from), let to = flow.card(link.to) else { return nil }
        let siblings = flow.links(from: link.from)
        let lane = siblings.firstIndex { $0.id == link.id } ?? 0
        // A card inside a folded group is drawn as the group's one card: a link to or from it meets that
        // card's edge, and a link between two cards of the same folded group isn't drawn.
        let fromFold = foldedFrame(holding: from.id, in: flow), toFold = foldedFrame(holding: to.id, in: flow)
        if let fromFold, let toFold, fromFold.id == toFold.id { return nil }
        let start = fromFold.map { CGPoint(x: $0.frame.maxX, y: $0.frame.midY) } ?? outputPoint(of: from, port: link.port)
        let end = toFold.map { CGPoint(x: $0.frame.minX, y: $0.frame.midY) } ?? inputPoint(of: to)
        return LinkRouter.route(from: start, to: end, source: fromFold?.frame ?? frame(of: from),
                                target: toFold?.frame ?? frame(of: to), lane: lane)
    }

    /// The folded group a card is in, and where that group's one card sits.
    static func foldedFrame(holding cardID: String, in flow: Flow) -> (id: String, frame: CGRect)? {
        guard let group = flow.group(containing: cardID), group.isFolded,
              let frame = groupFrame(of: group, cards: flow.cards) else { return nil }
        return (group.id, frame)
    }

    // MARK: Groups. The Mac's `GroupFrameView.frame(of:in:zoom:)` and `scale(for:)`.

    /// How far a group's frame stands off from its cards, and the room its name takes above them.
    static let groupPadding: CGFloat = 18
    static let groupTitleHeight: CGFloat = 24
    static let foldedGroupSize = CGSize(width: 240, height: 72)

    /// Where a group's view sits: round its cards when unfolded, a small card at their corner when folded.
    /// `zoom` only matters to an unfolded frame: zoomed out, its name strip grows so the name stays readable.
    static func groupFrame(of group: CardGroup, cards: [Card], zoom: CGFloat = 1) -> CGRect? {
        let frames = cards.filter { group.cardIDs.contains($0.id) }.map(frame(of:))
        guard let first = frames.first else { return nil }
        let box = frames.dropFirst().reduce(first) { $0.union($1) }
        if group.isFolded { return CGRect(origin: box.origin, size: foldedGroupSize) }
        let strip = groupTitleHeight * groupScale(for: zoom)
        return CGRect(x: box.minX - groupPadding, y: box.minY - groupPadding - strip,
                      width: box.width + groupPadding * 2, height: box.height + groupPadding * 2 + strip)
    }

    /// How much a group's name grows as the canvas zooms out, so it reads about the same on screen.
    static func groupScale(for zoom: CGFloat) -> CGFloat {
        zoom < 0.7 ? min(3.2, 0.7 / max(zoom, 0.01)) : 1
    }

    static func icon(for kind: CardKind) -> String {
        switch kind {
        case .agent: "terminal"
        case .start: "play"
        case .ifElse: "arrow.triangle.branch"
        case .switchCard: "arrow.triangle.swap"
        case .and: "arrow.triangle.merge"
        case .or: "bolt"
        case .prompt: "pencil"
        case .loop: "repeat"
        case .end: "flag"
        case .note: "note.text"
        case .approval: "checkmark.seal"
        case .script: "chevron.left.forwardslash.chevron.right"
        case .flow: "point.3.connected.trianglepath.dotted"
        case .forEach: "list.bullet"
        }
    }
}

/// One line about what a logic card is set to. The Mac's `CardSummary` in `App/Canvas/LogicCardView.swift`,
/// word for word, apart from a Flow card with no flow: the Mac says how to make one there, which can't be done here.
nonisolated enum CardSummary {
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
            return "No flow chosen yet"
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
