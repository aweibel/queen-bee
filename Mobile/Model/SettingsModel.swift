import Foundation
import Observation
import QueenBeeCore

/// What a setting holds, whatever kind of setting it is: a line or more of text, a choice by its value, a
/// number, a Switch card's branches, a Start card's schedule, or a switch that is on or off.
nonisolated enum FieldValue: Equatable, Sendable {
    case text(String)
    case number(Int)
    case list([String])
    case schedule(Trigger?)
    case flag(Bool)

    var text: String { if case .text(let text) = self { text } else { "" } }
    var number: Int { if case .number(let number) = self { number } else { 0 } }
    var list: [String] { if case .list(let list) = self { list } else { [] } }
    var schedule: Trigger? { if case .schedule(let trigger) = self { trigger } else { nil } }
    var flag: Bool { if case .flag(let on) = self { on } else { false } }

    /// How many characters it comes to, for the count shown near a limit.
    var count: Int {
        switch self {
        case .text(let text): text.count
        case .list(let list): list.map(\.count).max() ?? 0
        case .schedule(let trigger): trigger?.path.count ?? 0
        case .number, .flag: 0
        }
    }

    /// The value in a few words, for VoiceOver and for a test.
    var words: String {
        switch self {
        case .text(let text): text
        case .number(let number): "\(number)"
        case .list(let list): list.joined(separator: ", ")
        case .schedule(let trigger): trigger?.summary ?? "When you press Run"
        case .flag(let on): on ? "On" : "Off"
        }
    }
}

/// Which setting: of which card, link or group, or of the flow itself, in which flow.
nonisolated struct FieldKey: Hashable, Sendable {
    enum Item: Hashable, Sendable {
        case card(String)
        case link(String)
        case group(String)
        case flow
    }

    /// The names are `RemoteCardPatch`'s for a card's settings.
    enum Name: String, Sendable {
        case name, instructions, model, effort, permissionMode, role, browser, command, trigger, check, value, maxTries, branches, template, saveTo, text, flowRef
        case waitMinutes, whenNoAnswer, split, maxItems
        /// A link's limit.
        case limit
        case groupName
        case flowName, subflowLimit, notify, spendingLimit
    }

    var flowID: String
    var item: Item
    var name: Name

    /// What the Mac has in this setting, read from its copy of the flow. Nil when what it is a setting of has gone.
    func macValue(in flow: Flow, siblings: [RemoteFlowSummary]) -> FieldValue? {
        switch item {
        case .flow:
            switch name {
            case .flowName: return .text(flow.name)
            case .subflowLimit: return .number(Nesting.clamped(flow.subflowLimit))
            case .notify: return .flag(flow.notifyOrchestrator)
            case .spendingLimit: return .text(EditForm.dollars(flow.spendingLimit))
            default: return nil
            }
        case .link(let id):
            guard name == .limit, let link = flow.links.first(where: { $0.id == id }) else { return nil }
            return .number(link.maxPasses)
        case .group(let id):
            guard name == .groupName, let group = (flow.groups ?? []).first(where: { $0.id == id }) else { return nil }
            return .text(group.name)
        case .card(let id):
            guard let card = flow.card(id) else { return nil }
            switch name {
            case .name: return .text(card.name)
            case .instructions: return .text(card.instructions ?? "")
            case .model: return .text(card.model ?? "")
            case .effort: return .text(card.effort ?? "")
            case .permissionMode: return .text(card.permissionMode ?? "")
            case .role: return .text(card.role ?? "")
            case .browser: return .flag(card.browser == true)
            case .command: return .text(card.command ?? "")
            case .trigger: return .schedule(card.trigger)
            case .check: return .text((card.check ?? .judge).rawValue)
            case .value: return .text(card.value ?? "")
            case .maxTries: return .number(card.maxTries ?? 3)
            case .branches: return .list(card.branches ?? [])
            case .template: return .text(card.template ?? "")
            case .saveTo: return .text(card.saveTo ?? "")
            case .text: return .text(card.text ?? "")
            case .flowRef: return .text(CanvasContent.innerFlow(of: card, in: siblings, excluding: flow.id)?.id ?? "")
            case .waitMinutes: return .text("\(card.waitMinutes ?? 0)")
            case .whenNoAnswer: return .text(card.whenNoAnswer ?? "rejected")
            case .split: return .text((card.split ?? .auto).rawValue)
            case .maxItems: return .number(card.maxItems ?? 20)
            case .limit, .groupName, .flowName, .subflowLimit, .notify, .spendingLimit: return nil
            }
        }
    }

    /// The most characters the Mac takes for this setting from a device. Nil for a setting that isn't text.
    var limit: Int? {
        switch name {
        case .name, .groupName, .flowName, .branches: Remote.nameLimit
        case .instructions, .command, .value, .template, .text: Remote.textLimit
        case .saveTo, .trigger: Remote.pathLimit
        case .model, .effort, .permissionMode, .role, .browser, .check, .maxTries, .flowRef, .limit, .subflowLimit, .notify,
             .waitMinutes, .whenNoAnswer, .split, .maxItems, .spendingLimit: nil
        }
    }

    /// True for a setting that can run to many lines. One of these is sent after a pause in the writing as
    /// well as when it is left, and a new line in it is a new line.
    var isLong: Bool {
        switch name {
        case .instructions, .command, .template, .text: true
        default: false
        }
    }

    /// What was written, cut to what the Mac takes. Done as it is written, so nothing is ever in the field
    /// that the Mac would turn down for its length.
    func capped(_ value: FieldValue) -> FieldValue {
        guard let limit else { return value }
        switch value {
        case .text(let text): return .text(String(text.prefix(limit)))
        case .list(let list): return .list(Array(list.prefix(Remote.branchLimit)).map { String($0.prefix(limit)) })
        case .schedule(var trigger?):
            trigger.path = String(trigger.path.prefix(limit))
            return .schedule(trigger)
        case .schedule(nil), .number, .flag: return value
        }
    }

    /// What was written, as the Mac would keep it: `Remote.plainLine` and `Remote.plainText`, which the Mac
    /// puts everything from a device through. `final` is false while the field is still being written in,
    /// when nothing is taken from under the cursor.
    func cleaned(_ value: FieldValue, final: Bool) -> FieldValue {
        guard final else { return value }
        switch (name, value) {
        case (.name, .text(let text)), (.groupName, .text(let text)), (.flowName, .text(let text)), (.saveTo, .text(let text)):
            return .text(Remote.plainLine(text))
        case (.instructions, .text(let text)), (.command, .text(let text)), (.value, .text(let text)), (.template, .text(let text)), (.text, .text(let text)):
            return .text(Remote.plainText(text))
        case (.branches, .list(let list)):
            // The Mac drops a branch with no name.
            return .list(list.map(Remote.plainLine).filter { !$0.isEmpty })
        case (.trigger, .schedule(var trigger?)):
            trigger.path = Remote.plainLine(trigger.path)
            return .schedule(trigger)
        default:
            return value
        }
    }

    /// The command that tells the Mac this setting is now this.
    func command(_ value: FieldValue) -> RemoteCommand? {
        switch item {
        case .flow:
            switch name {
            case .flowName: return .renameFlow(flowID: flowID, name: value.text)
            case .subflowLimit: return .setFlowOption(flowID: flowID, option: .subflowLimit(levels: value.number))
            case .notify: return .setFlowOption(flowID: flowID, option: .notifyOrchestrator(on: value.flag))
            case .spendingLimit:
                let typed = value.text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
                // Empty is no limit. Anything else that isn't an amount isn't sent.
                if typed.isEmpty { return .setFlowOption(flowID: flowID, option: .spendingLimit(dollars: nil)) }
                return Double(typed).map { .setFlowOption(flowID: flowID, option: .spendingLimit(dollars: $0)) }
            default: return nil
            }
        case .link(let id):
            return name == .limit ? .setLinkLimit(flowID: flowID, linkID: id, maxPasses: value.number) : nil
        case .group(let id):
            return name == .groupName ? .renameGroup(flowID: flowID, groupID: id, name: value.text) : nil
        case .card(let id):
            var patch = RemoteCardPatch()
            switch name {
            case .name: patch.name = value.text
            case .instructions: patch.instructions = value.text
            case .model: patch.model = value.text
            case .effort: patch.effort = value.text
            case .permissionMode: patch.permissionMode = value.text
            case .role: patch.role = value.text
            case .browser: patch.browser = value.flag
            case .command: patch.command = value.text
            case .trigger:
                if let trigger = value.schedule { patch.trigger = trigger } else { patch.removesTrigger = true }
            case .check: patch.check = CheckKind(rawValue: value.text)
            case .value: patch.value = value.text
            case .maxTries: patch.maxTries = value.number
            case .branches: patch.branches = value.list
            case .template: patch.template = value.text
            case .saveTo: patch.saveTo = value.text
            case .text: patch.text = value.text
            case .flowRef: patch.flowRef = value.text
            case .waitMinutes: patch.waitMinutes = Int(value.text) ?? 0
            case .whenNoAnswer: patch.whenNoAnswer = value.text
            case .split: patch.split = ItemSplit(rawValue: value.text)
            case .maxItems: patch.maxItems = value.number
            case .limit, .groupName, .flowName, .subflowLimit, .notify, .spendingLimit: return nil
            }
            return .patchCard(flowID: flowID, cardID: id, patch: patch)
        }
    }
}

/// One setting as the details offer it for changing: the Mac's name for it, what kind of control it is, and
/// what the Mac has in it.
nonisolated struct EditField: Equatable, Identifiable, Sendable {
    struct Choice: Equatable, Sendable {
        var value: String
        var label: String
    }

    enum Control: Equatable, Sendable {
        /// Text that is one setting on one line, though it may wrap: Return moves on.
        case line(placeholder: String, lines: Int)
        /// Text of many lines.
        case text(placeholder: String, isMono: Bool)
        case choice([Choice])
        /// A number with a button either side, and what it counts: one of them, and several. Empty for a bare number.
        case stepper(ClosedRange<Int>, unit: String, units: String)
        /// A Switch card's branches: a line each, which can be renamed, moved, removed and added to.
        case branches
        /// A Start card's schedule, as the Mac's panel lays it out.
        case schedule
        case toggle
    }

    var key: FieldKey
    var label: String
    var control: Control
    var mac: FieldValue

    var id: FieldKey { key }

    /// What a value of this setting is called where it is shown or read out: a choice's own name.
    func words(for value: FieldValue) -> String {
        switch control {
        case .choice(let choices): choices.first { $0.value == value.text }?.label ?? value.text
        case .stepper(_, let unit, let units): units.isEmpty ? "\(value.number)" : "\(value.number) \(value.number == 1 ? unit : units)"
        case .line, .text, .branches, .schedule, .toggle: value.words
        }
    }
}

/// Something the details offer to do to what is selected while it is being edited.
nonisolated struct FormAction: Equatable, Identifiable, Sendable {
    var title: String
    var symbol: String?
    var action: EditAction
    var isDestructive = false

    var id: String { title }
}

/// The details of the selected card, link, group or cards while the flow is being edited: the Mac's
/// `InspectorView`, with each setting as something that can be changed. The names, the choices, their order
/// and the help are the Mac's. It is a plain value, so a test can read exactly what is offered.
nonisolated struct EditForm: Equatable {
    enum Row: Equatable {
        case field(EditField)
        /// A line that isn't a setting: help, a warning, what a run is waiting with.
        case item(DetailItem)
        /// An agent's folder, which is shown and never changed from here.
        case folder(String)
        /// The flow a Flow card runs, to go and look at.
        case open(flowID: String, name: String)
        /// A Flow card that runs nothing yet: "New sub-flow" makes one for it.
        case newSubflow(cardID: String)
        /// "Changed since the role was saved.", with Reset and "Update role".
        case roleDrift(cardID: String)
        /// A Start card's schedule, set and on or off, with "Turn on" or "Turn off".
        case arm(cardID: String, isOn: Bool)
    }

    var icon: String
    var title: String
    var kind: String
    var state: SessionState?
    var rows: [Row] = []
    var actions: [FormAction] = []
    var answerLine = false
    var messages: [LinkMessage]?
    var messagesTitle = ""

    static let folderLine = "Change the folder on your Mac."
    static let scriptLine = "A command changed from here was not typed on your Mac, so the next run stops and asks before running it."
    static let scheduleOffLine = "A schedule set here starts switched off. Turn it on once it is set."
    static let switchedOff = "This schedule is switched off. It stays off until you turn it on."
    static let scheduleOnLine = "This schedule is on. A change to what this flow does, made from a device, turns it off again."
    static let branchLine = "A link from a branch that is renamed or removed goes with it."
    static let editing = "Editing. Changes go to your Mac as you make them."
    static let pressEdit = "Press Edit to change these from here."
    static let keptLine = "Something you wrote here hasn't been saved. Press Edit to see it."
    static let keptAway = "Something you wrote here hasn't been saved. It is kept, to send when your Mac is back."

    var fields: [EditField] {
        rows.compactMap { if case .field(let field) = $0 { field } else { nil } }
    }

    init?(selection: CanvasModel.Selection, snapshot: RemoteFlowSnapshot, run: RunOnShow, siblings: [RemoteFlowSummary], roles: [RemoteRole]) {
        let flow = snapshot.flow
        switch selection {
        case .none:
            return nil
        case .card(let id):
            guard let card = flow.card(id) else { return nil }
            self.init(card: card, snapshot: snapshot, run: run, siblings: siblings, roles: roles)
        case .link(let id):
            guard let link = flow.links.first(where: { $0.id == id }) else { return nil }
            self.init(link: link, flow: flow, run: run)
        case .group(let id):
            guard let group = (flow.groups ?? []).first(where: { $0.id == id }) else { return nil }
            self.init(group: group, flow: flow)
        case .cards(let ids):
            let cards = flow.cards.map(\.id).filter(ids.contains)
            guard cards.count > 1 else { return nil }
            self.init(cards: cards)
        }
    }

    init(card: Card, snapshot: RemoteFlowSnapshot, run: RunOnShow, siblings: [RemoteFlowSummary], roles: [RemoteRole]) {
        let flow = snapshot.flow
        // What the read-only details say that isn't a setting is said here too, in the same words.
        let details = Details(card: card, snapshot: snapshot, run: run, siblings: siblings, roles: roles)
        icon = details.icon
        title = card.name
        kind = details.kind
        state = details.state
        answerLine = details.answerLine

        func key(_ name: FieldKey.Name) -> FieldKey { FieldKey(flowID: flow.id, item: .card(card.id), name: name) }
        func add(_ name: FieldKey.Name, _ label: String, _ control: EditField.Control) {
            let key = key(name)
            guard let mac = key.macValue(in: flow, siblings: siblings) else { return }
            rows.append(.field(EditField(key: key, label: label, control: control, mac: mac)))
        }
        func note(_ text: String) { rows.append(.item(DetailItem(style: .note, label: text))) }
        func caution(_ text: String) { rows.append(.item(DetailItem(style: .caution, label: text))) }
        func choices(_ all: [(String, String)]) -> EditField.Control { .choice(all.map { EditField.Choice(value: $0.0, label: $0.1) }) }

        // The Mac has the name in the panel's header, typed over where it stands. Here it is the first setting.
        add(.name, "Name", .line(placeholder: card.kind.label, lines: 2))

        switch card.kind {
        case .agent:
            add(.instructions, "Instructions", .text(placeholder: "A standing brief for this agent", isMono: false))
            // Always there, as on the Mac: it is also where a card is saved as a new role.
            // A role a device saved or changed is marked as the Mac marks it.
            add(.role, "Role", choices([("", "None")] + roles.map { role in (role.id, role.changedFrom.map { "\(role.name) · changed from \($0)" } ?? role.name) }))
            if let id = card.role, let role = roles.first(where: { $0.id == id }) {
                if let changed = role.changedLine { note(changed + ". Your Mac asks before it uses this role.") }
                if !role.matches(card) { rows.append(.roleDrift(cardID: card.id)) }
            }
            let known = ["fable", "opus", "sonnet", "haiku"], model = card.model ?? ""
            add(.model, "Model", choices([("", "Your default")] + known.map { ($0, $0.capitalized) } + (model.isEmpty || known.contains(model) ? [] : [(model, model)])))
            add(.effort, "Effort", choices([("", "Model default")] + Card.effortLevels.map { ($0, $0) }))
            if let cost = details.items.first(where: { $0.style == .row && $0.label == "Cost" }) { rows.append(.item(cost)) }
            // The Mac's choices and no others. A mode that skips permission checks is never one of them.
            add(.permissionMode, "Permissions", choices([("", "Your default"), ("manual", "Manual"), ("acceptEdits", "Accept edits"), ("plan", "Plan"), ("auto", "Auto")]))
            add(.browser, "Browser", .toggle)
            note(Self.browserLine)
            rows.append(.folder((card.cwd ?? "").isEmpty ? "The project's folder" : card.cwd ?? ""))
        case .start:
            add(.command, "What the run starts with", .text(placeholder: "The message the first card gets", isMono: false))
            if flow.isSubflow == true {
                note("This is a sub-flow. When a Flow card runs it, the message that card was given is used in place of the text above. The text above is for trying the sub-flow by itself.")
            }
            add(.trigger, "Runs", .schedule)
            if let trigger = card.trigger, snapshot.edit.armed.contains(card.id) {
                note(trigger.kind == .file
                     ? "A run starts whenever it changes, and is told which file changed. Queen Bee has to be open, and a change made while a run is going doesn't start another."
                     : "\(snapshot.edit.nextFires[card.id].map { "Next: \(Clock.run($0)). " } ?? "")Queen Bee has to be open for it to run. A run that falls due while another is going is skipped.")
                caution(Self.scheduleOnLine)
                rows.append(.arm(cardID: card.id, isOn: true))
            } else if card.trigger != nil {
                caution(Self.switchedOff)
                rows.append(.arm(cardID: card.id, isOn: false))
            } else {
                note(Self.scheduleOffLine)
            }
        case .ifElse, .loop:
            add(.check, "Check", choices([(CheckKind.judge.rawValue, "Ask Claude"), (CheckKind.contains.rawValue, "Message contains"),
                                          (CheckKind.notContains.rawValue, "Message doesn't contain"), (CheckKind.regex.rawValue, "Matches a pattern")]))
            // Named and prompted for the check the Mac has. The view names it for the check on show.
            add(.value, Self.valueLabel(card.check ?? .judge), .line(placeholder: Self.valuePlaceholder(card.check ?? .judge), lines: 4))
            if card.kind == .loop {
                add(.maxTries, "Give up after", .stepper(1...20, unit: "try", units: "tries"))
                note(Self.gaveUpText)
            }
        case .forEach:
            add(.split, "Split into", choices([(ItemSplit.auto.rawValue, "List items or lines"), (ItemSplit.lines.rawValue, "Lines")]))
            add(.maxItems, "At most", .stepper(1...Engine.mostItems, unit: "item", units: "items"))
            note(Self.forEachText)
        case .switchCard:
            add(.branches, "Branches", .branches)
            note("Claude reads each message and sends it down the branch it fits best. A message that fits none of them goes out Other.")
            note(Self.branchLine)
        case .prompt:
            add(.template, "Rewrite the message as", .text(placeholder: "{{message}}", isMono: false))
            note("Write {{message}} where the incoming message should go, and {{from}} for the name of the card it came from. If you leave {{message}} out, the message is added at the end.")
        case .end:
            add(.saveTo, "Save the answer to a file (optional)", .line(placeholder: "output/answer.md", lines: 2))
            if let answer = details.items.first(where: { $0.style == .text }) { rows.append(.item(answer)) }
        case .and, .or:
            details.items.filter { $0.style == .note }.forEach { rows.append(.item($0)) }
        case .note:
            add(.text, "Note", .text(placeholder: "", isMono: false))
        case .approval:
            add(.text, "What to check before approving", .line(placeholder: "Is this email right to send?", lines: 3))
            add(.waitMinutes, "Wait for an answer", Self.waitChoices(card))
            if (card.waitMinutes ?? 0) > 0 { add(.whenNoAnswer, "Then", choices([("rejected", "Reject it"), ("approved", "Approve it")])) }
            if !details.items.contains(where: { $0.style == .waiting }) {
                note("A run stops here and waits for you. You can edit the message, then approve or reject it.")
            }
        case .flow:
            let others = siblings.filter { $0.id != flow.id }
            add(.flowRef, "Runs", choices([("", "Nothing yet")] + others.map { ($0.id, $0.name) }))
            if let inner = CanvasContent.innerFlow(of: card, in: siblings, excluding: flow.id) {
                rows.append(.open(flowID: inner.id, name: inner.name))
            } else {
                rows.append(.newSubflow(cardID: card.id))
            }
            note("This card runs a whole flow as one step. The message that arrives here goes to that flow's Input, and what reaches its Output comes back out Done. If it stops early or fails, the message goes out Fail.")
        case .script:
            add(.command, "Command", .text(placeholder: "A command to run in the project's folder", isMono: true))
            caution(Self.scriptLine)
            add(.waitMinutes, "Wait to be allowed", Self.waitChoices(card))
            note("Runs this command in the project's folder, as if you had typed it in Terminal. If the command succeeds, the run carries on from Pass. If it fails, from Fail. Whatever the command prints is what gets passed on.")
        }
        // What a run is waiting with at this card, what is wrong with its wiring, that the run stopped here, and what its
        // session doesn't have yet.
        details.items.filter { [.waiting, .warning, .stopped, .pending].contains($0.style) }.forEach { rows.append(.item($0)) }

        actions = [FormAction(title: "Delete", symbol: "trash", action: .delete(cards: [card.id], links: []), isDestructive: true),
                   FormAction(title: "Duplicate", action: .duplicate([card.id])),
                   FormAction(title: "Copy", action: .copy([card.id]))]
    }

    init(link: QueenBeeCore.Link, flow: Flow, run: RunOnShow) {
        let details = Details(link: link, flow: flow, run: run)
        icon = details.icon
        title = details.title
        kind = details.kind
        let key = FieldKey(flowID: flow.id, item: .link(link.id), name: .limit)
        rows = [.field(EditField(key: key, label: "Limit per run", control: .stepper(1...50, unit: "", units: ""), mac: .number(link.maxPasses))),
                .item(DetailItem(style: .note, label: "This link carries at most this many messages in one run. The limit is what stops a loop from going round for ever."))]
        messages = details.messages
        messagesTitle = details.messagesTitle
        actions = [FormAction(title: "Delete", symbol: "trash", action: .delete(cards: [], links: [link.id]), isDestructive: true)]
    }

    init(group: CardGroup, flow: Flow) {
        let members = flow.cards.map(\.id).filter(group.cardIDs.contains)
        icon = "square.on.square.dashed"
        title = group.name
        kind = "Group"
        let key = FieldKey(flowID: flow.id, item: .group(group.id), name: .groupName)
        rows = [.field(EditField(key: key, label: "Group", control: .line(placeholder: "Name", lines: 2), mac: .text(group.name))),
                .item(DetailItem(style: .row, label: "Cards", value: "\(members.count)")),
                .item(DetailItem(style: .note, label: group.isFolded ? "Folded into one card. Its cards keep working, and links to them meet the group's edge."
                                 : "Drag the group by its name. Fold it to show its cards as one."))]
        actions = [FormAction(title: "Delete", symbol: "trash", action: .delete(cards: members, links: []), isDestructive: true),
                   FormAction(title: "Ungroup", action: .ungroup(group.id)),
                   FormAction(title: group.isFolded ? "Unfold" : "Fold", action: .fold(group.id, !group.isFolded))]
    }

    /// Several cards: no settings in common, only what can be done to all of them.
    init(cards: [String]) {
        icon = "square.on.square.dashed"
        title = "\(cards.count) cards"
        kind = ""
        rows = [.item(DetailItem(style: .note, label: "Drag any of them to move them together. With Select on, tap a card to add it or take it out."))]
        actions = [FormAction(title: "Delete", symbol: "trash", action: .delete(cards: cards, links: []), isDestructive: true),
                   FormAction(title: "Duplicate", action: .duplicate(cards)),
                   FormAction(title: "Group", action: .group(cards)),
                   FormAction(title: "Copy", action: .copy(cards))]
    }

    /// What the Mac calls an If or Loop card's text, which depends on how it checks.
    static func valueLabel(_ check: CheckKind) -> String {
        check == .judge ? "What should be true of the message?" : check == .regex ? "Pattern (a regular expression)" : "Text to look for"
    }

    static func valuePlaceholder(_ check: CheckKind) -> String {
        check == .judge ? "The review approves the draft" : "APPROVED"
    }

    /// The flow's own settings, as the Mac's flow settings have them.
    static func flowFields(_ flow: Flow) -> [EditField] {
        func key(_ name: FieldKey.Name) -> FieldKey { FieldKey(flowID: flow.id, item: .flow, name: name) }
        var fields = [EditField(key: key(.flowName), label: "Flow name", control: .line(placeholder: "Flow name", lines: 2), mac: .text(flow.name))]
        // One place to set the limit: the flow at the top. A sub-flow goes by the flow above it.
        if flow.isSubflow != true {
            fields.append(EditField(key: key(.subflowLimit), label: "Sub-flows can go", control: .stepper(0...Nesting.deepestLimit, unit: "level deep", units: "levels deep"),
                                    mac: .number(Nesting.clamped(flow.subflowLimit))))
        }
        fields.append(EditField(key: key(.spendingLimit), label: "Stop a run once it has spent ($)", control: .line(placeholder: "No limit", lines: 1),
                                mac: .text(dollars(flow.spendingLimit))))
        fields.append(EditField(key: key(.notify), label: "Tell the orchestrator when a run ends", control: .toggle, mac: .flag(flow.notifyOrchestrator)))
        return fields
    }

    /// "5", "2.50", or empty for no limit, as the Mac's flow settings show it.
    static func dollars(_ amount: Double?) -> String {
        guard let amount else { return "" }
        return amount == amount.rounded() ? String(format: "%.0f", amount) : String(format: "%.2f", amount)
    }

    /// The Mac's choices for how long an Approval or Script card waits for the person, and the card's own if it is another.
    static func waitChoices(_ card: Card) -> EditField.Control {
        let minutes = card.waitMinutes ?? 0, all = [0, 15, 30, 60, 120, 240, 480, 24 * 60, 2 * 24 * 60, 7 * 24 * 60]
        return .choice((all + (all.contains(minutes) ? [] : [minutes])).sorted().map {
            EditField.Choice(value: "\($0)", label: $0 == 0 ? "As long as it takes" : "Up to \(HoldTimeLimit.describe(minutes: $0))")
        })
    }

    /// What a card with a time limit does when it is up, or nil for one that waits for good.
    static func waitLine(_ card: Card) -> String? {
        guard let minutes = card.waitMinutes, minutes > 0 else { return nil }
        let after = "After \(HoldTimeLimit.describe(minutes: minutes))"
        switch HoldTimeLimit.port(for: card) {
        case "approved": return "\(after), approved"
        case "rejected": return "\(after), rejected"
        default: return "\(after), skipped"
        }
    }

    /// When a waiting card answers for the person, after what the details say it is waiting for.
    static func deadlineLine(_ hold: PendingHold, card: Card) -> String {
        guard let deadline = hold.deadline else { return "" }
        let time = deadline.formatted(date: .omitted, time: .shortened)
        switch HoldTimeLimit.port(for: card) {
        case "approved": return " If nobody answers by \(time), it is approved."
        case "rejected": return " If nobody answers by \(time), it is rejected."
        default: return " If nobody allows it by \(time), it is skipped."
        }
    }

    static let gaveUpText = "When the tries run out, the message goes out Gave up. If nothing is linked to Gave up, it goes out Done instead."
    static let forEachText = "Sends each item out Each, one at a time. Link the last card that works on an item back into this card: what comes back that way is that item's result, and then the next item goes. When all of them are back, everything goes out Done together."
    static let spendingText = "Your Mac adds up what a run's agents have used, at API prices, each time one of them finishes a turn. A run that goes past this amount is stopped. Leave it empty for no limit."

    static let subflowLimitText = "A Flow card runs another flow, which can hold Flow cards of its own. This is how far down that may go under this flow. 0 means no sub-flows."
    static let subflowText = "This is a sub-flow. How deep sub-flows can go is set on the flow at the top."
    static let notifyText = "When on, the orchestrator is sent what each run did and replies about it. That reply uses its model, so turning this off makes runs cheaper."
}

/// Something that is asked before a flow is made, renamed or deleted.
nonisolated enum FlowAsk: Equatable, Sendable {
    /// A new flow's name, which may be left empty for the Mac to give it one.
    case new(projectID: String, project: String)
    case rename(flowID: String, name: String)
    /// Deleting a flow can't be undone, so it is asked by the flow's name.
    case delete(flowID: String, name: String)
    /// "Stop Its Agents" ends every session of the flow and any run, so it is asked first.
    case stopAgents(flowID: String, name: String)
}

/// One thing a flow's row in the list offers when a finger is held on it.
nonisolated struct FlowMenuItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case rename, pin, stopAgents, settings, delete }

    var kind: Kind
    var title: String
    var symbol: String

    var id: Kind { kind }
}

/// The settings this device is in the middle of changing, and what the list of flows is asking. A setting
/// is here only while it holds something the Mac doesn't have: the keyboard, or text not yet taken. What was
/// written and couldn't be sent is kept for as long as the app runs, so it is there when its card is
/// selected again.
@Observable
final class SettingsModel {
    private(set) var fields: [FieldKey: FieldEdit<FieldValue>] = [:]
    /// What sends each long text a moment after the writing stops.
    @ObservationIgnored var pauses: [FieldKey: Task<Void, Never>] = [:]

    /// The flow whose row in the list has its menu out.
    var flowMenu: String?
    /// What is being asked about a flow. Put away by setting it to nil.
    var asking: FlowAsk?
    /// The flow's own settings are up.
    var showsFlowSettings = false
    /// The last thing about a flow that the Mac turned down, in its words, shown over the list of flows.
    var refusal: String?
    /// What is written in Find, over the list of flows. Empty for the list itself.
    var search = ""
    /// The last thing the Mac turned down about the project's browser, said in the flow's settings beside its buttons.
    var browserRefusal: String?
    /// A new flow was asked for in this project, and is opened when the Mac lists it: the flows the project
    /// had before, the name that was asked for, which may be none, and when the Mac said it had made it.
    @ObservationIgnored var awaitingNew: NewFlowAwaited?

    /// How long after the last key a long text is sent.
    static let pause: Duration = .seconds(1)

    /// Changes one setting's state, starting from what the Mac has when it isn't here yet. A setting left
    /// with nothing of the person's in it is forgotten.
    func update(_ key: FieldKey, mac: FieldValue? = nil, _ change: (inout FieldEdit<FieldValue>) -> Void) {
        guard var field = fields[key] ?? mac.map({ FieldEdit(mac: $0) }) else { return }
        change(&field)
        let kept: FieldEdit<FieldValue>? = field.isIdle ? nil : field
        if fields[key] != kept { fields[key] = kept }
    }

    func forget(_ key: FieldKey) {
        pauses.removeValue(forKey: key)?.cancel()
        if fields[key] != nil { fields[key] = nil }
    }

    func clear() {
        pauses.values.forEach { $0.cancel() }
        pauses = [:]
        fields = [:]
        flowMenu = nil
        asking = nil
        showsFlowSettings = false
        refusal = nil
        search = ""
        browserRefusal = nil
        awaitingNew = nil
    }
}
