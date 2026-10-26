import QueenBeeCore
import SwiftUI

/// Settings for the selected card or link, floating over the canvas's corner. Every kind of
/// card gets the same three parts: a header that names it, rows for what it is set to, and a
/// footer with what you can do to it.
struct InspectorView: View {
    static let width: CGFloat = 300
    let controller: FlowController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch controller.selection {
            case .card(let id):
                if let card = controller.flow.card(id) {
                    CardSettings(controller: controller, card: card)
                        .id(card.id)
                }
            case .link(let id):
                if let link = controller.flow.links.first(where: { $0.id == id }) {
                    LinkSettings(controller: controller, link: link)
                        .id(link.id)
                }
            case .cards(let ids):
                SeveralSettings(controller: controller, count: ids.count)
            case .none:
                EmptyView()
            }
        }
        .frame(width: Self.width)
        .foregroundStyle(Theme.ink.ui)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .floatingPanel()
    }
}

private struct CardSettings: View {
    let controller: FlowController
    let card: Card
    @State private var name = ""
    @FocusState private var isNaming: Bool

    var body: some View {
        let pending = card.kind == .agent ? controller.settingsAwaitingRestart(forCard: card.id) : []
        VStack(alignment: .leading, spacing: 0) {
            header
            switch card.kind {
            case .agent: agent
            case .start:
                EditorField("What the run starts with", text: card.command ?? "") { v in patch { $0.command = v } }
                if controller.flow.isSubflow == true {
                    note("This is a sub-flow. When a Flow card runs it, the message that card was given is used in place of the text above. The text above is for trying the sub-flow by itself.")
                }
                TriggerSettings(controller: controller, card: card)
            case .ifElse:
                condition
            case .loop:
                condition
                row("Give up after") {
                    HStack(spacing: 4) {
                        StepField(value: card.maxTries ?? 3, range: 1...20) { v in patch { $0.maxTries = v } }
                        Text("tries").font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui)
                    }
                }
                note("When the tries run out, the message goes out Gave up. If nothing is linked to Gave up, it goes out Done instead.")
            case .forEach:
                row("Split into") {
                    MenuField(options: [(value: ItemSplit.auto, label: "List items or lines"), (value: .lines, label: "Lines")],
                              selection: card.split ?? .auto) { v in patch { $0.split = v } }
                }
                row("At most") {
                    HStack(spacing: 4) {
                        StepField(value: card.maxItems ?? 20, range: 1...Engine.mostItems) { v in patch { $0.maxItems = v } }
                        Text("items").font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui)
                    }
                }
                note("Sends each item out Each, one at a time. Link the last card that works on an item back into this card: what comes back that way is that item's result, and then the next item goes. When all of them are back, everything goes out Done together. “List items” is used when the message is a JSON list. Every hand-off to an agent counts toward a run's limit of \(Engine.maxDeliveries).")
            case .switchCard:
                LineField("Branches, separated by commas", placeholder: "bug, feature, question",
                          text: (card.branches ?? []).joined(separator: ", ")) { v in
                    let names = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    patch { $0.branches = names }
                }
                note("Claude reads each message and sends it down the branch it fits best. A message that fits none of them goes out Other.")
            case .prompt:
                EditorField("Rewrite the message as", text: card.template ?? "") { v in patch { $0.template = v } }
                note("Write {{message}} where the incoming message should go, and {{from}} for the name of the card it came from. If you leave {{message}} out, the message is added at the end.")
            case .end:
                LineField("Save the answer to a file (optional)", placeholder: "output/answer.md", text: card.saveTo ?? "") { v in patch { $0.saveTo = v } }
                if let result = controller.results[card.id] {
                    section {
                        field("Latest answer") {
                            ScrollView {
                                Text(result).font(.dsSans(Theme.Size.body)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                    }
                }
            case .and:
                note("Waits until every card linked into it has answered, then passes all their answers on together.")
            case .or:
                note("Passes on whichever answer arrives first in a run and ignores the rest.")
            case .note:
                EditorField("Note", text: card.text ?? "") { v in patch { $0.text = v } }
            case .approval:
                LineField("What to check before approving", placeholder: "Is this email right to send?",
                          text: card.text ?? "", lines: 1...3) { v in patch { $0.text = v } }
                WaitSettings(card: card, patch: patch)
                if let hold = controller.holds.first(where: { $0.cardID == card.id }) {
                    ApprovalReview(controller: controller, hold: hold)
                        .id(hold.id)
                } else {
                    note("A run stops here and waits for you. You can edit the message, then approve or reject it.")
                }
            case .flow:
                let inner = controller.innerFlow(of: card)
                let everyOther = controller.project.controllers.filter { $0 !== controller }
                // Only flows that fit: not ones that would run this flow in turn, or nest too deep.
                let others = everyOther.filter { $0 === inner || controller.nestingProblem(placing: $0) == nil }
                row("Runs") {
                    MenuField(options: [(value: "", label: "Nothing yet")] + others.map { (value: $0.flow.id, label: $0.flow.name) },
                              selection: inner?.flow.id ?? "") { v in patch { $0.flowRef = v } }
                }
                if let inner, let problem = controller.nestingProblem(placing: inner) {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.dsSans(Theme.Size.caption))
                        .foregroundStyle(Theme.failInk.ui)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.bottom, 6)
                }
                HStack(spacing: Theme.Space.s) {
                    Text(inner == nil ? "Make a sub-flow just for this card:" : "Build or change what it does:")
                        .font(.dsSans(Theme.Size.caption))
                        .foregroundStyle(Theme.inkSecondary.ui)
                    Spacer()
                    Button(inner == nil ? "New sub-flow" : "Open") { controller.openSubflow(forCard: card.id) }
                        .buttonStyle(.panel(.filled))
                        .disabled(inner == nil && controller.newSubflowProblem != nil)
                        .help(inner == nil ? controller.newSubflowProblem ?? "You can also double-click the card" : "You can also double-click the card")
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 6)
                note("This card runs a whole flow as one step. The message that arrives here goes to that flow's Input, and what reaches its Output comes back out Done. If it stops early or fails, the message goes out Fail.")
            case .script:
                EditorField("Command", text: card.command ?? "", mono: true) { v in controller.setScriptCommand(card.id, v) }
                    .help("For scripts that need it: the incoming message is in $QB_MESSAGE and on standard input, and the sender's name is in $QB_FROM.")
                note("Runs this command in the project's folder, as if you had typed it in Terminal. If the command succeeds, the run carries on from Pass. If it fails, from Fail. Whatever the command prints is what gets passed on.")
                WaitSettings(card: card, patch: patch)
                if let hold = controller.holds.first(where: { $0.cardID == card.id }) {
                    ScriptReview(controller: controller, hold: hold)
                        .id(hold.id)
                }
            }

            if let warning = controller.warnings[card.id] {
                section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.dsSans(Theme.Size.caption))
                        .foregroundStyle(Theme.failInk.ui)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if controller.canRetry(card.id) {
                HStack(spacing: Theme.Space.s) {
                    Text("The run stopped here.")
                        .font(.dsSans(Theme.Size.caption))
                    Spacer()
                    Button("Retry") { controller.retry(card.id) }
                        .buttonStyle(.panel())
                        .help("Give this card the same message again and carry on from here")
                }
                .foregroundStyle(Theme.failInk.ui)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 6)
                .background(Theme.failTint.ui)
                .overlay(alignment: .top) { rule }
            }
            if controller.runFromCardID == card.id {
                RunFromHere(controller: controller, card: card)
            }
            if !pending.isEmpty {
                // The session is still running on what it was started with. Say so beside
                // the buttons that settle it.
                Text("Not in use yet. The agent keeps working with its old \(Self.list(pending)) until you restart it.")
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(Theme.liveInk.ui)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, 7)
                    .background(Theme.liveTint.ui)
                    .overlay(alignment: .top) { rule }
                    .transition(.opacity)
            }
            footer(pending: pending)
        }
        .animation(Theme.Motion.standard, value: pending.isEmpty)
    }

    /// The card's kind, its name, and for an agent what its session is doing. The name is
    /// edited where it stands.
    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: CanvasGeometry.icon(for: card.kind))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
                .help(card.kind.label)
            TextField(card.kind.label, text: $name)
                .textFieldStyle(.plain)
                .font(.dsSans(Theme.Size.title, .medium))
                .focused($isNaming)
                .onSubmit(commitName)
                .onAppear { name = card.name }
                .onChange(of: card.name) { name = card.name }
                // A new name is kept when the box is left, by Tab or a click elsewhere, not only by Return.
                .onChange(of: isNaming) { if !isNaming { commitName() } }
                .onDisappear(perform: commitName)
                .help("Rename this card")
            if card.kind == .agent {
                let session = controller.session(forCard: card.id)
                Badge(text: session.state.label.lowercased(), tone: session.state.tone)
            } else {
                Text(card.kind.label)
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.bar.ui)
    }

    private func footer(pending: [String]) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button { controller.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(.panel(.quiet))
                .help("Delete this card and its links")
            Spacer()
            if acceptsInput(card), controller.runFromCardID != card.id {
                Button("Run from here…") { controller.runFromCardID = card.id }
                    .buttonStyle(.panel(.quiet))
                    .help("Start a run at this card with a message you give it, skipping everything that comes before")
            }
            if card.kind == .start {
                Button { Task { await controller.run(startCardID: card.id) } } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.panel(.filled))
                    .disabled(controller.isRunning || (card.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || controller.flow.links(from: card.id).isEmpty)
                    .help("Start a run from this Start card")
            }
            if card.kind == .agent {
                let session = controller.session(forCard: card.id)
                if pending.isEmpty {
                    Button(session.isLive ? "Restart" : "Start") { controller.startSession(forCard: card.id) }
                        .buttonStyle(.panel())
                        .help(session.isLive ? "Restart the agent. It keeps its conversation so far." : "Start the agent with these settings")
                } else {
                    Button("Undo") { controller.revertSettings(forCard: card.id) }
                        .buttonStyle(.panel())
                        .help("Put these settings back to what the agent is using now")
                    Button("Restart to apply") { controller.startSession(forCard: card.id) }
                        .buttonStyle(.panel(.live))
                        .help(session.state == .working ? "Restarting interrupts what the agent is doing now. It keeps its conversation so far." : "The agent keeps its conversation so far.")
                }
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
        .background(Theme.bar.ui)
        .overlay(alignment: .top) { rule }
    }

    @ViewBuilder private var agent: some View {
        EditorField("Instructions", text: card.instructions ?? "") { v in patch { $0.instructions = v } }
        roleRow
        row("Model") {
            let known = ["fable", "opus", "sonnet", "haiku"]
            let custom = (card.model ?? "").isEmpty || known.contains(card.model ?? "") ? [] : [(value: card.model ?? "", label: card.model ?? "")]
            MenuField(options: [(value: "", label: "Your default")] + known.map { (value: $0, label: $0.capitalized) } + custom,
                      selection: card.model ?? "") { v in patch { $0.model = v } }
        }
        row("Effort") {
            MenuField(options: [(value: "", label: "Model default")] + Card.effortLevels.map { (value: $0, label: $0) },
                      selection: card.effort ?? "") { v in patch { $0.effort = v } }
                .help("Claude Code's effort level: how hard the agent thinks before it answers. Higher is slower and uses more.")
        }
        if let all = controller.usage[card.id], !all.isZero {
            row("Cost") {
                let run = controller.runUsage(forCard: card.id)
                Text(run.map { $0.isZero ? "\(all.price) in all" : "\($0.price) this run · \(all.price) in all" } ?? "\(all.price) in all")
                    .font(.dsSans(Theme.Size.caption, .medium))
                    .help("An estimate of what this agent's work would cost if you paid Anthropic by usage (\(all.tokenCount) so far). On a Claude subscription you don't pay this.")
            }
        }
        row("Permissions") {
            MenuField(options: [(value: "", label: "Your default"), (value: "manual", label: "Manual"),
                                (value: "acceptEdits", label: "Accept edits"), (value: "plan", label: "Plan"), (value: "auto", label: "Auto")],
                      selection: card.permissionMode ?? "") { v in patch { $0.permissionMode = v } }
                .help("Claude Code's permission mode. Manual asks before each action, Accept edits changes files without asking, Plan only plans and changes nothing, and Auto decides for itself.")
        }
        row("Browser") {
            Toggle("", isOn: Binding(get: { card.browser == true }, set: { on in patch { $0.browser = on } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.select.ui)
                .help("Gives this agent a web browser in its card. You can watch what it does there and use the browser yourself. The agent can look at pages freely, and asks before it clicks or types unless its permissions say otherwise.")
        }
    }

    /// The saved role the agent comes from. A card that has drifted from its role can go back
    /// to it, or the role can be brought up to date from the card.
    @ViewBuilder private var roleRow: some View {
        let roles = AppServices.shared.roles
        let current = controller.role(of: card)
        row("Role") {
            Menu {
                Toggle("None", isOn: Binding(get: { current == nil }, set: { _ in controller.applyRole(nil, toCard: card.id) }))
                ForEach(roles) { role in
                    // A role a paired device saved or changed is marked, and asked about before it is first used here.
                    Toggle(role.changedFrom.map { "\(role.name) — changed from \($0.device)" } ?? role.name,
                           isOn: Binding(get: { current?.id == role.id }, set: { _ in controller.applyRole(role, toCard: card.id) }))
                }
                Divider()
                Button(current == nil ? "Save as a New Role" : "Update “\(current?.name ?? "")” from This Card") { controller.saveRole(fromCard: card.id) }
                if let current, current.earlier != nil {
                    Button("Put Back the Earlier Version of “\(current.name)”") { AppServices.shared.putBackEarlierVersion(of: current.id) }
                }
                let deleted = AppServices.shared.deletedRoles
                if !deleted.isEmpty {
                    Menu("Restore a Role Deleted from a Device") {
                        ForEach(deleted.reversed()) { gone in
                            Button("\(gone.role.name) — deleted from \(gone.device), \(gone.date.formatted(date: .abbreviated, time: .shortened))") {
                                AppServices.shared.restoreRole(gone.role.id)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current?.name ?? "None").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.inkSecondary.ui)
                }
                .font(.dsSans(Theme.Size.caption, .medium))
                .foregroundStyle(Theme.ink.ui)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("A role is an agent's settings saved under a name, so you can make more agents like it in any flow")
        }
        if let current, let changed = current.changedLine {
            HStack(spacing: Theme.Space.s) {
                Text("\(changed).")
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if current.earlier != nil {
                    Button("Put back the earlier version") { AppServices.shared.putBackEarlierVersion(of: current.id) }
                        .buttonStyle(.panel(.quiet))
                        .help("Give the role what it held before the device changed it. Cards that have the role keep what they have.")
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, 6)
        }
        if let current, !current.matches(card) {
            HStack(spacing: Theme.Space.s) {
                Text("Changed since the role was saved.")
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
                Spacer()
                Button("Reset") { controller.applyRole(current, toCard: card.id) }
                    .buttonStyle(.panel(.quiet))
                    .help("Put this card back to what the role holds")
                Button("Update role") { controller.saveRole(fromCard: card.id) }
                    .buttonStyle(.panel())
                    .help("Save this card's settings into the role. Other agents with the same role can then take them with Reset.")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, 6)
        }
    }

    /// "model", "model and effort", "name, model and effort".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    @ViewBuilder private var condition: some View {
        let check = card.check ?? .judge
        row("Check") {
            MenuField(options: [(value: CheckKind.judge, label: "Ask Claude"), (value: .contains, label: "Message contains"),
                                (value: .notContains, label: "Message doesn't contain"), (value: .regex, label: "Matches a pattern")],
                      selection: check) { v in patch { $0.check = v } }
        }
        LineField(check == .judge ? "What should be true of the message?" : check == .regex ? "Pattern (a regular expression)" : "Text to look for",
                  placeholder: check == .judge ? "The review approves the draft" : "APPROVED",
                  text: card.value ?? "", lines: 1...4) { v in patch { $0.value = v } }
    }

    private func commitName() {
        // The card may have gone while its name was being edited, as when it was deleted.
        guard let current = controller.flow.card(card.id), name != current.name else { return }
        patch { $0.name = name }
        // A refused name (empty, or already taken) snaps back.
        if controller.flow.card(card.id)?.name != name { name = card.name }
    }

    private func patch(_ change: (inout CardPatch) -> Void) {
        var p = CardPatch()
        change(&p)
        controller.update(card.id, p)
    }
}

/// How long an Approval card waits for an answer, and what it answers if none comes. On a Script card, how long
/// a command nobody has allowed yet waits before it is skipped.
private struct WaitSettings: View {
    let card: Card
    let patch: ((inout CardPatch) -> Void) -> Void

    private static let choices = [0, 15, 30, 60, 120, 240, 480, 24 * 60, 2 * 24 * 60, 7 * 24 * 60]

    var body: some View {
        let minutes = card.waitMinutes ?? 0
        let options = (Self.choices + (Self.choices.contains(minutes) ? [] : [minutes])).sorted()
        row(card.kind == .approval ? "Wait for an answer" : "Wait to be allowed") {
            MenuField(options: options.map { (value: $0, label: $0 == 0 ? "As long as it takes" : "Up to \(HoldTimeLimit.describe(minutes: $0))") },
                      selection: minutes) { v in patch { $0.waitMinutes = v } }
        }
        if minutes > 0 {
            if card.kind == .approval {
                row("Then") {
                    MenuField(options: [(value: "rejected", label: "Reject it"), (value: "approved", label: "Approve it")],
                              selection: card.whenNoAnswer ?? "rejected") { v in patch { $0.whenNoAnswer = v } }
                }
            } else {
                note("If nobody lets the command run in time, it is skipped and the run carries on from Fail.")
            }
        }
    }
}

/// A message waiting at an Approval card: read it, change it if need be, then send it on or back.
private struct ApprovalReview: View {
    let controller: FlowController
    let hold: PendingHold
    @State private var draft = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("From \(hold.from). Waiting for you.")
                .font(.dsSans(Theme.Size.caption, .medium))
            if let deadline = hold.deadline, let card = controller.flow.card(hold.cardID) {
                Text("If you don't answer by \(deadline.formatted(date: .omitted, time: .shortened)), it will be \(HoldTimeLimit.port(for: card) == "approved" ? "approved" : "rejected") for you.")
                    .font(.dsSans(Theme.Size.caption))
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $draft)
                .font(.dsSans(Theme.Size.body))
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
                .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.live.ui))
                .foregroundStyle(Theme.ink.ui)
            TextField("Why you're rejecting it (optional)", text: $note, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.dsSans(Theme.Size.body))
                .fieldBox()
                .foregroundStyle(Theme.ink.ui)
            HStack(spacing: Theme.Space.s) {
                Button("Reject") { controller.reject(hold.id, note: note) }
                    .buttonStyle(.panel())
                    .help("Send the message on along the Rejected link, with your reason ahead of it if you gave one")
                Spacer()
                Button(draft == hold.text ? "Approve" : "Approve edited") { controller.approve(hold.id, text: draft) }
                    .buttonStyle(.panel(.live))
                    .help("Send the message on along the Approved link")
            }
        }
        .foregroundStyle(Theme.liveInk.ui)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.liveTint.ui)
        .overlay(alignment: .top) { rule }
        .onAppear { draft = hold.text }
    }
}

/// A Script card whose run is waiting on its command: to be allowed, or to finish.
private struct ScriptReview: View {
    let controller: FlowController
    let hold: PendingHold

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if hold.needsAllow {
                Text("You didn't write this command yourself, so it is waiting for you. Read it, then let it run or skip it."
                     + (hold.deadline.map { " If you haven't by \($0.formatted(date: .omitted, time: .shortened)), it is skipped." } ?? ""))
                    .font(.dsSans(Theme.Size.caption))
                    .fixedSize(horizontal: false, vertical: true)
                Text(hold.command)
                    .font(.dsSans(Theme.Size.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .foregroundStyle(Theme.ink.ui)
                HStack(spacing: Theme.Space.s) {
                    Button("Don't run") { controller.refuseScript(hold.id) }
                        .buttonStyle(.panel())
                    Spacer()
                    Button("Allow and run") { controller.allowScript(hold.id) }
                        .buttonStyle(.panel(.live))
                        .help("Runs the command now. This card won't ask again unless the command changes.")
                }
            } else {
                Text("Running its command…")
                    .font(.dsSans(Theme.Size.caption, .medium))
            }
        }
        .foregroundStyle(Theme.liveInk.ui)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.liveTint.ui)
        .overlay(alignment: .top) { rule }
    }
}

/// What starts runs from a Start card besides the Run button: the clock, or a file changing.
private struct TriggerSettings: View {
    let controller: FlowController
    let card: Card

    private static let intervals = [5, 10, 15, 30, 60, 120, 240, 480, 720, 1440]
    private static let days = [(2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S")]

    private func set(_ change: (inout Trigger) -> Void) {
        var trigger = card.trigger ?? Trigger(kind: .daily)
        change(&trigger)
        controller.setTrigger(trigger, onCard: card.id)
    }

    var body: some View {
        let trigger = card.trigger
        row("Runs") {
            MenuField(options: [(value: "", label: "When you press Run"), (value: "interval", label: "Every so often"),
                                (value: "daily", label: "Every day"), (value: "weekly", label: "On chosen days"),
                                (value: "file", label: "When a file changes")],
                      selection: trigger?.kind.rawValue ?? "") { raw in
                guard let kind = Trigger.Kind(rawValue: raw) else { return controller.setTrigger(nil, onCard: card.id) }
                set { $0.kind = kind }
            }
        }
        if let trigger {
            switch trigger.kind {
            case .interval:
                row("Every") {
                    MenuField(options: (Self.intervals + (Self.intervals.contains(trigger.minutes) ? [] : [trigger.minutes])).sorted()
                                .map { (value: $0, label: Trigger(kind: .interval, minutes: $0).summary.replacingOccurrences(of: "Every ", with: "")) },
                              selection: trigger.minutes) { v in set { $0.minutes = v } }
                }
            case .daily:
                timeRow(trigger)
            case .weekly:
                row("On") {
                    HStack(spacing: 3) {
                        ForEach(Self.days, id: \.0) { day, letter in
                            let isOn = trigger.weekdays.contains(day)
                            Button {
                                set { $0.weekdays = isOn ? $0.weekdays.filter { $0 != day } : ($0.weekdays + [day]).sorted() }
                            } label: {
                                Text(letter)
                                    .font(.dsSans(Theme.Size.caption, .medium))
                                    .frame(width: 20, height: 20)
                                    .foregroundStyle((isOn ? Theme.surface : Theme.ink).ui)
                                    .background((isOn ? Theme.ink : Theme.bar).ui, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                timeRow(trigger)
            case .file:
                LineField("File or folder in the project", placeholder: "inbox", text: trigger.path) { v in set { $0.path = v } }
            }

            if controller.isArmed(card) {
                note(trigger.kind == .file
                     ? "A run starts whenever it changes, and is told which file changed. Queen Bee has to be open, and a change made while a run is going doesn't start another."
                     : "\(controller.nextFires[card.id].map { "Next: \(Self.when($0)). " } ?? "")Queen Bee has to be open for it to run. A run that falls due while another is going is skipped.")
            } else {
                // A schedule that came in the flow's file, or from an undo, hasn't been agreed to here.
                HStack(spacing: Theme.Space.s) {
                    Text("This schedule is switched off. It stays off until you turn it on here.")
                        .font(.dsSans(Theme.Size.caption))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Turn on") { controller.setTrigger(trigger, onCard: card.id) }
                        .buttonStyle(.panel(.live))
                }
                .foregroundStyle(Theme.liveInk.ui)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 6)
                .background(Theme.liveTint.ui)
                .overlay(alignment: .top) { rule }
            }
        }
    }

    private func timeRow(_ trigger: Trigger) -> some View {
        row("At") {
            HStack(spacing: 2) {
                MenuField(options: (0...23).map { (value: $0, label: String(format: "%02d", $0)) }, selection: trigger.hour) { v in set { $0.hour = v } }
                Text(":").font(.dsMono(Theme.Size.caption, .medium))
                MenuField(options: stride(from: 0, to: 60, by: 5).map { (value: $0, label: String(format: "%02d", $0)) } + (trigger.minute % 5 == 0 ? [] : [(value: trigger.minute, label: String(format: "%02d", trigger.minute))]),
                          selection: trigger.minute) { v in set { $0.minute = v } }
            }
        }
    }

    private static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// What a link carried in the run on show, newest first.
private struct LinkMessages: View {
    let messages: [LinkMessage]

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        section {
            field(messages.isEmpty ? "Messages" : messages.count == 1 ? "1 message in this run" : "\(messages.count) messages in this run") {
                if messages.isEmpty {
                    Text("Nothing has gone along this link in the run on show.")
                        .font(.dsSans(Theme.Size.caption))
                        .foregroundStyle(Theme.inkSecondary.ui)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            ForEach(messages.reversed()) { message in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(Self.time.string(from: message.date)) · from \(message.from)")
                                        .font(.dsSans(Theme.Size.caption))
                                        .foregroundStyle(Theme.inkSecondary.ui)
                                    Text(message.text)
                                        .font(.dsSans(Theme.Size.body))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(6)
                                .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
    }
}

/// Starts a run at this card, with a message you give it: by default the last one it received.
private struct RunFromHere: View {
    let controller: FlowController
    let card: Card
    @State private var draft = ""

    var body: some View {
        section {
            field("The message \(card.name) gets") {
                TextEditor(text: $draft)
                    .font(.dsSans(Theme.Size.body))
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 5)
                    .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
                HStack {
                    Button("Cancel") { controller.runFromCardID = nil }
                        .buttonStyle(.panel(.quiet))
                    Spacer()
                    Button("Run from here") {
                        let text = draft
                        controller.runFromCardID = nil
                        Task { await controller.run(from: card.id, message: text) }
                    }
                    .buttonStyle(.panel(.filled))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isRunning)
                }
                .padding(.top, 2)
            }
        }
        .onAppear { draft = controller.lastMessage(into: card.id)?.text ?? "" }
    }
}

/// What can be done to several cards at once.
private struct SeveralSettings: View {
    let controller: FlowController
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text("\(count) cards")
                    .font(.dsSans(Theme.Size.title, .medium))
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.bar.ui)
            if let group = controller.selectedGroup {
                GroupName(controller: controller, group: group)
                    .id(group.id)
                note(group.isFolded ? "Folded into one card. Its cards keep working, and links to them meet the group's edge."
                     : "Drag the group by its name. Fold it to show its cards as one.")
            } else {
                note("Drag any of them to move them together, or use the arrow keys. Shift-click a card to add it or take it out.")
            }
            HStack(spacing: Theme.Space.s) {
                Button { controller.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.panel(.quiet))
                Spacer()
                if let group = controller.selectedGroup {
                    Button("Ungroup") { controller.ungroupSelection() }
                        .buttonStyle(.panel(.quiet))
                    Button(group.isFolded ? "Unfold" : "Fold") { controller.setFolded(!group.isFolded, group: group.id) }
                        .buttonStyle(.panel())
                } else {
                    Button("Duplicate") { controller.duplicateSelection() }
                        .buttonStyle(.panel(.quiet))
                    Button("Group") { controller.groupSelection() }
                        .buttonStyle(.panel())
                        .help("Frame these cards together under a name. A group can be folded into one card.")
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .background(Theme.bar.ui)
            .overlay(alignment: .top) { rule }
        }
        .animation(Theme.Motion.quick, value: count)
    }
}

/// A group's name, edited where it stands.
private struct GroupName: View {
    let controller: FlowController
    let group: CardGroup
    @State private var name = ""

    var body: some View {
        section {
            field("Group") {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.dsSans(Theme.Size.body, .medium))
                    .fieldBox()
                    .onAppear { name = group.name }
                    .onChange(of: name) { if name != group.name, !name.trimmingCharacters(in: .whitespaces).isEmpty { controller.rename(group: group.id, to: name) } }
            }
        }
    }
}

private struct LinkSettings: View {
    let controller: FlowController
    let link: QueenBeeCore.Link

    var body: some View {
        let from = controller.flow.card(link.from)?.name ?? "?"
        let to = controller.flow.card(link.to)?.name ?? "?"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(link.port == "out" ? "\(from) → \(to)" : "\(from) · \(portLabel(link.port)) → \(to)")
                    .font(.dsSans(Theme.Size.title, .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Link")
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.bar.ui)
            row("Limit per run") {
                StepField(value: link.maxPasses, range: 1...50) { controller.setMaxPasses(link.id, $0) }
            }
            note("This link carries at most this many messages in one run. The limit is what stops a loop from going round for ever.")
            LinkMessages(messages: controller.messages[link.id] ?? [])
            HStack {
                Button { controller.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.panel(.quiet))
                    .help("Delete this link")
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .background(Theme.bar.ui)
            .overlay(alignment: .top) { rule }
        }
    }
}

// MARK: Small building blocks

/// The hairline between a panel's parts.
private var rule: some View {
    Rectangle().fill(Theme.hairline.ui).frame(height: 1)
}

/// One part of the panel, ruled off from the part above it.
private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .top) { rule }
}

/// A one-line setting: what it is on the left, its value on the right.
private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: Theme.Space.s) {
        Text(title).font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui)
        Spacer(minLength: Theme.Space.s)
        content()
    }
    .padding(.horizontal, Theme.Space.m)
    .frame(minHeight: 30)
    .overlay(alignment: .top) { rule }
}

private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui)
        content()
    }
}

/// A sentence of help under the setting it explains.
private func note(_ text: String) -> some View {
    section {
        Text(text).font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui).fixedSize(horizontal: false, vertical: true)
    }
}

/// A short text setting that keeps its own draft while you type and writes each change through.
private struct LineField: View {
    let title: String
    let placeholder: String
    let text: String
    var lines: ClosedRange<Int> = 1...1
    let commit: (String) -> Void
    @State private var draft = ""

    init(_ title: String, placeholder: String, text: String, lines: ClosedRange<Int> = 1...1, commit: @escaping (String) -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.text = text
        self.lines = lines
        self.commit = commit
    }

    var body: some View {
        section {
            field(title) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(lines)
                    .textFieldStyle(.plain)
                    .font(.dsSans(Theme.Size.body))
                    .fieldBox()
                    .onAppear { draft = text }
                    .onChange(of: draft) { if draft != text { commit(draft) } }
                    .onChange(of: text) { if text != draft { draft = text } }
            }
        }
    }
}

/// A multi-line text box that keeps its own draft while you type and writes each change through.
private struct EditorField: View {
    let title: String
    let text: String
    var mono = false
    let commit: (String) -> Void
    @State private var draft = ""

    init(_ title: String, text: String, mono: Bool = false, commit: @escaping (String) -> Void) {
        self.title = title
        self.text = text
        self.mono = mono
        self.commit = commit
    }

    var body: some View {
        section {
            field(title) {
                TextEditor(text: $draft)
                    .font(mono ? .dsMono(Theme.Size.caption) : .dsSans(Theme.Size.body))
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 5)
                    .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
                    .onAppear { draft = text }
                    .onChange(of: draft) { if draft != text { commit(draft) } }
                    .onChange(of: text) { if text != draft { draft = text } }
            }
        }
    }
}
