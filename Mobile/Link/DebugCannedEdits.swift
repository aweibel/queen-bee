#if DEBUG
import Foundation
import QueenBeeCore

/// The made-up Mac's copy of its flow, and what it makes of each edit: the change the real Mac would make,
/// through the same rules in `QueenBeeCore`, or the real Mac's refusal. It keeps its own Undo and Redo, by
/// the names the real one gives them, and treats a drag's steps as the real one does: one step of Undo for
/// the whole drag, ended by its last step or by anything else arriving. See `App/Remote/RemoteCommands.swift`.
/// It changes a card's settings and the flow's own as the real one does, and makes, renames and deletes
/// flows in its made-up list. None of this is in a release build.
struct MadeUpEdits {
    private(set) var flow: Flow
    /// Its projects, their flows and its saved roles, as it lists them.
    private(set) var library: RemoteLibrary
    /// The Start cards whose schedule is on. One is only ever turned on at the Mac, so here they only go off.
    private(set) var armed: [String]
    private var flowsMade = 0
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
    private static let flowGone = "That flow is no longer on your Mac."
    /// A flow that already runs the open one, so a Flow card here can't run it: the real Mac's own refusal.
    static let outerFlow = "other002"

    init(flow: Flow, library: RemoteLibrary) {
        self.flow = flow
        self.library = library
        // As if each schedule the flow came with had been turned on at the Mac.
        armed = flow.cards.filter { $0.kind == .start && $0.trigger != nil }.map(\.id)
    }

    var state: RemoteEditState {
        var fires: [String: Date] = [:]
        for id in armed {
            // A whole minute, so what is shown of it doesn't change from one look to the next.
            let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
            if let next = flow.card(id)?.trigger?.nextFire(after: now) { fires[id] = next }
        }
        return RemoteEditState(undo: undos.last.map { "Undo \($0.name)" }, redo: redos.last.map { "Redo \($0.name)" }, armed: armed, nextFires: fires)
    }

    private func summary(_ id: String) -> RemoteFlowSummary? { library.projects.flatMap(\.flows).first { $0.id == id } }

    private mutating func changeSummary(_ id: String, _ body: (inout RemoteFlowSummary) -> Void) {
        for p in library.projects.indices {
            for f in library.projects[p].flows.indices where library.projects[p].flows[f].id == id { body(&library.projects[p].flows[f]) }
        }
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

        case .patchCard(_, let cardID, let patch):
            guard let card = flow.card(cardID) else { return Self.cardGone }
            if patch.trigger != nil || patch.removesTrigger == true, card.kind != .start { return "Only a Start card has a schedule." }
            if let roleID = patch.role {
                guard card.kind == .agent else { return "Only an agent card has a role." }
                if !roleID.isEmpty, !library.roles.contains(where: { $0.id == roleID }) { return "That role is no longer on your Mac." }
            }
            if card.kind == .flow, let ref = patch.flowRef, !ref.isEmpty, ref != card.flowRef {
                guard let inner = summary(ref), ref != flow.id else { return Self.flowGone }
                if ref == Self.outerFlow { return "\(inner.name) already runs \(flow.name), so the two would go round for ever." }
            }
            let refusal = edit("Change \(card.name)") { flow in
                guard let index = flow.cards.firstIndex(where: { $0.id == cardID }) else { return }
                if let roleID = patch.role { flow.cards[index].role = roleID.isEmpty ? nil : roleID }
                if let trigger = patch.trigger { flow.cards[index].trigger = trigger }
                if patch.removesTrigger == true { flow.cards[index].trigger = nil }
                try flow.updateCard(cardID, patch: patch.cardPatch)
            }
            // A change the Mac didn't see the person make, to what a scheduled flow does, turns its schedules off.
            let changesWhatRuns = card.kind == .start ? patch.command != nil || patch.trigger != nil || patch.removesTrigger == true
                : card.kind == .agent && (patch.instructions != nil || patch.permissionMode != nil)
            if refusal == nil, changesWhatRuns { armed = [] }
            return refusal

        case .setFlowOption(_, let option):
            switch option {
            case .subflowLimit(let levels):
                guard flow.isSubflow != true else { return "The limit is set on the flow above this one." }
                flow.subflowLimit = Nesting.clamped(levels)
            case .notifyOrchestrator(let on):
                flow.notifyOrchestrator = on
            }
            return nil

        case .newFlow(let projectID, let name):
            guard let index = library.projects.firstIndex(where: { $0.id == projectID }) else { return "That project is no longer in your Mac's sidebar." }
            flowsMade += 1
            library.projects[index].flows.append(RemoteFlowSummary(id: "made000\(flowsMade)", name: name.isEmpty ? "Flow \(library.projects[index].flows.count + 1)" : name,
                                                                   isSubflow: false, activity: .quiet))
            return nil

        case .renameFlow(let id, let name):
            guard summary(id) != nil else { return Self.flowGone }
            changeSummary(id) { $0.name = name }
            if id == flow.id { flow.name = name }
            return nil

        case .deleteFlow(let id):
            guard let found = summary(id) else { return Self.flowGone }
            guard found.activity != .running else { return "\(found.name) is running. Stop the run before deleting the flow." }
            for index in library.projects.indices { library.projects[index].flows.removeAll { $0.id == id } }
            return nil

        default:
            return "This made-up Mac doesn't do that."
        }
    }
}
#endif
