import QueenBeeCore
import SwiftUI

/// The parts of a card's details that are buttons more than settings, as the Mac's settings panel has them: a
/// schedule turned on or off, a role saved, brought up to date, put back or deleted, and a sub-flow made or gone
/// into. Each sends one command, and waits for the Mac's answer before it can be pressed again.

/// "Turn on" or "Turn off" for a Start card's schedule. The lines above it say whether it is on and when it next runs.
struct ScheduleSwitch: View {
    @Environment(RemoteClient.self) private var client
    let cardID: String
    let isOn: Bool

    var body: some View {
        let command = client.armCommand(cardID, on: !isOn)
        HStack(spacing: Theme.Space.s) {
            Text(isOn ? "Runs by itself while it is on." : "Turned on here, it runs by itself, with nobody watching.")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button(isOn ? "Turn off" : "Turn on") { Task { await client.armSchedule(cardID, on: !isOn) } }
                .buttonStyle(.panel(isOn ? .outline : .live))
                .fixedSize()
                .disabled(command.map(client.isSending) ?? true)
                .accessibilityHint(isOn ? "Turns the schedule off on your Mac. It stays set, to turn on again."
                                        : "Turns the schedule on on your Mac, for the flow as it is now.")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Touch.target)
    }
}

/// A Flow card's way into the flow it runs.
struct SubflowRow: View {
    @Environment(RemoteClient.self) private var client
    let cardID: String
    let inner: RemoteFlowSummary

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Runs \(inner.name).").dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
            Spacer(minLength: Theme.Space.s)
            Button("Open") { client.openSubflow(of: cardID) }
                .buttonStyle(.panel())
                .fixedSize()
                .accessibilityLabel("Open \(inner.name)")
                .accessibilityHint("Shows the flow this card runs on the canvas. Back to this flow is over the canvas there.")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Touch.target)
    }
}

/// A Flow card that runs nothing yet: the Mac's "New sub-flow", which asks the new flow's name first.
struct NewSubflowRow: View {
    @Environment(RemoteClient.self) private var client
    let cardID: String

    var body: some View {
        let busy = client.mirror.waiting.values.contains { if case .newSubflow(_, cardID, _) = $0 { true } else { false } }
        HStack(spacing: Theme.Space.s) {
            Text("Make a sub-flow just for this card:").dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
            Spacer(minLength: Theme.Space.s)
            Button("New sub-flow") { client.askForNewSubflow(for: cardID) }
                .buttonStyle(.panel(.filled))
                .fixedSize()
                .disabled(busy)
                .accessibilityHint("Asks for a name, then makes a flow with an Input and an Output on your Mac for this card to run.")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Touch.target)
    }
}

/// The Mac's line under an agent's role when the card has drifted from it, with its two ways back together.
struct RoleDriftRow: View {
    @Environment(RemoteClient.self) private var client
    let cardID: String

    var body: some View {
        let reset = client.resetCommand(cardID), update = client.updateRoleCommand(cardID)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) {
                line
                Spacer(minLength: Theme.Space.s)
                buttons(reset: reset, update: update)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                line
                HStack(spacing: Theme.Space.s) {
                    Spacer(minLength: 0)
                    buttons(reset: reset, update: update)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }

    private var line: some View {
        Text(EditForm.roleDrift).dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func buttons(reset: RemoteCommand?, update: RemoteCommand?) -> some View {
        Button("Reset") { Task { await client.resetRole(cardID) } }
            .buttonStyle(.panel(.quiet))
            .fixedSize()
            .disabled(reset.map(client.isSending) ?? true)
            .accessibilityHint("Puts this card back to what the role holds.")
        Button("Update role") { Task { await client.updateRole(from: cardID) } }
            .buttonStyle(.panel())
            .fixedSize()
            .disabled(update.map(client.isSending) ?? true)
            .accessibilityHint("Saves this card's settings into the role. Other agents with the role take them when Reset is chosen on them.")
    }
}

/// An agent's role, as the Mac's menu has it: the roles to pick from, or None, then "Save as a New Role…" for a card
/// with no role, or "Update “X” from This Card" for one that has one, and the way to delete that role.
struct RoleMenu: View {
    @Environment(RemoteClient.self) private var client
    let field: EditField
    let choices: [EditField.Choice]

    var body: some View {
        let picked = client.shown(field).text
        let cardID: String? = if case .card(let id) = field.key.item { id } else { nil }
        let role = (client.mirror.library?.roles ?? []).first { $0.id == picked && !picked.isEmpty }
        let chosen = choices.first { $0.value == picked }?.label ?? (picked.isEmpty ? "None" : picked)
        Menu {
            Picker("Role", selection: Binding { picked } set: { new in Task { await client.setField(field.key, .text(new)) } }) {
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
            }
            if let cardID {
                Divider()
                if let role {
                    Button("Update “\(role.name)” from This Card") { Task { await client.updateRole(from: cardID) } }
                    Button("Delete “\(role.name)”…", role: .destructive) { client.askToDeleteRole(role.id) }
                } else {
                    Button("Save as a New Role…") { client.askToSaveRole(from: cardID) }
                }
            }
        } label: {
            HStack(spacing: Theme.Space.xs + 2) {
                Text(chosen).dsSans(Theme.Touch.body, .medium).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkSecondary.ui)
            }
            .foregroundStyle(Theme.ink.ui)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 36)
            .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
            .frame(minHeight: Theme.Touch.target)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Role")
        .accessibilityValue(chosen)
        .accessibilityHint("Picks a saved role, or saves this card as one.")
    }
}
