import Foundation
import QueenBeeCore
import UIKit

/// Editing the open flow from this device: what the bar and the menus offer, and how each thing asked for
/// becomes a command. Like the rest of the controls, what is offered is a courtesy. The Mac checks every
/// command itself, makes the change itself, and what it made comes back with the flow.
extension RemoteClient {
    /// Editing is on for the flow that is open.
    var isEditing: Bool { edit.isOn(for: mirror.openFlowID) && mirror.snapshot != nil }

    /// Edit was pressed, or Done.
    func setEditing(_ on: Bool) {
        guard on else { return stopEditing() }
        guard abilities.canAct, let flowID = mirror.snapshot?.flow.id else { return }
        edit.start(in: flowID)
    }

    /// Turns editing off and lets go of whatever was under the finger. Called by Done, and by the canvas
    /// when this device may no longer act: control was turned off, the link dropped, or an earlier run was put on show.
    func stopEditing() {
        canvas.view?.letGoOfDrag()
        // What was written in a setting and not sent is sent now, or kept if the Mac can't be reached.
        flushFields()
        edit.stop()
    }

    /// Whether a command of this kind has been sent and not yet answered. Its control waits for the Mac.
    private func isWaiting(for kind: String?) -> Bool {
        guard let kind else { return false }
        return mirror.waiting.values.contains { $0.editKind == kind }
    }

    func isBusy(_ action: EditAction) -> Bool { isWaiting(for: action.kind) }

    // MARK: The bar

    /// The editing bar's buttons, left to right. One button, Edit, while editing is off. None when this
    /// device may not act.
    var editBar: [EditBarItem] {
        guard abilities.canAct, let snapshot = mirror.snapshot else { return [] }
        guard isEditing else {
            return [EditBarItem(kind: .edit, title: "Edit", symbol: "pencil", hint: "Lets you move, add, link and delete cards from here.")]
        }
        let state = snapshot.edit
        return [
            EditBarItem(kind: .undo, title: state.undo ?? "Undo", symbol: "arrow.uturn.backward", isEnabled: state.undo != nil && !isBusy(.undo),
                        hint: "Undoes the last change to this flow, whoever made it."),
            EditBarItem(kind: .redo, title: state.redo ?? "Redo", symbol: "arrow.uturn.forward", isEnabled: state.redo != nil && !isBusy(.redo)),
            EditBarItem(kind: .add, title: "Add Card", symbol: "plus", isEnabled: !isWaiting(for: "addCard"),
                        hint: "Shows the kinds of card. The one you pick goes in the middle of the canvas."),
            EditBarItem(kind: .select, title: "Select", symbol: "rectangle.dashed", isOn: edit.isSelecting,
                        hint: edit.isSelecting ? "Stops selecting. What is selected stays selected."
                            : "Lets you drag a box round cards, and tap cards to add them to what is selected."),
            EditBarItem(kind: .tidy, title: "Tidy Up", symbol: "rectangle.3.group", isEnabled: !snapshot.flow.cards.isEmpty && !isBusy(.tidy),
                        hint: "Lays the flow out left to right in the order its links run."),
            EditBarItem(kind: .done, title: "Done", symbol: "checkmark", hint: "Stops editing."),
        ]
    }

    /// A button of the bar was pressed.
    func press(_ item: EditBarItem.Kind) {
        switch item {
        case .edit: setEditing(true)
        case .done: setEditing(false)
        case .select: edit.isSelecting.toggle()
        case .undo: Task { await act(.undo) }
        case .redo: Task { await act(.redo) }
        case .tidy: Task { await act(.tidy) }
        case .add: Task { await act(.showAdd(at: nil)) }
        }
    }

    // MARK: Menus

    /// The kinds of card that can be added, in the order of the Mac's own list.
    static let cardKinds: [CardKind] = [.agent, .start, .ifElse, .switchCard, .and, .or, .prompt, .loop, .approval, .script, .flow, .end, .note]

    /// What a long press on something offers. `point` is where on the canvas the finger is, for a card added there.
    func menu(for target: CanvasModel.Selection, at point: CGPoint? = nil) -> EditMenu? {
        guard isEditing, let flow = mirror.snapshot?.flow else { return nil }
        func item(_ title: String, _ symbol: String, _ action: EditAction, destructive: Bool = false) -> EditMenu.Item {
            EditMenu.Item(title: title, symbol: symbol, action: action, isDestructive: destructive, isEnabled: !isBusy(action))
        }
        switch target {
        case .card(let id):
            guard let card = flow.card(id) else { return nil }
            // A long press on one of several selected cards is about all of them, as a right-click is on the Mac.
            let picked = canvas.selection.cardIDs.contains(id) ? canvas.selection.cardIDs : [id]
            let ids = flow.cards.map(\.id).filter(picked.contains)
            var items: [EditMenu.Item] = []
            let can = abilities
            if ids.count > 1 {
                items.append(item("Group", "rectangle.dashed", .group(ids)))
            } else {
                // The Mac's card menu: a Start card runs from itself, a card the run stopped at is tried again.
                for button in [can.starts[id], can.retry[id]].compactMap({ $0 }) {
                    var press = item(button.title, button.press == .retry(cardID: id) ? "arrow.clockwise" : "play", .press(button.press))
                    press.isEnabled = button.isEnabled
                    items.append(press)
                }
                if can.runFrom.contains(id) { items.append(item("Run from here…", "play", .runFrom(id))) }
                if card.kind == .flow, CanvasContent.innerFlow(of: card, in: openFlow?.project.flows ?? [], excluding: flow.id) != nil {
                    items.append(item("Open Its Flow", "arrow.turn.down.right", .openSubflow(id)))
                }
            }
            items.append(item("Duplicate", "plus.square.on.square", .duplicate(ids)))
            items.append(item("Copy", "doc.on.doc", .copy(ids)))
            items.append(item("Cut", "scissors", .cut(ids)))
            items.append(item(ids.count > 1 ? "Delete \(ids.count) Cards" : "Delete", "trash", .delete(cards: ids, links: []), destructive: true))
            return EditMenu(title: ids.count > 1 ? "\(ids.count) cards" : card.name, items: items)
        case .cards:
            // A finger is only ever on one thing.
            return nil
        case .link(let id):
            guard let link = flow.links.first(where: { $0.id == id }) else { return nil }
            let from = flow.card(link.from)?.name ?? "a card", to = flow.card(link.to)?.name ?? "a card"
            return EditMenu(title: "Link from \(from) to \(to)", items: [item("Delete Link", "trash", .delete(cards: [], links: [id]), destructive: true)])
        case .group(let id):
            guard let group = (flow.groups ?? []).first(where: { $0.id == id }) else { return nil }
            let ids = flow.cards.map(\.id).filter(group.cardIDs.contains)
            return EditMenu(title: group.name, items: [
                item("Rename Group…", "pencil", .renameGroup(id, to: nil)),
                item(group.isFolded ? "Unfold" : "Fold into One Card", group.isFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical", .fold(id, !group.isFolded)),
                item("Ungroup", "rectangle.dashed", .ungroup(id)),
                item("Duplicate", "plus.square.on.square", .duplicate(ids)),
                item("Copy", "doc.on.doc", .copy(ids)),
                item("Delete \(ids.count) Cards", "trash", .delete(cards: ids, links: []), destructive: true),
            ])
        case .none:
            // Held on bare canvas, what the Mac's canvas menu offers comes first: Paste there, and Select All.
            var items: [EditMenu.Item] = []
            if let point {
                if edit.clipboard != nil { items.append(item("Paste", "doc.on.clipboard", .paste(at: point))) }
                if !flow.cards.isEmpty { items.append(item("Select All", "checklist", .selectAll)) }
            }
            return EditMenu(title: "Add Card", items: items + addItems(at: point))
        }
    }

    /// The kinds of card, in the order of the Mac's list, with the saved roles under Agent as the Mac's palette has them.
    func addItems(at point: CGPoint?) -> [EditMenu.Item] {
        let busy = isWaiting(for: "addCard")
        return Self.cardKinds.flatMap { kind -> [EditMenu.Item] in
            let plain = EditMenu.Item(title: kind.label, symbol: CanvasGeometry.icon(for: kind), action: .add(kind, at: point), isEnabled: !busy)
            guard kind == .agent else { return [plain] }
            return [plain] + (mirror.library?.roles ?? []).map { role in
                EditMenu.Item(title: role.name, symbol: "person.crop.square", action: .addRole(role.id, at: point), isEnabled: !busy, id: "role:\(role.id)")
            }
        }
    }

    /// The cards each of a card's outputs could be linked to, by the Mac's own rules for what takes a link.
    func linkMenu(from cardID: String) -> EditMenu? {
        guard isEditing, let flow = mirror.snapshot?.flow, let card = flow.card(cardID) else { return nil }
        let outputs = ports(of: card)
        var items: [EditMenu.Item] = []
        for port in outputs {
            for target in flow.cards where flow.linkProblem(from: cardID, port: port, to: target.id) == nil {
                // A card with one output needs no telling which.
                let title = outputs.count > 1 ? "\(portLabel(port)) to \(target.name)" : target.name
                items.append(EditMenu.Item(title: title, symbol: "arrow.right", action: .link(from: cardID, port: port, to: target.id),
                                           isEnabled: !isWaiting(for: "addLink")))
            }
        }
        return items.isEmpty ? nil : EditMenu(title: "Link \(card.name) to", items: items)
    }

    // MARK: Doing it

    static let notEditing = "Press Edit to change this flow from here."
    static let nothingToLink = "There is no card this one can be linked to."
    static let nothingToPaste = "There is nothing to paste. Copy or cut some cards first."

    /// Puts cards on this device's clipboard, as they are in the flow now, with the links and groups between them.
    private func copy(_ ids: [String], from flow: Flow) {
        let fragment = flow.fragment(of: Set(ids))
        guard !fragment.cards.isEmpty else { return }
        edit.clipboard = fragment
        UIAccessibility.post(notification: .announcement, argument: fragment.cards.count == 1 ? "Copied \(fragment.cards[0].name)." : "Copied \(fragment.cards.count) cards.")
    }

    /// Where to ask for pasted cards to go so that they sit round a canvas point: their top-left card's place.
    static func pastePlace(_ fragment: FlowFragment, around centre: CGPoint) -> CGPoint {
        let box = fragment.cards.map(CanvasGeometry.frame(of:)).reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull else { return centre }
        let left = fragment.cards.map(\.x).min() ?? box.minX, top = fragment.cards.map(\.y).min() ?? box.minY
        return CGPoint(x: max(20, centre.x - box.width / 2 + (left - box.minX)), y: max(20, centre.y - box.height / 2 + (top - box.minY)))
    }

    /// Does one thing that was asked for, and waits for the Mac. Returns nil when it was done, or is being
    /// asked about first, and otherwise why it wasn't: the Mac's own words, which also go in the notice
    /// over the canvas. `confirmed` is true once the person has said yes to what is asked first.
    @discardableResult
    func act(_ action: EditAction, confirmed: Bool = false) async -> String? {
        guard isEditing, let flow = mirror.snapshot?.flow else { return Self.notEditing }
        let flowID = flow.id
        // A choice was made, so the list it was made from goes.
        edit.menu = nil
        switch action {
        case .showAdd(let point):
            edit.menu = EditMenu(title: "Add Card", items: addItems(at: point))
            return nil
        case .copy(let ids):
            copy(ids, from: flow)
            return nil
        case .cut(let ids):
            copy(ids, from: flow)
            // The cards are on the clipboard, so nothing is lost, and nothing is asked: the Mac's Cut doesn't ask either.
            return await perform(command: .deleteItems(flowID: flowID, cardIDs: ids, linkIDs: []))
        case .paste(let point):
            guard let fragment = edit.clipboard else { return Self.nothingToPaste }
            let at = point ?? Self.pastePlace(fragment, around: canvas.view?.middleOfWhatShows ?? CGPoint(x: 400, y: 300))
            return await adding(to: flow) { await perform(command: .paste(flowID: flowID, fragment: fragment, at: RemotePoint(x: at.x, y: at.y))) }
        case .selectAll:
            canvas.select(.of(Set(flow.cards.map(\.id))))
            return nil
        case .addRole(let roleID, let point):
            let taken = flow.cards.map(CanvasGeometry.frame(of:))
            let place = point ?? TouchEdit.placeForNewCard(.agent, centre: canvas.view?.middleOfWhatShows ?? CGPoint(x: 400, y: 300), taken: taken,
                                                           titleHeight: CanvasGeometry.titleHeight)
            return await adding(to: flow) { await perform(command: .addRoleCard(flowID: flowID, roleID: roleID, x: place.x, y: place.y)) }
        case .press(let press):
            self.press(press)
            return nil
        case .openSubflow(let cardID):
            openSubflow(of: cardID)
            return nil
        case .showLinks(let cardID):
            guard let menu = linkMenu(from: cardID) else {
                controls.refusal = ControlRefusal(command: .addLink(flowID: flowID, from: cardID, port: "", to: ""), text: Self.nothingToLink)
                return Self.nothingToLink
            }
            edit.menu = menu
            return nil
        case .runFrom(let cardID):
            canvas.select(.card(cardID))
            panel.show(PanelPage.details)
            controls.runFrom = cardID
            return nil
        case .renameGroup(let id, nil):
            guard let group = (flow.groups ?? []).first(where: { $0.id == id }) else { return nil }
            edit.ask(.renameGroup(id: id, name: group.name), in: flowID)
            return nil

        case .add(let kind, let point):
            let taken = flow.cards.map(CanvasGeometry.frame(of:))
            let place = point ?? TouchEdit.placeForNewCard(kind, centre: canvas.view?.middleOfWhatShows ?? CGPoint(x: 400, y: 300), taken: taken,
                                                           titleHeight: CanvasGeometry.titleHeight)
            return await adding(to: flow) { await perform(command: .addCard(flowID: flowID, kind: kind, x: place.x, y: place.y)) }
        case .duplicate(let ids):
            return await adding(to: flow) { await perform(command: .duplicate(flowID: flowID, cardIDs: ids)) }
        case .delete(let cards, let links):
            // Deleting can be undone, on the Mac or from here. It is still asked about when it takes more than one thing.
            let linked = flow.links.filter { cards.contains($0.from) || cards.contains($0.to) }.count
            if !confirmed, cards.count + links.count > 1 || linked > 0 {
                let title = cards.count == 1 ? "Delete \(flow.card(cards[0])?.name ?? "this card")?"
                    : cards.isEmpty ? "Delete \(links.count) links?" : "Delete \(cards.count) cards?"
                let goes = linked == 0 ? "" : linked == 1 ? "The link to \(cards.count == 1 ? "it" : "them") goes too. " : "The \(linked) links to \(cards.count == 1 ? "it" : "them") go too. "
                edit.ask(.delete(cards: cards, links: links, title: title, message: goes + "You can undo this."), in: flowID)
                return nil
            }
            return await perform(command: .deleteItems(flowID: flowID, cardIDs: cards, linkIDs: links))
        case .group(let ids):
            return await perform(command: .group(flowID: flowID, cardIDs: ids, name: ""))
        case .ungroup(let id):
            return await perform(command: .ungroup(flowID: flowID, groupID: id))
        case .fold(let id, let folded):
            return await perform(command: .foldGroup(flowID: flowID, groupID: id, folded: folded))
        case .renameGroup(let id, let name?):
            return await perform(command: .renameGroup(flowID: flowID, groupID: id, name: name))
        case .link(let from, let port, let to):
            let refusal = await perform(command: .addLink(flowID: flowID, from: from, port: port, to: to))
            // The new link is selected, as it is on the Mac, once the Mac has sent it.
            if refusal == nil { edit.linkToSelect = (from, port, to) }
            return refusal
        case .nudge(let ids, let dx, let dy):
            let moves = Dictionary(uniqueKeysWithValues: flow.cards.filter { ids.contains($0.id) }.map { ($0.id, RemotePoint(x: $0.x + dx, y: $0.y + dy)) })
            // One step that is also the last: the Mac makes it one step of its Undo, as it does a whole drag.
            return await perform(command: .moveCards(flowID: flowID, moves: moves, final: true))
        case .undo:
            return await perform(command: .undo(flowID: flowID))
        case .redo:
            return await perform(command: .redo(flowID: flowID))
        case .tidy:
            let refusal = await perform(command: .tidy(flowID: flowID))
            if refusal == nil {
                // The Mac shows all of the flow once it is tidied, and so does this, once the tidied flow has come.
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if mirror.openFlowID == flowID { canvas.fit() }
                }
            }
            return refusal
        }
    }

    /// Sends a command that adds cards, and selects what it added once the Mac has sent it, as the Mac does.
    /// The Mac's answer says only that it was done, and comes before the flow with the new cards in it.
    private func adding(to flow: Flow, _ send: () async -> String?) async -> String? {
        let before = Set(flow.cards.map(\.id))
        let refusal = await send()
        guard refusal == nil else { return refusal }
        let new = Set((mirror.snapshot?.flow.cards ?? []).map(\.id)).subtracting(before)
        if new.isEmpty { edit.addsAwaited += 1 } else { canvas.select(.of(new)) }
        return nil
    }

    /// Called by the canvas whenever the Mac's flow may have changed. Selects the cards that have come since
    /// one was added or copied from here, and the link that was just made from here.
    func selectWhatWasAdded() {
        guard let flow = mirror.snapshot?.flow else { return }
        let cards = Set(flow.cards.map(\.id))
        if let seen = edit.seenCards, edit.addsAwaited > 0, isEditing {
            let new = cards.subtracting(seen)
            if !new.isEmpty {
                edit.addsAwaited -= 1
                canvas.select(.of(new))
            }
        }
        edit.seenCards = cards
        if let wanted = edit.linkToSelect, let link = flow.links.first(where: { $0.from == wanted.from && $0.port == wanted.port && $0.to == wanted.to }) {
            edit.linkToSelect = nil
            canvas.select(.link(link.id))
        }
    }

    /// The person said yes to what was asked. The answer goes to the flow the question was asked about, and
    /// nowhere if that flow is no longer the one open.
    func confirm(_ ask: EditAsk, name: String = "") {
        let flowID = edit.askedIn
        edit.asking = nil
        guard let flowID, flowID == mirror.openFlowID else { return }
        switch ask {
        case .delete(let cards, let links, _, _): Task { await act(.delete(cards: cards, links: links), confirmed: true) }
        case .renameGroup(let id, _): Task { await act(.renameGroup(id, to: name)) }
        case .saveRole(let cardID, _): Task { await saveRole(from: cardID, name: name) }
        case .newSubflow(let cardID, _): Task { await newSubflow(for: cardID, name: name) }
        case .deleteRole(let roleID, _): Task { await deleteRole(roleID) }
        }
    }

    // MARK: Drags

    /// The command that says where the cards under the finger are now.
    private func dragCommand(_ carried: EditModel.Carried, final: Bool) -> RemoteCommand? {
        switch carried.drag {
        case .move:
            let moves = carried.overlay.frames.mapValues { RemotePoint(x: $0.minX, y: $0.minY) }
            return moves.isEmpty ? nil : .moveCards(flowID: carried.flowID, moves: moves, final: final)
        case .resize(let cardID):
            guard let frame = carried.overlay.frames[cardID] else { return nil }
            return .resizeCard(flowID: carried.flowID, cardID: cardID,
                               frame: RemoteFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), final: final)
        }
    }

    /// The cards under the finger have moved. The Mac is told where they are, at most twenty times a second:
    /// a step that comes too soon is held back, and the latest place goes when its turn comes.
    func dragMoved() {
        guard let carried = edit.carried, !carried.isSettling else { return }
        if let wait = edit.throttle.wait(at: ProcessInfo.processInfo.systemUptime) {
            guard edit.trailing == nil else { return }
            edit.trailing = Task {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                edit.trailing = nil
                dragMoved()
            }
            return
        }
        if let command = dragCommand(carried, final: false) { sendStep(command) }
    }

    /// The finger has lifted. The last step goes to the Mac, which ends the drag there, and this waits for
    /// what the Mac says. Until then the cards stay where the finger left them. Then they are the Mac's:
    /// taken, they are drawn from the flow it sends, which may not be quite where they were left. Refused,
    /// or with the Mac gone or silent, they go back to where it has them, and its words are shown.
    @discardableResult
    func dragEnded() async -> String? {
        edit.dropGesture()
        guard let carried = edit.carried, !carried.isSettling, let id = edit.settle() else { return nil }
        guard let command = dragCommand(carried, final: true) else {
            edit.dropCarried(id)
            return nil
        }
        let refusal = await perform(command: command)
        if refusal == nil {
            edit.settled(id, on: mirror.snapshot?.flow, revision: mirror.revision)
        } else {
            edit.dropCarried(id)
        }
        return refusal
    }
}
