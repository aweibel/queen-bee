#if DEBUG
import Foundation
import QueenBeeCore

/// The made-up Mac's copy of its flow, and what it makes of each edit: the change the real Mac would make,
/// through the same rules in `QueenBeeCore`, or the real Mac's refusal. It keeps its own Undo and Redo, by
/// the names the real one gives them, and treats a drag's steps as the real one does: one step of Undo for
/// the whole drag, ended by its last step or by anything else arriving. See `App/Remote/RemoteCommands.swift`.
/// It changes no card's settings and makes no flows. None of this is in a release build.
struct MadeUpEdits {
    private(set) var flow: Flow
    /// Set by a test: every edit is refused in these words until it is cleared.
    var refusing: String?
    private var undos: [(name: String, flow: Flow)] = []
    private var redos: [(name: String, flow: Flow)] = []
    /// The drag that is under way, and the flow as it was before its first step.
    private var drag: (start: Flow, drag: RemoteDrag)?
    /// As far up and left as the real Mac lets a card go.
    private static let farLeft = -2900.0
    private static let cardGone = "That card is no longer in the flow."
    private static let linkGone = "That link is no longer in the flow."
    private static let groupGone = "That group is no longer in the flow."

    init(flow: Flow) { self.flow = flow }

    var state: RemoteEditState {
        RemoteEditState(undo: undos.last.map { "Undo \($0.name)" }, redo: redos.last.map { "Redo \($0.name)" })
    }

    /// A change made at the Mac itself, by whoever is sitting at it.
    mutating func changeAtMac(_ name: String, _ body: (inout Flow) -> Void) {
        let old = flow
        body(&flow)
        if flow != old {
            undos.append((name, old))
            redos = []
        }
    }

    private mutating func endDrag() {
        guard let open = drag else { return }
        drag = nil
        guard open.start != flow else { return }
        let name = switch open.drag {
        case .move: "Move"
        case .resize: "Resize"
        }
        undos.append((name, open.start))
        redos = []
    }

    /// Nil when it was done. Otherwise why not, in the real Mac's words.
    mutating func obey(_ command: RemoteCommand) -> String? {
        if let open = drag, command.dragStep?.drag != open.drag { endDrag() }
        if let problem = command.problem { return problem }
        if let refusing {
            if command.dragStep?.isLast == true { endDrag() }
            return refusing
        }
        func edit(_ name: String, _ body: (inout Flow) throws -> Void) -> String? {
            var copy = flow
            do {
                try body(&copy)
            } catch {
                return String(describing: error)
            }
            if copy != flow {
                undos.append((name, flow))
                redos = []
                flow = copy
            }
            return nil
        }
        func group(_ id: String) -> CardGroup? { (flow.groups ?? []).first { $0.id == id } }

        switch command {
        case .addCard(_, let kind, let x, let y):
            let made = Card.make(kind: kind, name: "x", x: 0, y: 0)
            return edit("Add \(kind.label)") { try $0.addCard(kind: kind, x: max(20, x - made.width / 2), y: max(20, y - CanvasGeometry.titleHeight / 2)) }

        case .moveCards(_, let moves, let final):
            defer { if final { endDrag() } }
            guard moves.keys.allSatisfy({ flow.card($0) != nil }) else { return Self.cardGone }
            if drag == nil { drag = (flow, .move) }
            // The whole set stops at the canvas's edge together, as on the real Mac.
            let dx = max(0, Self.farLeft - (moves.values.map(\.x).min() ?? 0)), dy = max(0, Self.farLeft - (moves.values.map(\.y).min() ?? 0))
            for index in flow.cards.indices {
                guard let place = moves[flow.cards[index].id] else { continue }
                flow.cards[index].x = place.x + dx
                flow.cards[index].y = place.y + dy
            }
            return nil

        case .resizeCard(_, let cardID, let frame, let final):
            defer { if final { endDrag() } }
            guard flow.card(cardID) != nil else { return Self.cardGone }
            if drag == nil { drag = (flow, .resize(cardID: cardID)) }
            var patch = CardPatch()
            patch.x = max(frame.x, Self.farLeft)
            patch.y = max(frame.y, Self.farLeft)
            patch.width = frame.width
            patch.height = frame.height
            _ = try? flow.updateCard(cardID, patch: patch)
            return nil

        case .deleteItems(_, let cardIDs, let linkIDs):
            let cards = Set(cardIDs), links = Set(linkIDs)
            guard cards.allSatisfy({ flow.card($0) != nil }) else { return Self.cardGone }
            guard links.allSatisfy({ id in flow.links.contains { $0.id == id } }) else { return Self.linkGone }
            let name = cards.count > 1 ? "Delete Cards" : cards.count == 1 ? "Delete Card" : links.count == 1 ? "Delete Link" : "Delete Links"
            return edit(name) { flow in
                for id in cards { try flow.removeCard(id) }
                for id in links where flow.links.contains(where: { $0.id == id }) { try flow.removeLink(id) }
            }

        case .addLink(_, let from, let port, let to):
            guard flow.card(from) != nil, flow.card(to) != nil else { return Self.cardGone }
            return edit("Link") { try $0.addLink(from: from, port: port, to: to) }

        case .setLinkLimit(_, let linkID, let maxPasses):
            guard flow.links.contains(where: { $0.id == linkID }) else { return Self.linkGone }
            return edit("Change Link") { try $0.updateLink(linkID, maxPasses: maxPasses) }

        case .duplicate(_, let cardIDs):
            let ids = Set(cardIDs)
            guard ids.allSatisfy({ flow.card($0) != nil }) else { return Self.cardGone }
            return edit(ids.count == 1 ? "Duplicate Card" : "Duplicate Cards") { _ = $0.insert($0.fragment(of: ids), dx: 48, dy: 48) }

        case .tidy:
            return edit("Tidy Up") { flow in
                for (id, point) in Tidy.layout(flow) {
                    guard let index = flow.cards.firstIndex(where: { $0.id == id }) else { continue }
                    flow.cards[index].x = point.x
                    flow.cards[index].y = point.y
                }
            }

        case .group(_, let cardIDs, let name):
            guard cardIDs.allSatisfy({ flow.card($0) != nil }) else { return Self.cardGone }
            return edit("Group") { try $0.addGroup(name: name, cardIDs: cardIDs) }

        case .ungroup(_, let groupID):
            guard group(groupID) != nil else { return Self.groupGone }
            return edit("Ungroup") { $0.removeGroup(groupID) }

        case .renameGroup(_, let groupID, let name):
            guard group(groupID) != nil else { return Self.groupGone }
            return edit("Rename Group") { try $0.updateGroup(groupID, name: name) }

        case .foldGroup(_, let groupID, let folded):
            guard group(groupID) != nil else { return Self.groupGone }
            return edit(folded ? "Fold Group" : "Unfold Group") { try $0.updateGroup(groupID, isFolded: folded) }

        case .undo:
            guard let last = undos.popLast() else { return "There is nothing to undo." }
            redos.append((last.name, flow))
            flow = last.flow
            return nil

        case .redo:
            guard let next = redos.popLast() else { return "There is nothing to redo." }
            undos.append((next.name, flow))
            flow = next.flow
            return nil

        default:
            return "This made-up Mac can't change a card's settings, or make or delete a flow."
        }
    }
}
#endif
