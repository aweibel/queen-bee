import Foundation
import QueenBeeCore
import UIKit

/// What the details and a card's menu offer besides its settings: a schedule turned on and off, a role saved,
/// brought up to date, put back or deleted, a sub-flow made or gone into, the log cleared and the message at the
/// top of the flow closed. Each is one of the Mac's own buttons and one command, which the Mac checks. What it
/// turns down is said in the notice over the canvas, as for every other control.
extension RemoteClient {
    /// Whether this very command has been sent and not yet answered. Its button waits for the Mac.
    func isSending(_ command: RemoteCommand) -> Bool { mirror.isWaiting(for: command) }

    /// The open flow's id, with the command made for it, when there is a flow open.
    private func forOpenFlow(_ make: (String) -> RemoteCommand) -> RemoteCommand? {
        mirror.snapshot.map { make($0.flow.id) }
    }

    // MARK: Schedules

    /// A Start card's "Turn on", or turning its schedule off and leaving it set.
    func armCommand(_ cardID: String, on: Bool) -> RemoteCommand? {
        forOpenFlow { .armSchedule(flowID: $0, cardID: cardID, on: on) }
    }

    @discardableResult
    func armSchedule(_ cardID: String, on: Bool) async -> String? {
        guard let command = armCommand(cardID, on: on) else { return Self.notConnected }
        return await perform(command: command)
    }

    // MARK: Roles

    /// The saved role a card has, when the Mac still has it.
    func role(of card: Card) -> RemoteRole? {
        guard let id = card.role, !id.isEmpty else { return nil }
        return mirror.library?.roles.first { $0.id == id }
    }

    /// "Reset": the card is given what its role holds again, as picking the role does.
    func resetCommand(_ cardID: String) -> RemoteCommand? {
        guard let card = mirror.snapshot?.flow.card(cardID), let role = role(of: card) else { return nil }
        var patch = RemoteCardPatch()
        patch.role = role.id
        return forOpenFlow { .patchCard(flowID: $0, cardID: cardID, patch: patch) }
    }

    @discardableResult
    func resetRole(_ cardID: String) async -> String? {
        guard isEditing, let command = resetCommand(cardID) else { return Self.notEditing }
        return await perform(command: command)
    }

    /// "Update role": the role takes this card's settings. No card changes.
    func updateRoleCommand(_ cardID: String) -> RemoteCommand? {
        guard let card = mirror.snapshot?.flow.card(cardID), let role = role(of: card) else { return nil }
        return forOpenFlow { .updateRole(roleID: role.id, flowID: $0, cardID: cardID) }
    }

    @discardableResult
    func updateRole(from cardID: String) async -> String? {
        guard isEditing, let command = updateRoleCommand(cardID) else { return Self.notEditing }
        return await perform(command: command)
    }

    /// "Save as a New Role…": the name is asked first, and may be left empty for the card's own.
    func askToSaveRole(from cardID: String) {
        guard isEditing, let flowID = mirror.openFlowID, let card = mirror.snapshot?.flow.card(cardID) else { return }
        edit.ask(.saveRole(cardID: cardID, name: card.name), in: flowID)
    }

    @discardableResult
    func saveRole(from cardID: String, name: String) async -> String? {
        guard isEditing, let flowID = mirror.openFlowID else { return Self.notEditing }
        return await perform(command: .saveRole(flowID: flowID, cardID: cardID, name: String(Remote.plainLine(name).prefix(Remote.nameLimit))))
    }

    /// A saved role is deleted on the Mac, from every flow's list of roles. It is asked first, by its name.
    func askToDeleteRole(_ roleID: String) {
        guard isEditing, let flowID = mirror.openFlowID, let role = mirror.library?.roles.first(where: { $0.id == roleID }) else { return }
        edit.ask(.deleteRole(roleID: roleID, name: role.name), in: flowID)
    }

    @discardableResult
    func deleteRole(_ roleID: String) async -> String? {
        guard isEditing else { return Self.notEditing }
        return await perform(command: .deleteRole(roleID: roleID))
    }

    // MARK: Sub-flows

    /// The flow a Flow card runs, as the Mac lists it.
    func innerFlow(of cardID: String) -> RemoteFlowSummary? {
        guard let flow = mirror.snapshot?.flow, let card = flow.card(cardID), card.kind == .flow else { return nil }
        return CanvasContent.innerFlow(of: card, in: openFlow?.project.flows ?? [], excluding: flow.id)
    }

    /// "Open" on a Flow card: the flow it runs takes the canvas's place. Watching it changes nothing on the Mac.
    func openSubflow(of cardID: String) {
        guard let inner = innerFlow(of: cardID) else { return }
        open(inner.id)
    }

    /// A Flow card's "New sub-flow": the name is asked first, and may be left empty for the card's own.
    func askForNewSubflow(for cardID: String) {
        guard isEditing, let flowID = mirror.openFlowID, let card = mirror.snapshot?.flow.card(cardID) else { return }
        edit.ask(.newSubflow(cardID: cardID, name: card.name), in: flowID)
    }

    /// Makes a sub-flow with an Input and an Output, which the card then runs. The Mac doesn't go into it, and
    /// neither does this: it is there to open from the card.
    @discardableResult
    func newSubflow(for cardID: String, name: String) async -> String? {
        guard isEditing, let flowID = mirror.openFlowID else { return Self.notEditing }
        return await perform(command: .newSubflow(flowID: flowID, cardID: cardID, name: String(Remote.plainLine(name).prefix(Remote.nameLimit))))
    }

    // MARK: The log and the message at the top

    /// The log's Clear: the log and the list of earlier runs are emptied on the Mac. Asked first, in the log.
    func clearLogCommand() -> RemoteCommand? { forOpenFlow { .clearLog(flowID: $0) } }

    /// Whether the log's Clear is on offer: the latest run is on show, there is something to clear, and this device may act.
    var canClearLog: Bool { abilities.canAct && !(mirror.snapshot?.log.isEmpty ?? true) }

    @discardableResult
    func clearLog() async -> String? {
        guard let command = clearLogCommand() else { return Self.notConnected }
        return await perform(command: command)
    }

    func dismissBannerCommand() -> RemoteCommand? { forOpenFlow { .dismissBanner(flowID: $0) } }

    /// Closes the message at the top of the flow, on the Mac as well as here.
    @discardableResult
    func dismissBanner() async -> String? {
        guard let command = dismissBannerCommand() else { return Self.notConnected }
        return await perform(command: command)
    }

    // MARK: The empty flow's note

    /// What an empty flow says over its canvas, as the Mac's note beside the orchestrator does. Nil when the
    /// flow has cards, or the note has been put away here.
    var callout: Callout? {
        guard let snapshot = mirror.snapshot, snapshot.flow.cards.isEmpty, !canvas.calloutPutAway.contains(snapshot.flow.id) else { return nil }
        let state = snapshot.run.sessions[Remote.orchestratorKey] ?? .notStarted
        let isOff = state == .notStarted || state == .exited
        let can = abilities
        return Callout(text: isOff ? "The orchestrator builds it on the canvas, but it isn't running yet."
                                   : "Tell the orchestrator and it builds it here. Or add cards yourself.",
                       start: isOff && can.canAct ? can.orchestrator : nil, canBuild: can.canAct)
    }

    /// "Build it by hand": the note is put away, and with control, editing starts with the list of cards to add.
    func buildByHand() {
        guard let flowID = mirror.openFlowID else { return }
        canvas.calloutPutAway.insert(flowID)
        guard abilities.canAct else { return }
        setEditing(true)
        Task { await act(.showAdd(at: nil)) }
    }

    /// "Start the orchestrator": started on the Mac, and its panel turned to.
    func startOrchestratorFromCallout() {
        press(.startOrchestrator)
        panel.show(PanelPage.orchestrator)
    }
}

/// The note an empty flow shows: what to do, and the buttons that do it.
nonisolated struct Callout: Equatable {
    static let title = "Describe the flow you want"
    var text: String
    /// "Start the orchestrator", while it isn't running and this device may start it.
    var start: PressButton?
    /// "Build it by hand" turns editing on as well as putting the note away.
    var canBuild: Bool
}

extension EditForm {
    /// What the Mac's "Not in use yet" line says, from the names of the settings that are waiting.
    nonisolated static func notInUseYet(_ names: [String]) -> String {
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names.first ?? ""
        return "Not in use yet. The agent keeps working with its old \(list) until you restart it."
    }

    nonisolated static let roleDrift = "Changed since the role was saved."
    nonisolated static let browserLine = "Gives this agent a web browser in its card. You can watch what it does there and use the browser yourself on your Mac. "
        + "The agent can look at pages freely, and asks before it clicks or types unless its permissions say otherwise."
}
