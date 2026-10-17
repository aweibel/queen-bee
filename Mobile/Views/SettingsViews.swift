import QueenBeeCore
import SwiftUI

/// The details while a flow is being edited: each setting as something that can be changed, drawn from
/// `EditForm`. What is offered is decided there and in `Settings.swift`. These are the controls, made big
/// enough for a finger and drawn as the rest of the app is.

/// Where the keyboard is: in which setting, and for a setting with several boxes, in which of them.
nonisolated struct FieldFocus: Hashable, Sendable {
    var key: FieldKey
    /// A Switch card's branch by its place, or 0.
    var part = 0
}

/// One card, link, group or set of cards, with its settings open to change.
struct EditDetails: View {
    @Environment(RemoteClient.self) private var client
    let form: EditForm
    /// The card, when it is a card that is selected.
    let card: Card?
    let flow: Flow
    let run: RunOnShow
    let abilities: Abilities
    var focus: FocusState<FieldFocus?>.Binding

    /// The message held at this card, when it is one this device may answer.
    private var hold: PendingHold? {
        guard let card, abilities.cards[card.id] != nil else { return nil }
        return run.holds.first { $0.cardID == card.id && ($0.kind == .approval || $0.needsAllow) }
    }

    private var inTerminal: Card? {
        guard let card, abilities.inTerminal.contains(card.id), client.terminals.sizes[card.id] != nil else { return nil }
        return card
    }

    /// The boxes the keyboard goes to in turn, top to bottom.
    private var order: [FieldFocus] {
        form.fields.flatMap { field -> [FieldFocus] in
            switch field.control {
            case .line, .text: [FieldFocus(key: field.key)]
            case .branches: client.shown(field).list.indices.map { FieldFocus(key: field.key, part: $0) }
            case .schedule: client.shown(field).schedule?.kind == .file ? [FieldFocus(key: field.key)] : []
            case .choice, .stepper, .toggle: []
            }
        }
    }

    var body: some View {
        let order = order
        VStack(alignment: .leading, spacing: 0) {
            DetailsHeader(icon: form.icon, title: form.title, kind: form.kind, state: form.state)
            ForEach(Array(form.rows.enumerated()), id: \.offset) { _, row in
                Hairline()
                switch row {
                case .field(let field):
                    SettingField(field: field, label: label(for: field), placeholder: placeholder(for: field), order: order, focus: focus)
                case .item(let item):
                    ItemView(item: item, answerLine: form.answerLine ? abilities.answerLine ?? WaitingCard.answer : nil,
                             hold: hold, buttons: hold.flatMap { abilities.cards[$0.cardID] } ?? [], inTerminal: inTerminal,
                             retry: card.flatMap { abilities.retry[$0.id] })
                case .folder(let folder):
                    FolderRow(folder: folder)
                case .open(let flowID, let name):
                    HStack(spacing: Theme.Space.s) {
                        Text("Build or change what it does:").dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
                        Spacer(minLength: Theme.Space.s)
                        Button("Open") { client.open(flowID) }
                            .buttonStyle(.panel())
                            .accessibilityLabel("Open \(name)")
                            .accessibilityHint("Shows that flow on the canvas, and stops editing this one.")
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                case .newSubflow(let cardID):
                    NewSubflowRow(cardID: cardID)
                case .roleDrift(let cardID):
                    RoleDriftRow(cardID: cardID)
                case .arm(let cardID, let isOn):
                    ScheduleSwitch(cardID: cardID, isOn: isOn)
                }
            }
            if let messages = form.messages {
                Hairline()
                MessageList(title: form.messagesTitle, messages: messages)
            }
            if let card {
                let start = CardActions.buttons(for: card, in: abilities)
                if !start.isEmpty || abilities.runFrom.contains(card.id) {
                    Hairline()
                    CardActions(card: card, buttons: start, canRunFrom: abilities.runFrom.contains(card.id),
                                lastMessage: flow.links(into: card.id).compactMap { run.messages[$0.id]?.last }.max { $0.date < $1.date }?.text ?? "")
                }
            }
            if !form.actions.isEmpty {
                Hairline()
                FormActions(actions: form.actions)
            }
        }
    }

    /// An If or Loop card's text is named for how it checks, as on the Mac: by the check on show, which
    /// may be one just picked here.
    private func check(for field: EditField) -> CheckKind? {
        guard field.key.name == .value, let check = form.fields.first(where: { $0.key.name == .check }) else { return nil }
        return CheckKind(rawValue: client.shown(check).text)
    }

    private func label(for field: EditField) -> String { check(for: field).map(EditForm.valueLabel) ?? field.label }
    private func placeholder(for field: EditField) -> String? { check(for: field).map(EditForm.valuePlaceholder) }
}

/// What the details are of: its kind's symbol, its name, and its kind or its session's state.
struct DetailsHeader: View {
    let icon: String
    let title: String
    let kind: String
    let state: SessionState?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink.ui)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .dsMono(Theme.Touch.title, .medium)
                .foregroundStyle(Theme.ink.ui)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.s)
            if let state {
                Badge(text: state.label.lowercased(), tone: state.tone)
            } else {
                Text(kind).dsMono(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
        .background(Theme.bar.ui)
        .accessibilityElement(children: .combine)
    }
}

/// An agent's folder. It is picked with the Mac's folder panel and nowhere else, so here it is only shown.
private struct FolderRow: View {
    let folder: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text("Folder").dsSans().foregroundStyle(Theme.inkSecondary.ui)
                Spacer(minLength: Theme.Space.s)
                Text(folder).dsMono(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui).multilineTextAlignment(.trailing)
            }
            Text(EditForm.folderLine).dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What can be done to what is selected, at the foot of its details: the Mac's panel has the same buttons.
private struct FormActions: View {
    @Environment(RemoteClient.self) private var client
    let actions: [FormAction]

    var body: some View {
        let safe = actions.filter { !$0.isDestructive }, lost = actions.filter(\.isDestructive)
        // On one line where every name fits whole. Where they don't, what deletes has a line to itself.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) {
                ForEach(lost) { button($0) }
                Spacer(minLength: 0)
                ForEach(safe) { button($0) }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Spacer(minLength: 0)
                    ForEach(safe) { button($0) }
                }
                ForEach(lost) { button($0) }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }

    private func button(_ action: FormAction) -> some View {
        Button {
            Task { await client.act(action.action) }
        } label: {
            if let symbol = action.symbol { Label(action.title, systemImage: symbol) } else { Text(action.title) }
        }
        .buttonStyle(.panel(action.isDestructive ? .danger : .outline))
        .disabled(client.isBusy(action.action))
        .fixedSize()
    }
}

// MARK: One setting

/// One setting, drawn for the kind of control it is, with what has become of it underneath.
struct SettingField: View {
    @Environment(RemoteClient.self) private var client
    let field: EditField
    /// The Mac's name for it, when that isn't always the same.
    var label: String?
    var placeholder: String?
    /// The boxes the keyboard goes to in turn, so Return can move on.
    var order: [FieldFocus] = []
    var focus: FocusState<FieldFocus?>.Binding

    private var name: String { label ?? field.label }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch field.control {
            case .line(let fallback, let lines):
                block { TextBox(field: field, label: name, placeholder: placeholder ?? fallback, lines: 1...lines, order: order, focus: focus) }
            case .text(let fallback, let isMono):
                block { TextBox(field: field, label: name, placeholder: placeholder ?? fallback, lines: 3...12, isMono: isMono, order: order, focus: focus) }
            case .choice(let choices) where field.key.name == .role:
                SettingRow(title: name) { RoleMenu(field: field, choices: choices) }
            case .choice(let choices):
                SettingRow(title: name) {
                    ChoiceMenu(title: name, choices: choices, selection: client.shown(field).text) { picked in
                        Task { await client.setField(field.key, .text(picked)) }
                    }
                }
            case .stepper(let range, let unit, let units):
                SettingRow(title: name) {
                    StepControl(title: name, value: client.shown(field).number, range: range, unit: unit, units: units) { number in
                        Task { await client.setField(field.key, .number(number)) }
                    }
                }
            case .toggle:
                SettingRow(title: name) {
                    OnOffSwitch(title: name, isOn: client.shown(field).flag) { on in
                        Task { await client.setField(field.key, .flag(on)) }
                    }
                }
            case .branches:
                BranchesField(field: field, order: order, focus: focus)
            case .schedule:
                ScheduleField(field: field, order: order, focus: focus)
            }
            FieldStatus(field: field)
        }
    }

    /// A setting that is text: its name over its box.
    private func block<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(name).dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui).accessibilityHidden(true)
            content()
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
    }
}

/// A one-line setting: what it is on the left, its control on the right. Where the two don't fit side by
/// side, as with a long name in a narrow column, the control goes under its name, and neither is squeezed.
private struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        let name = Text(title).dsSans().foregroundStyle(Theme.inkSecondary.ui).accessibilityHidden(true)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) {
                name.fixedSize()
                Spacer(minLength: Theme.Space.s)
                content.fixedSize()
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                name.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    content
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: Theme.Touch.target + Theme.Space.s)
    }
}

/// What has become of what was written in a setting: on its way, turned down in the Mac's words, or kept
/// because the Mac couldn't be reached. And how near its limit it is, once it is near. Nothing for a
/// setting that is as the Mac has it.
struct FieldStatus: View {
    @Environment(RemoteClient.self) private var client
    let field: EditField

    /// How near the limit a text has to be before its length is shown.
    static func isNearLimit(_ count: Int, _ limit: Int) -> Bool { count >= limit - max(20, limit / 20) }

    /// The words for a state, for the screen and for a test. Nil when there is nothing to say.
    static func words(_ state: FieldEdit<FieldValue>.State) -> String? {
        switch state {
        case .untouched: nil
        case .edited: "Not sent yet."
        case .sending: "Sending…"
        case .refused(let words): words
        case .unsaved: "Not saved yet. Your Mac can't be reached."
        }
    }

    var body: some View {
        let state = client.fieldState(field.key), count = client.shown(field).count
        let counted = field.key.limit.flatMap { Self.isNearLimit(count, $0) ? "\(count) of \($0) characters" : nil }
        if state != .untouched || counted != nil {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let counted {
                    Text(counted).dsMono(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui)
                }
                switch state {
                case .untouched:
                    EmptyView()
                case .edited, .sending:
                    Text(Self.words(state) ?? "").dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
                case .refused(let words):
                    kept(words, symbol: "exclamationmark.triangle", tone: Theme.failInk, tint: Theme.failTint, again: "Try Again")
                case .unsaved:
                    kept(Self.words(state) ?? "", symbol: "wifi.slash", tone: Theme.liveInk, tint: Theme.liveTint, again: "Send Again")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.s)
        }
    }

    /// What was written is still in the field. It can be sent again as it is, or put back to what the Mac has.
    private func kept(_ words: String, symbol: String, tone: UIColor, tint: UIColor, again: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label(words, systemImage: symbol)
                .dsSans(Theme.Touch.caption + 1, .medium)
                .foregroundStyle(tone.ui)
                .fixedSize(horizontal: false, vertical: true)
            Text("What you wrote is kept.").dsSans(Theme.Touch.caption + 1).foregroundStyle(tone.ui)
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Button("Put Back") { client.discardField(field.key) }
                    .buttonStyle(.panel(.quiet))
                    .fixedSize()
                    .accessibilityHint("Goes back to what your Mac has.")
                Button(again) { client.sendAgain(field.key) }.buttonStyle(.panel()).fixedSize()
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(tint.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .contain)
    }
}

// MARK: Controls

/// A box of text. Its text is the setting's own, kept outside the view, so it is still there when the card
/// is selected again. One line or a few, Return moves on to the next box. Many lines, Return is a new line.
private struct TextBox: View {
    @Environment(RemoteClient.self) private var client
    let field: EditField
    let label: String
    let placeholder: String
    let lines: ClosedRange<Int>
    var isMono = false
    let order: [FieldFocus]
    var focus: FocusState<FieldFocus?>.Binding

    private var mine: FieldFocus { FieldFocus(key: field.key) }

    var body: some View {
        let isLong = field.key.isLong
        let text = Binding<String> {
            client.shown(field).text
        } set: { new in
            // A box of one setting on one line takes Return as "next", as a form does.
            guard !isLong, new.contains("\n") else {
                client.writeField(field.key, .text(new))
                return
            }
            client.writeField(field.key, .text(new.replacingOccurrences(of: "\n", with: " ")))
            focus.wrappedValue = order.next(after: mine)
        }
        Group {
            if isMono {
                TextField(placeholder, text: text, axis: .vertical).dsMono(Theme.Touch.body - 1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(placeholder, text: text, axis: .vertical).dsSans()
            }
        }
        .lineLimit(lines)
        .foregroundStyle(Theme.ink.ui)
        .submitLabel(isLong ? .return : .next)
        .focused(focus, equals: mine)
        .typingBox(isOn: focus.wrappedValue == mine)
        .id(mine)
        .accessibilityLabel(label)
    }
}

extension Array where Element == FieldFocus {
    /// The box after this one, or nil at the last, which puts the keyboard away.
    func next(after focus: FieldFocus) -> FieldFocus? {
        guard let index = firstIndex(of: focus), index + 1 < count else { return nil }
        return self[index + 1]
    }
}

extension View {
    /// The box text is typed into: the panel's own, ruled in the colour of what is selected while the keyboard is in it.
    fileprivate func typingBox(isOn: Bool) -> some View {
        padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s + 2)
            .frame(minHeight: Theme.Touch.target)
            .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(isOn ? Theme.select.ui : Theme.hairline.ui, lineWidth: isOn ? Theme.Stroke.selected : Theme.Stroke.card))
    }
}

/// A choice from a short list: what is chosen, in a box, and the list when it is pressed. The Mac's `MenuField`.
private struct ChoiceMenu: View {
    let title: String
    let choices: [EditField.Choice]
    let selection: String
    let pick: (String) -> Void

    var body: some View {
        let chosen = choices.first { $0.value == selection }?.label ?? selection
        Menu {
            Picker(title, selection: Binding { selection } set: { pick($0) }) {
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
            }
        } label: {
            HStack(spacing: Theme.Space.xs + 2) {
                Text(chosen).dsMono(Theme.Touch.body, .medium).lineLimit(1)
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
        .accessibilityLabel(title)
        .accessibilityValue(chosen)
    }
}

/// Something that is on or off, as two halves of one box with the half it is set to inked in: the app's own
/// way of drawing a choice of two, where the system's switch is a pill of glass.
private struct OnOffSwitch: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            half("Off", false)
            half("On", true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.ink.ui, lineWidth: Theme.Stroke.card))
        .frame(minHeight: Theme.Touch.target)
        .animation(Theme.Motion.quick, value: isOn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { set(!isOn) }
    }

    private func half(_ name: String, _ value: Bool) -> some View {
        Button { if isOn != value { set(value) } } label: {
            Text(name)
                .dsMono(Theme.Touch.body, .medium)
                .foregroundStyle((isOn == value ? Theme.surface : Theme.ink).ui)
                .frame(minWidth: 52, minHeight: 36)
                .background(isOn == value ? Theme.ink.ui : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A number with a button either side of it, and what it counts. The Mac's `StepField`.
private struct StepControl: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let unit: String
    let units: String
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: 0) {
                step("minus", by: -1)
                Text("\(value)")
                    .dsMono(Theme.Touch.body, .medium)
                    .foregroundStyle(Theme.ink.ui)
                    .frame(minWidth: 34)
                    .contentTransition(.numericText())
                step("plus", by: 1)
            }
            .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
            if !units.isEmpty {
                Text(value == 1 ? unit : units).dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui).fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(units.isEmpty ? "\(value)" : "\(value) \(value == 1 ? unit : units)")
        .accessibilityAdjustableAction { direction in
            let next = value + (direction == .increment ? 1 : -1)
            if range.contains(next) { set(next) }
        }
    }

    private func step(_ symbol: String, by change: Int) -> some View {
        let next = value + change
        return Button { set(next) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle((range.contains(next) ? Theme.ink : Theme.inkSecondary.withAlphaComponent(0.45)).ui)
        .disabled(!range.contains(next))
    }
}

/// A Switch card's branches, a line each. A branch is renamed in its box, moved up or down, and removed
/// with the buttons beside it. The Mac has them in one line with commas between: this is the same list.
private struct BranchesField: View {
    @Environment(RemoteClient.self) private var client
    let field: EditField
    let order: [FieldFocus]
    var focus: FocusState<FieldFocus?>.Binding

    var body: some View {
        let names = client.shown(field).list
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(field.label).dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui).accessibilityAddTraits(.isHeader)
            ForEach(names.indices, id: \.self) { index in
                let mine = FieldFocus(key: field.key, part: index)
                HStack(spacing: 0) {
                    TextField("Branch", text: Binding {
                        names.indices.contains(index) ? names[index] : ""
                    } set: { new in
                        var changed = client.shown(field).list
                        guard changed.indices.contains(index) else { return }
                        changed[index] = new.replacingOccurrences(of: "\n", with: " ")
                        client.writeField(field.key, .list(changed))
                        if new.contains("\n") { focus.wrappedValue = order.next(after: mine) }
                    }, axis: .vertical)
                    .lineLimit(1...2)
                    .dsMono(Theme.Touch.body, .medium)
                    .foregroundStyle(Theme.ink.ui)
                    .submitLabel(.next)
                    .focused(focus, equals: mine)
                    .typingBox(isOn: focus.wrappedValue == mine)
                    .id(mine)
                    .accessibilityLabel("Branch \(index + 1)")
                    .padding(.trailing, Theme.Space.xs)
                    tool("arrow.up", "Move \(names[index]) up", isEnabled: index > 0) { change { $0.swapAt(index, index - 1) } }
                    tool("arrow.down", "Move \(names[index]) down", isEnabled: index < names.count - 1) { change { $0.swapAt(index, index + 1) } }
                    tool("xmark", "Remove \(names[index])", isEnabled: true) { change { $0.remove(at: index) } }
                }
            }
            Button { change { $0.append(Self.newName(among: $0)) } } label: { Label("Add Branch", systemImage: "plus") }
                .buttonStyle(.panel())
                .disabled(names.count >= Remote.branchLimit)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
    }

    /// The next letter no branch has, as the Mac's own first two are A and B.
    static func newName(among names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        let letters = (65...90).map { String(UnicodeScalar(UInt8($0))) }
        return letters.first { !taken.contains($0.lowercased()) } ?? "Branch \(names.count + 1)"
    }

    /// Moving, removing and adding are sent at once, as a choice is.
    private func change(_ body: (inout [String]) -> Void) {
        var names = client.shown(field).list
        body(&names)
        Task { await client.setField(field.key, .list(names)) }
    }

    private func tool(_ symbol: String, _ label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 36, height: Theme.Touch.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle((isEnabled ? Theme.ink : Theme.inkSecondary.withAlphaComponent(0.45)).ui)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// What starts runs from a Start card besides the Run button: the Mac's `TriggerSettings`, with the same
/// choices in the same order. A schedule set here is only what the card says. Turning it on is a button of its own.
private struct ScheduleField: View {
    @Environment(RemoteClient.self) private var client
    let field: EditField
    let order: [FieldFocus]
    var focus: FocusState<FieldFocus?>.Binding

    private static let intervals = [5, 10, 15, 30, 60, 120, 240, 480, 720, 1440]
    private static let days = [(2, "M", "Monday"), (3, "T", "Tuesday"), (4, "W", "Wednesday"), (5, "T", "Thursday"), (6, "F", "Friday"), (7, "S", "Saturday"), (1, "S", "Sunday")]
    static let kinds = [EditField.Choice(value: "", label: "When you press Run"), EditField.Choice(value: "interval", label: "Every so often"),
                        EditField.Choice(value: "daily", label: "Every day"), EditField.Choice(value: "weekly", label: "On chosen days"),
                        EditField.Choice(value: "file", label: "When a file changes")]

    private var mine: FieldFocus { FieldFocus(key: field.key) }

    private func set(_ change: (inout Trigger) -> Void) {
        var trigger = client.shown(field).schedule ?? Trigger(kind: .daily)
        change(&trigger)
        Task { await client.setField(field.key, .schedule(trigger)) }
    }

    private func two(_ number: Int) -> String { String(format: "%02d", number) }

    var body: some View {
        let trigger = client.shown(field).schedule
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: field.label) {
                ChoiceMenu(title: field.label, choices: Self.kinds, selection: trigger?.kind.rawValue ?? "") { raw in
                    guard let kind = Trigger.Kind(rawValue: raw) else {
                        Task { await client.setField(field.key, .schedule(nil)) }
                        return
                    }
                    set { $0.kind = kind }
                }
            }
            if let trigger {
                switch trigger.kind {
                case .interval:
                    let minutes = (Self.intervals + (Self.intervals.contains(trigger.minutes) ? [] : [trigger.minutes])).sorted()
                    SettingRow(title: "Every") {
                        ChoiceMenu(title: "Every", choices: minutes.map { EditField.Choice(value: "\($0)", label: Trigger(kind: .interval, minutes: $0).summary.replacingOccurrences(of: "Every ", with: "")) },
                                   selection: "\(trigger.minutes)") { picked in set { $0.minutes = Int(picked) ?? $0.minutes } }
                    }
                case .daily:
                    time(trigger)
                case .weekly:
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("On").dsSans().foregroundStyle(Theme.inkSecondary.ui).accessibilityHidden(true)
                        HStack(spacing: Theme.Space.xs) {
                            ForEach(Self.days, id: \.0) { day, letter, name in
                                let isOn = trigger.weekdays.contains(day)
                                Button {
                                    set { $0.weekdays = isOn ? $0.weekdays.filter { $0 != day } : ($0.weekdays + [day]).sorted() }
                                } label: {
                                    Text(letter)
                                        .dsMono(Theme.Touch.body, .medium)
                                        .foregroundStyle((isOn ? Theme.surface : Theme.ink).ui)
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .background((isOn ? Theme.ink : Theme.bar).ui, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge).strokeBorder(isOn ? Theme.ink.ui : Theme.hairline.ui))
                                        .frame(minHeight: Theme.Touch.target)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(name)
                                .accessibilityAddTraits(isOn ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.xs)
                    time(trigger)
                case .file:
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("File or folder in the project").dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui).accessibilityHidden(true)
                        TextField("inbox", text: Binding {
                            client.shown(field).schedule?.path ?? ""
                        } set: { new in
                            guard var changed = client.shown(field).schedule else { return }
                            changed.path = new.replacingOccurrences(of: "\n", with: " ")
                            client.writeField(field.key, .schedule(changed))
                            if new.contains("\n") { focus.wrappedValue = order.next(after: mine) }
                        }, axis: .vertical)
                        .lineLimit(1...2)
                        .dsMono(Theme.Touch.body - 1)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(Theme.ink.ui)
                        .submitLabel(.next)
                        .focused(focus, equals: mine)
                        .typingBox(isOn: focus.wrappedValue == mine)
                        .id(mine)
                        .accessibilityLabel("File or folder in the project")
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                }
            }
        }
    }

    private func time(_ trigger: Trigger) -> some View {
        let minutes = Array(stride(from: 0, to: 60, by: 5)) + (trigger.minute % 5 == 0 ? [] : [trigger.minute])
        return SettingRow(title: "At") {
            HStack(spacing: Theme.Space.xs) {
                ChoiceMenu(title: "Hour", choices: (0...23).map { EditField.Choice(value: "\($0)", label: two($0)) }, selection: "\(trigger.hour)") { picked in
                    set { $0.hour = Int(picked) ?? $0.hour }
                }
                Text(":").dsMono(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui).accessibilityHidden(true)
                ChoiceMenu(title: "Minute", choices: minutes.sorted().map { EditField.Choice(value: "\($0)", label: two($0)) }, selection: "\(trigger.minute)") { picked in
                    set { $0.minute = Int(picked) ?? $0.minute }
                }
            }
        }
    }
}

// MARK: The foot of the details

/// Says whether the flow is being edited, at the foot of the details, with the way in and the way out. It
/// stays put while the details scroll, and sits on top of the keyboard, where its Done puts the keyboard
/// away. On an iPhone the details cover the canvas's own Edit, so this is the Edit that can be reached.
struct EditFoot: View {
    @Environment(RemoteClient.self) private var client
    var focus: FocusState<FieldFocus?>.Binding

    var body: some View {
        if let foot = client.editFoot {
            VStack(spacing: 0) {
                Hairline()
                HStack(spacing: Theme.Space.s) {
                    if let field = focus.wrappedValue {
                        Text(field.key.isLong ? "Sent a moment after you stop writing." : "Sent when you leave the box.")
                            .dsSans(Theme.Touch.caption + 1)
                            .foregroundStyle(Theme.inkSecondary.ui)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Space.s)
                        Button("Done") { focus.wrappedValue = nil }
                            .buttonStyle(.panel(.filled))
                            .accessibilityHint("Puts the keyboard away and sends what you wrote.")
                    } else {
                        Text(foot.text)
                            .dsSans(Theme.Touch.caption + 1)
                            .foregroundStyle((client.isEditing ? Theme.ink : Theme.inkSecondary).ui)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Space.s)
                        if let button = foot.button {
                            Button(button) { client.setEditing(!client.isEditing) }
                                .buttonStyle(.panel())
                                .accessibilityHint(client.isEditing ? "Stops editing." : "Lets you change this flow's cards and their settings from here.")
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .frame(minHeight: Theme.Touch.target + Theme.Space.s * 2)
            }
            .background(Theme.bar.ui)
        }
    }
}

// MARK: The flow's own settings, and what is asked about a flow

/// Settings that belong to the whole flow, as the Mac's flow settings word them: its name, how deep its
/// sub-flows may go, and whether the orchestrator is told when a run ends.
struct FlowSettingsSheet: View {
    @Environment(RemoteClient.self) private var client
    @FocusState private var focus: FieldFocus?
    /// How tall the settings come to, and the bar over them, once they have been laid out.
    @State private var height: CGFloat = 0
    @State private var headHeight: CGFloat = 0

    var body: some View {
        let fields = client.flowFields, flow = client.mirror.snapshot?.flow
        let order = fields.compactMap { field -> FieldFocus? in
            if case .line = field.control { FieldFocus(key: field.key) } else { nil }
        }
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .medium)).frame(width: 22).accessibilityHidden(true)
                Text("Flow Settings").dsMono(Theme.Touch.title, .medium).accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.s)
                Text(flow?.isSubflow == true ? "Sub-flow" : "Flow").dsMono(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui)
                Button("Done") {
                    if focus != nil { focus = nil } else { client.settings.showsFlowSettings = false }
                }
                .buttonStyle(.panel(.filled))
            }
            .foregroundStyle(Theme.ink.ui)
            .padding(.leading, Theme.Space.l)
            .padding(.trailing, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.bar.ui)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fields) { field in
                        Hairline()
                        SettingField(field: field, order: order, focus: $focus)
                        if let text = Self.help(for: field.key.name) { help(text) }
                    }
                    if flow?.isSubflow == true {
                        Hairline()
                        help(EditForm.subflowText).padding(.top, Theme.Space.m)
                    }
                    if let status = client.browserStatus {
                        Hairline()
                        BrowserSection(status: status)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .frame(idealHeight: height > 0 ? height : nil)
        }
        .background(Theme.surface.ui)
        // As tall as what is in it, and no taller, as the questions the app asks in a sheet are.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDetents([.height(height > 0 && headHeight > 0 ? height + headHeight : 420)])
        .presentationBackground(Theme.surface.ui)
        .onChange(of: focus) { old, new in client.focusMoved(from: old?.key, to: new?.key) }
        .onDisappear { client.flushFields() }
    }

    static func help(for name: FieldKey.Name) -> String? {
        switch name {
        case .subflowLimit: EditForm.subflowLimitText
        case .notify: EditForm.notifyText
        default: nil
        }
    }

    private func help(_ text: String) -> some View {
        Text(text)
            .dsSans(Theme.Touch.caption + 1)
            .foregroundStyle(Theme.inkSecondary.ui)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.m)
    }
}

/// The project's browser, which every agent card with a browser in the project shares: what it is doing, the
/// Mac's Download, Restart or Try again when it offers one, and "Clear browser data", asked first.
private struct BrowserSection: View {
    @Environment(RemoteClient.self) private var client
    let status: BrowserStatus
    @State private var asksToClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Browser for \(status.project)").dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui).accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(status.words)
                    .dsSans()
                    .foregroundStyle(Theme.ink.ui)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let offer = status.offer {
                    let command = client.browserCommand(offer.action)
                    Button(offer.title) { Task { await client.browser(offer.action) } }
                        .buttonStyle(.panel(.live))
                        .fixedSize()
                        .disabled(command.map(client.isSending) ?? true)
                        .accessibilityHint(offer.action == .download ? "Has your Mac download the browser it offers, about 150 MB." : "Starts the browser again on your Mac.")
                }
            }
            if let refusal = client.settings.browserRefusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .dsSans(Theme.Touch.caption + 1, .medium)
                    .foregroundStyle(Theme.failInk.ui)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                Text(BrowserStatus.clearText)
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if status.canClear {
                    let command = client.browserCommand(.clear)
                    Button("Clear browser data") { asksToClear = true }
                        .buttonStyle(.panel())
                        .fixedSize()
                        .disabled(command.map(client.isSending) ?? true)
                        .accessibilityHint("Asks first, then signs the agents' browser out of every site in this project.")
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .confirmationDialog("Clear the browser data of \(status.project)?", isPresented: $asksToClear, titleVisibility: .visible) {
            Button("Clear browser data", role: .destructive) { Task { await client.browser(.clear) } }
        } message: {
            Text("The agents' browser is signed out of every site and forgets the pages it kept, for every flow in \(status.project). This can't be undone.")
        }
        .onDisappear { client.settings.browserRefusal = nil }
    }
}

/// Asks a new flow's name, a flow's new name, and before a flow is deleted. And puts up the flow's settings.
private struct AsksAboutFlows: ViewModifier {
    @Environment(RemoteClient.self) private var client
    /// True for the one inside the details' sheet on an iPhone, which asks while that sheet is up. The one on
    /// the whole app asks the rest of the time.
    let overSheet: Bool
    @State private var name = ""

    private var isMine: Bool { overSheet || !client.panel.isSheetUp }

    private var naming: FlowAsk? {
        switch client.settings.asking {
        case .new, .rename: isMine ? client.settings.asking : nil
        case .delete, .stopAgents, nil: nil
        }
    }

    /// Deleting a flow and stopping its agents: a yes or a no, the yes in red.
    private var deleting: FlowAsk? {
        switch client.settings.asking {
        case .delete, .stopAgents: isMine ? client.settings.asking : nil
        case .new, .rename, nil: nil
        }
    }

    private func isAsking(_ ask: FlowAsk?) -> Binding<Bool> {
        Binding { ask != nil } set: { if !$0, ask != nil, client.settings.asking == ask { client.settings.asking = nil } }
    }

    func body(content: Content) -> some View {
        content
            .alert(FlowAsk.title(naming), isPresented: isAsking(naming), presenting: naming) { ask in
                TextField(FlowAsk.namePrompt(ask), text: $name)
                Button(FlowAsk.answer(ask)) { client.confirm(ask, name: name) }
                Button("Cancel", role: .cancel) {}
            } message: { ask in
                Text(FlowAsk.message(ask))
            }
            .alert(FlowAsk.title(deleting), isPresented: isAsking(deleting), presenting: deleting) { ask in
                Button(FlowAsk.answer(ask), role: .destructive) { client.confirm(ask) }
                Button("Cancel", role: .cancel) {}
            } message: { ask in
                Text(FlowAsk.message(ask))
            }
            .sheet(isPresented: Binding { isMine && client.settings.showsFlowSettings } set: { if !$0, isMine { client.settings.showsFlowSettings = false } }) {
                FlowSettingsSheet()
            }
            .onChange(of: client.settings.asking, initial: true) { _, ask in
                if case .rename(_, let current) = ask { name = current } else { name = "" }
            }
            // What was being asked may no longer be this device's to do: control was turned off, or the link dropped.
            .onChange(of: client.canChangeFlows) { _, can in
                if !can { client.settings.asking = nil }
            }
            .onChange(of: client.abilities.canAct) { _, can in
                if !can { client.settings.showsFlowSettings = false }
            }
            .onChange(of: client.mirror.openFlowID) { client.settings.showsFlowSettings = false }
    }
}

extension FlowAsk {
    /// The words each question is asked in, for the screen and for a test.
    static func title(_ ask: FlowAsk?) -> String {
        switch ask {
        case .new(_, let project): "New flow in \(project)"
        case .rename: "Rename Flow"
        case .delete(_, let name): "Delete “\(name)”?"
        case .stopAgents(_, let name): "Stop the agents of “\(name)”?"
        case nil: ""
        }
    }

    static func message(_ ask: FlowAsk) -> String {
        switch ask {
        case .new: "Give it a name, or leave this empty and your Mac names it."
        case .rename: "The flow is renamed on your Mac."
        case .delete: "The flow is taken out of this project on your Mac and its agents are stopped. It goes to the Trash on your Mac."
        case .stopAgents: "Every session of this flow ends on your Mac, the orchestrator's included, and so does a run that is going."
        }
    }

    static func answer(_ ask: FlowAsk) -> String {
        switch ask {
        case .new: "Make Flow"
        case .rename: "Rename"
        case .delete: "Delete Flow"
        case .stopAgents: "Stop Its Agents"
        }
    }

    static func namePrompt(_ ask: FlowAsk) -> String {
        if case .new = ask { "Name (optional)" } else { "Name" }
    }
}

extension View {
    /// Puts up what is asked before a flow is made, renamed or deleted, and the flow's own settings.
    func asksAboutFlows(overSheet: Bool = false) -> some View { modifier(AsksAboutFlows(overSheet: overSheet)) }
}
