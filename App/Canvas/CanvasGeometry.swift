import AppKit
import QueenBeeCore

/// Where things sit on a card, in canvas points. Card views and the link layer both
/// read these, so a link always ends on the dot it belongs to.
enum CanvasGeometry {
    static let titleHeight: CGFloat = 28
    static let portRowHeight: CGFloat = 22
    static let portRadius: CGFloat = 5
    static let resizeHandle: CGFloat = 16
    static let gridStep: CGFloat = 24

    static func frame(of card: Card) -> CGRect {
        CGRect(x: card.x, y: card.y, width: card.width, height: card.height)
    }

    /// The input dot's centre, on the card's left edge beside its title.
    static func inputPoint(of card: Card) -> CGPoint {
        CGPoint(x: card.x, y: card.y + titleHeight / 2)
    }

    /// An output dot's centre on the card's right edge: one output sits beside the
    /// title; named outputs get a row each at the card's foot.
    static func outputPoint(of card: Card, port: String) -> CGPoint {
        let all = ports(of: card)
        guard all.count > 1, let i = all.firstIndex(of: port) else {
            return CGPoint(x: card.x + card.width, y: card.y + titleHeight / 2)
        }
        let fromBottom = CGFloat(all.count - i)
        return CGPoint(x: card.x + card.width, y: card.y + card.height - fromBottom * portRowHeight + portRowHeight / 2)
    }

    /// The corner points of a link's right-angled route. Links that leave the same card are
    /// given a lane each, so two that loop back don't run on top of one another.
    static func route(of link: Link, in flow: Flow) -> [CGPoint]? {
        guard let from = flow.card(link.from), let to = flow.card(link.to) else { return nil }
        let siblings = flow.links(from: link.from)
        let lane = siblings.firstIndex { $0.id == link.id } ?? 0
        // A card inside a folded group is drawn as the group's one card: a link to or from it
        // meets that card's edge, and a link between two cards of the same folded group isn't drawn.
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
              let frame = GroupFrameView.frame(of: group, in: flow) else { return nil }
        return (group.id, frame)
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
