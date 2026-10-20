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
    /// The Start cards whose schedule is on. A device turns one on or off with `armSchedule`, and an edit from a
    /// device to what the flow does turns them all off.
    private(set) var armed: [String]
    /// What each agent's made-up session was started with, by card id: what "Not in use yet" is measured from.
    private(set) var using: [String: Card] = [:]
    /// With `-qbParity 1`: it also says what an agent's session doesn't have yet, and a role picked for a card gives
    /// it what the role holds. Without, the scenarios from before stage 4 see the made-up Mac they always saw.
    var isFull = false
    /// The flows it has besides the open one, as they were left, by id. Opening one swaps it with the open one.
    private var parked: [String: (flow: Flow, armed: [String], using: [String: Card])] = [:]
    private var subflowsMade = 0
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
        // As if each agent's session had been started with the flow as it came.
        for card in flow.cards where card.kind == .agent { using[card.id] = card }
    }

    // MARK: More than one flow

    /// Flows the device can open besides this one.
    mutating func park(_ flows: [Flow]) {
        for other in flows { parked[other.id] = (other, [], [:]) }
    }

    /// The device opened another flow. False when the made-up Mac has no such flow to send.
    mutating func switchTo(_ id: String) -> Bool {
        guard id != flow.id else { return true }
        guard let next = parked.removeValue(forKey: id) else { return false }
        endDrag()
        parked[flow.id] = (flow, armed, using)
        (flow, armed, using) = next
        undos = []
        redos = []
        return true
    }

    /// The settings each agent's session doesn't have yet, by the Mac's names for them. Nothing for a session that isn't running.
    func awaitingRestart(_ sessions: [String: SessionState]) -> [String: [String]] {
        guard isFull else { return [:] }
        var pending: [String: [String]] = [:]
        for card in flow.cards where card.kind == .agent {
            let state = sessions[card.id] ?? .notStarted
            guard state != .notStarted, state != .exited, let was = using[card.id] else { continue }
            let changed = Self.changes(card, from: was)
            if !changed.isEmpty { pending[card.id] = changed }
        }
        return pending
    }

    /// The settings of an agent that differ from what its session was started with, by the Mac's names for them.
    private static func changes(_ card: Card, from was: Card) -> [String] {
        let names: [(Bool, String)] = [(card.name != was.name, "name"), (card.instructions != was.instructions, "instructions"),
                                       (card.model != was.model, "model"), (card.effort != was.effort, "effort"),
                                       (card.permissionMode != was.permissionMode, "permissions"), ((card.browser ?? false) != (was.browser ?? false), "browser")]
        return names.filter(\.0).map(\.1)
    }

    /// An agent's session was started, or restarted to apply what had changed.
    mutating func startedSession(_ cardID: String) {
        if let card = flow.card(cardID) { using[cardID] = card }
    }

    // MARK: Commands that change no flow

    /// What the made-up Mac makes of a command that is not an edit and is about its list, its roles or a schedule.
    /// Nil when it was done, or when it is none of these. Otherwise why not, in the real Mac's words.
    mutating func housekeeping(_ command: RemoteCommand) -> String? {
        switch command {
        case .armSchedule(_, let cardID, let on):
            guard let card = flow.card(cardID) else { return Self.cardGone }
            guard card.kind == .start else { return "Only a Start card has a schedule." }
            guard card.trigger != nil else { return "\(card.name) has no schedule to turn \(on ? "on" : "off"). Choose when it runs first." }
            if on, !armed.contains(cardID) { armed.append(cardID) }
            if !on { armed.removeAll { $0 == cardID } }
            return nil
        case .pin(let id, let on):
            guard summary(id) != nil else { return Self.flowGone }
            changeSummary(id) { $0.pinned = on }
            return nil
        case .updateRole(let roleID, _, let cardID):
            guard let index = library.roles.firstIndex(where: { $0.id == roleID }) else { return Self.roleGone }
            guard let card = flow.card(cardID) else { return Self.cardGone }
            guard card.kind == .agent, card.role == roleID else {
                return "\(card.name) doesn't have the role \(library.roles[index].name), so it can't update it."
            }
            // Marked as changed from this device, as the real Mac marks it.
            library.roles[index] = RemoteRole(id: roleID, name: library.roles[index].name, instructions: card.instructions ?? "", model: card.model ?? "",
                                              effort: card.effort ?? "", permissionMode: card.permissionMode ?? "",
                                              changedFrom: Self.deviceName, changedAt: Date())
            return nil
        case .deleteRole(let roleID):
            guard library.roles.contains(where: { $0.id == roleID }) else { return Self.roleGone }
            library.roles.removeAll { $0.id == roleID }
            return nil
        case .clearBrowserData(let projectID), .installBrowser(let projectID), .restartBrowser(let projectID):
            guard let index = library.projects.firstIndex(where: { $0.id == projectID }) else { return "That project is no longer in your Mac's sidebar." }
            var browser = library.projects[index].browser
            switch command {
            case .clearBrowserData:
                guard browser.hasData else { return "There is no browser data to clear in \(library.projects[index].name)." }
                browser.hasData = false
            case .installBrowser:
                if browser.status == .downloading { return "The browser is already downloading." }
                guard browser.status == .missing else {
                    return "Your Mac isn't offering to download a browser: it has one it can use, or none has been needed yet."
                }
                browser.status = .downloading
                browser.progress = 0.05
            default:
                guard browser.status == .stopped || browser.status == .failed else { return "The browser isn't stopped, so there is nothing to restart." }
                browser.status = .starting
                browser.problem = nil
            }
            library.projects[index].browser = browser
            return nil
        default:
            return nil
        }
    }

    /// Something a test has the made-up Mac's project browser do by itself.
    mutating func setBrowser(_ change: (inout RemoteBrowserState) -> Void) {
        guard !library.projects.isEmpty else { return }
        change(&library.projects[0].browser)
    }

    /// The flow is listed as running or not, as the real Mac's sidebar badges it.
    mutating func setActivity(_ id: String, _ activity: FlowActivity) { changeSummary(id) { $0.activity = activity } }

    private static let roleGone = "That role is no longer on your Mac."
    /// What the made-up Mac calls this device when it marks a role the device saved or changed.
    static let deviceName = "This iPad"

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
                if let roleID = patch.role {
                    flow.cards[index].role = roleID.isEmpty ? nil : roleID
                    // Picking a role, or Reset, gives the card what the role holds, as on the Mac.
                    if isFull, let role = library.roles.first(where: { $0.id == roleID }) {
                        flow.cards[index].instructions = role.instructions.isEmpty ? nil : role.instructions
                        flow.cards[index].model = role.model.isEmpty ? nil : role.model
                        flow.cards[index].effort = role.effort.isEmpty ? nil : role.effort
                        flow.cards[index].permissionMode = role.permissionMode.isEmpty ? nil : role.permissionMode
                    }
                }
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
            case .spendingLimit(let dollars):
                flow.spendingLimit = SpendingLimit.clamped(dollars)
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

        case .revertSettings(_, let cardID):
            guard let card = flow.card(cardID) else { return Self.cardGone }
            guard card.kind == .agent else { return "Only an agent card has settings to put back." }
            guard isFull, let was = using[cardID], !Self.changes(card, from: was).isEmpty else { return "There is nothing to undo: the agent is using these settings." }
            return edit("Change \(card.name)") { flow in
                guard let index = flow.cards.firstIndex(where: { $0.id == cardID }) else { return }
                flow.cards[index].name = was.name
                flow.cards[index].instructions = was.instructions
                flow.cards[index].model = was.model
                flow.cards[index].effort = was.effort
                flow.cards[index].permissionMode = was.permissionMode
                flow.cards[index].browser = was.browser
            }

        case .paste(_, var fragment, let at):
            fragment = fragment.cleanedFromDevice
            let roles = Set(library.roles.map(\.id)), flows = Set(library.projects.flatMap(\.flows).map(\.id)).subtracting([flow.id])
            for index in fragment.cards.indices {
                if let role = fragment.cards[index].role, !roles.contains(role) { fragment.cards[index].role = nil }
                if let ref = fragment.cards[index].flowRef, !flows.contains(ref) { fragment.cards[index].flowRef = nil }
            }
            // The real Mac's `pasteOffset`: the top-left card at the point, or a step down and right.
            var dx = 48.0, dy = 48.0
            if let at, let left = fragment.cards.map(\.x).min(), let top = fragment.cards.map(\.y).min() { dx = at.x - left; dy = at.y - top }
            let old = flow
            let refusal = edit("Paste") { _ = $0.insert(fragment, dx: dx, dy: dy) }
            if refusal == nil, flow.changesWhatItDoes(from: old) { armed = [] }
            return refusal

        case .addRoleCard(_, let roleID, let x, let y):
            guard let role = library.roles.first(where: { $0.id == roleID }) else { return Self.roleGone }
            let made = Card.make(kind: .agent, name: "x", x: 0, y: 0)
            let old = flow
            let refusal = edit("Add \(role.name)") { flow in
                var patch = CardPatch()
                patch.instructions = role.instructions.isEmpty ? nil : role.instructions
                patch.model = role.model.isEmpty ? nil : role.model
                patch.effort = role.effort.isEmpty ? nil : role.effort
                patch.permissionMode = role.permissionMode.isEmpty ? nil : role.permissionMode
                let card = try flow.addCard(kind: .agent, name: flow.uniqueName(role.name), x: max(20, x - made.width / 2),
                                            y: max(20, y - CanvasGeometry.titleHeight / 2), patch: patch)
                if let index = flow.cards.firstIndex(where: { $0.id == card.id }) { flow.cards[index].role = role.id }
            }
            if refusal == nil, flow.changesWhatItDoes(from: old) { armed = [] }
            return refusal

        case .newSubflow(_, let cardID, let wanted):
            guard let card = flow.card(cardID) else { return Self.cardGone }
            guard card.kind == .flow else { return "Only a Flow card runs a sub-flow." }
            if let ref = card.flowRef, let inner = summary(ref) { return "\(card.name) already runs \(inner.name)." }
            subflowsMade += 1
            var inner = Flow(id: "sub000\(subflowsMade)", name: wanted.isEmpty ? card.name : wanted, cards: [
                Card(id: "in\(subflowsMade)", kind: .start, name: "Input", x: 40, y: 120, width: 240, height: 120),
                Card(id: "out\(subflowsMade)", kind: .end, name: "Output", x: 400, y: 120, width: 240, height: 120),
            ], links: [Link(id: "sl\(subflowsMade)", from: "in\(subflowsMade)", to: "out\(subflowsMade)")])
            inner.isSubflow = true
            let refusal = edit("Change \(card.name)") { flow in
                guard let index = flow.cards.firstIndex(where: { $0.id == cardID }) else { return }
                flow.cards[index].flowRef = inner.id
            }
            guard refusal == nil else { return refusal }
            parked[inner.id] = (inner, [], [:])
            if let index = library.projects.firstIndex(where: { $0.flows.contains { $0.id == flow.id } }) {
                library.projects[index].flows.append(RemoteFlowSummary(id: inner.id, name: inner.name, isSubflow: true, activity: .quiet, parentID: flow.id,
                                                                       cardNames: Remote.listedNames(of: inner)))
            }
            armed = []
            return nil

        case .saveRole(_, let cardID, let wanted):
            guard let card = flow.card(cardID) else { return Self.cardGone }
            guard card.kind == .agent else { return "Only an agent card can be saved as a role." }
            if let id = card.role, let current = library.roles.first(where: { $0.id == id }) {
                return "\(card.name) already has the role \(current.name). Update that role instead."
            }
            if let mode = card.permissionMode, !mode.isEmpty, !Card.permissionModes.contains(mode) {
                return "A role can't skip permission checks. Give \(card.name) one of these permissions first: \(Card.permissionModes.joined(separator: ", "))."
            }
            let name = wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.name : wanted
            if library.roles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return "Your Mac already has a role called \(name). Give this one another name."
            }
            let role = RemoteRole(id: "role\(String(format: "%04d", library.roles.count + 100))", name: name, instructions: card.instructions ?? "",
                                  model: card.model ?? "", effort: card.effort ?? "", permissionMode: card.permissionMode ?? "",
                                  changedFrom: Self.deviceName, changedAt: Date())
            library.roles.append(role)
            return edit("Save Role") { flow in
                guard let index = flow.cards.firstIndex(where: { $0.id == cardID }) else { return }
                flow.cards[index].role = role.id
            }

        default:
            return "This made-up Mac doesn't do that."
        }
    }
}
#endif
