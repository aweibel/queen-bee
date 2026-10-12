import Foundation
import QueenBeeCore
import UIKit

/// Changing settings from this device, and making, renaming and deleting flows. A setting is written here
/// and the Mac is told when it is left, or after a pause in the writing: never on every key. As with every
/// other edit, the Mac checks it, makes it, and what it made comes back with the flow.
extension RemoteClient {
    // MARK: What the details offer

    /// The details of what is selected, as settings that can be changed. Nil when editing is off, or nothing
    /// that has settings is selected.
    var editForm: EditForm? {
        guard isEditing, let snapshot = mirror.snapshot else { return nil }
        return EditForm(selection: canvas.selection, snapshot: snapshot, run: RunOnShow(snapshot, viewed: canvas.viewedRun),
                        siblings: openFlow?.project.flows ?? [], roles: mirror.library?.roles ?? [])
    }

    /// The flow's own settings, when this device may change them.
    var flowFields: [EditField] {
        guard abilities.canAct, let flow = mirror.snapshot?.flow else { return [] }
        return EditForm.flowFields(flow)
    }

    /// What the foot of the details says about editing, and the button beside it, if there is one: Edit, or
    /// Done. Nothing when this device may not edit and has nothing of the person's to speak of.
    var editFoot: (text: String, button: String?)? {
        guard mirror.snapshot != nil else { return nil }
        let isKeeping = settings.fields.contains { $0.key.flowID == mirror.openFlowID && $0.value.draft != nil }
        guard abilities.canAct else { return isKeeping ? (EditForm.keptAway, nil) : nil }
        if isEditing { return (EditForm.editing, "Done") }
        return (isKeeping ? EditForm.keptLine : EditForm.pressEdit, "Edit")
    }

    /// What a setting shows: what was written here, or what the Mac has.
    func shown(_ field: EditField) -> FieldValue { settings.fields[field.key]?.shown ?? field.mac }

    func fieldState(_ key: FieldKey) -> FieldEdit<FieldValue>.State { settings.fields[key]?.state ?? .untouched }

    /// What the Mac has in a setting of the open flow now.
    private func macValue(_ key: FieldKey) -> FieldValue? {
        guard let flow = mirror.snapshot?.flow, flow.id == key.flowID else { return nil }
        return key.macValue(in: flow, siblings: openFlow?.project.flows ?? [])
    }

    /// Whether a setting may be written in from here now. The flow's own settings need no Edit pressed:
    /// they are on a sheet of their own, which is its own way in.
    private func mayChange(_ key: FieldKey) -> Bool {
        key.flowID == mirror.openFlowID && (key.item == .flow ? abilities.canAct : isEditing)
    }

    // MARK: Writing and sending

    /// The keyboard has moved from one setting to another, or left. The one it left is sent.
    func focusMoved(from old: FieldKey?, to new: FieldKey?) {
        guard old != new else { return }
        if let old {
            settings.update(old) { $0.setFocus(false) }
            Task { await commitField(old) }
        }
        if let new, mayChange(new) { settings.update(new, mac: macValue(new)) { $0.setFocus(true) } }
    }

    /// The person changed what is in a setting. Nothing is sent: a long text is sent a moment after the
    /// writing stops, and everything else when `commitField` is called for it. False when the setting can't
    /// be written in from here now.
    @discardableResult
    func writeField(_ key: FieldKey, _ value: FieldValue) -> Bool {
        guard mayChange(key) else { return false }
        settings.update(key, mac: macValue(key)) { $0.write(key.capped(value)) }
        settings.pauses.removeValue(forKey: key)?.cancel()
        guard key.isLong, settings.fields[key]?.needsSending == true else { return true }
        settings.pauses[key] = Task {
            try? await Task.sleep(for: SettingsModel.pause)
            guard !Task.isCancelled else { return }
            settings.pauses[key] = nil
            // Still being written in, so nothing is tidied away from under the cursor.
            await commitField(key, final: settings.fields[key]?.hasFocus != true)
        }
        return true
    }

    /// Tells the Mac what a setting now is, and waits for what it says. Returns nil when it was taken, or
    /// there was nothing to send, and otherwise the Mac's words, which stay beside the setting. The shared
    /// notice over the canvas is left alone: what was refused is said where it was written.
    @discardableResult
    func commitField(_ key: FieldKey, final: Bool = true) async -> String? {
        if final { settings.pauses.removeValue(forKey: key)?.cancel() }
        var value: FieldValue?
        settings.update(key) { field in
            if let draft = field.draft, field.state != .sending { field.write(key.cleaned(draft, final: final)) }
            value = field.send()
        }
        guard let value, let command = key.command(value) else { return nil }
        let refusal = await send(command)
        settings.update(key) { $0.answered(refusal, unreachable: refusal == Self.notConnected) }
        if let refusal {
            // Said aloud too: the words are beside a field that VoiceOver may have left.
            UIAccessibility.post(notification: .announcement, argument: refusal)
        }
        // More was written while that was on its way, and nothing else is going to send it.
        if let field = settings.fields[key], field.needsSending, !field.hasFocus, settings.pauses[key] == nil {
            return await commitField(key)
        }
        return refusal
    }

    /// A choice was made, a number stepped or a switch thrown: written and sent at once.
    @discardableResult
    func setField(_ key: FieldKey, _ value: FieldValue) async -> String? {
        guard mayChange(key) else { return Self.notEditing }
        writeField(key, value)
        return await commitField(key)
    }

    /// Sends what was kept because the Mac couldn't be reached, or was refused, as it is.
    func sendAgain(_ key: FieldKey) {
        Task { await commitField(key) }
    }

    /// Goes back to what the Mac has.
    func discardField(_ key: FieldKey) {
        settings.pauses.removeValue(forKey: key)?.cancel()
        settings.update(key) { $0.discard() }
    }

    /// Sends everything that was written and not sent, and takes the keyboard out of every setting. Called
    /// when the selection changes, when Done is pressed, and when editing turns itself off. What can't go
    /// because the Mac is away is kept, marked as not saved.
    func flushFields() {
        for (key, field) in settings.fields {
            if field.hasFocus { settings.update(key) { $0.setFocus(false) } }
            if field.needsSending { Task { await commitField(key) } }
        }
    }

    /// The Mac's copy of the open flow has arrived. Every setting that isn't being written in follows it, and
    /// one whose card, link or group has gone is forgotten.
    func fieldsFollowMac() {
        guard let flow = mirror.snapshot?.flow else { return }
        for key in settings.fields.keys where key.flowID == flow.id {
            if let value = macValue(key) {
                settings.update(key) { $0.macHas(value) }
            } else {
                settings.forget(key)
            }
        }
    }

    // MARK: Flows

    /// Whether flows can be made, renamed and deleted from here. A courtesy, as ever: the Mac checks.
    var canChangeFlows: Bool { mirror.canControl && state == .connected }

    /// What a flow's row offers when a finger is held on it. Nothing when this device may only watch.
    func flowMenu(for flow: RemoteFlowSummary) -> [FlowMenuItem] {
        guard canChangeFlows else { return [] }
        var items = [FlowMenuItem(kind: .rename, title: "Rename…", symbol: "pencil")]
        // The flow's own settings are read from the flow, which the device only has for the one that is open.
        if flow.id == mirror.snapshot?.flow.id, abilities.canAct {
            items.append(FlowMenuItem(kind: .settings, title: "Flow Settings…", symbol: "slider.horizontal.3"))
        }
        items.append(FlowMenuItem(kind: .delete, title: "Delete…", symbol: "trash"))
        return items
    }

    /// A choice from a flow's menu. Renaming and deleting are asked about first.
    func choose(_ item: FlowMenuItem.Kind, for flow: RemoteFlowSummary) {
        settings.flowMenu = nil
        switch item {
        case .rename: settings.asking = .rename(flowID: flow.id, name: flow.name)
        case .delete: settings.asking = .delete(flowID: flow.id, name: flow.name)
        case .settings: showFlowSettings()
        }
    }

    func showFlowSettings() {
        guard abilities.canAct, mirror.snapshot != nil else { return }
        settings.showsFlowSettings = true
    }

    /// The + beside a project's name.
    func askForNewFlow(in project: RemoteProject) {
        guard canChangeFlows else { return }
        settings.flowMenu = nil
        settings.asking = .new(projectID: project.id, project: project.name)
    }

    /// The person answered what was asked about a flow.
    func confirm(_ ask: FlowAsk, name: String = "") {
        settings.asking = nil
        Task {
            switch ask {
            case .new(let projectID, _): await newFlow(in: projectID, name: name)
            case .rename(let flowID, _): await renameFlow(flowID, to: name)
            case .delete(let flowID, _): await deleteFlow(flowID)
            }
        }
    }

    /// Every command about a flow in the list goes through here, so what the Mac turned down is said over
    /// the list, in its words, and goes when the next one works.
    private func flowCommand(_ command: RemoteCommand) async -> String? {
        let refusal = await send(command)
        settings.refusal = refusal
        if let refusal { UIAccessibility.post(notification: .announcement, argument: refusal) }
        return refusal
    }

    /// Makes a flow in a project that is in the Mac's sidebar. With no name the Mac gives it one. It is
    /// opened here when the Mac lists it.
    @discardableResult
    func newFlow(in projectID: String, name: String) async -> String? {
        let known = Set(mirror.library?.projects.first { $0.id == projectID }?.flows.map(\.id) ?? [])
        let wanted = String(Remote.plainLine(name).prefix(Remote.nameLimit))
        let refusal = await flowCommand(.newFlow(projectID: projectID, name: wanted))
        if refusal == nil {
            settings.awaitingNew = NewFlowAwaited(projectID: projectID, known: known, name: Remote.plainLine(wanted), answered: Date())
            openNewFlow()
        }
        return refusal
    }

    @discardableResult
    func renameFlow(_ flowID: String, to name: String) async -> String? {
        await flowCommand(.renameFlow(flowID: flowID, name: String(Remote.plainLine(name).prefix(Remote.nameLimit))))
    }

    /// Deletes a flow and its file on the Mac. Already asked about, by the flow's name.
    @discardableResult
    func deleteFlow(_ flowID: String) async -> String? {
        let refusal = await flowCommand(.deleteFlow(flowID: flowID))
        // The flow on the canvas is the one that went.
        if refusal == nil, mirror.openFlowID == flowID { open(nil) }
        return refusal
    }

    /// The Mac's list of flows has arrived. A flow that was asked for from here a moment ago and is now in it
    /// is opened. One that turns up later, or under another name, is somebody else's and is left alone.
    func openNewFlow() {
        guard let awaited = settings.awaitingNew else { return }
        guard !awaited.isOver() else { return settings.awaitingNew = nil }
        guard let project = mirror.library?.projects.first(where: { $0.id == awaited.projectID }), let made = awaited.flow(among: project.flows) else { return }
        settings.awaitingNew = nil
        open(made.id)
    }
}
