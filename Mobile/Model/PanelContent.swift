import Foundation
import QueenBeeCore

/// What the panels say, worked out from what the Mac sent. Each of these mirrors something the Mac's
/// `FlowController` works out for its own panels, reading the snapshot where the Mac reads itself. They are
/// plain values, so a test can read exactly what a panel shows without looking at the screen.

/// Times as the Mac's panels write them.
nonisolated enum Clock {
    private static func style(_ format: Date.FormatString) -> Date.VerbatimFormatStyle {
        Date.VerbatimFormatStyle(format: format, locale: .current, timeZone: .current, calendar: .current)
    }

    /// "14:02:09", for a line of the log or a message.
    static func time(_ date: Date) -> String {
        date.formatted(style("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)"))
    }

    /// When a run began: "14:02" today, "3 Oct 14:02" before that.
    static func run(_ date: Date) -> String {
        let clock = date.formatted(style("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)"))
        return Calendar.current.isDateInToday(date) ? clock : date.formatted(style("\(day: .defaultDigits) \(month: .abbreviated)")) + " " + clock
    }

    /// How long a run took: "42 sec", "3 min 5 sec", "1 hr 4 min".
    static func length(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if seconds < 60 { return "\(seconds) sec" }
        if seconds < 3600 { return "\(seconds / 60) min \(seconds % 60) sec" }
        return "\(seconds / 3600) hr \(seconds % 3600 / 60) min"
    }
}

/// The run the panels and the canvas are showing: the latest, or an earlier one picked on this device.
nonisolated struct RunOnShow: Equatable {
    /// The earlier run being looked at. Nil for the latest.
    var earlier: RunRecord?
    var isRunning: Bool
    var log: [LogLine]
    var results: [String: String]
    var messages: [String: [LinkMessage]]
    var marks: [String: RunMark]
    /// Messages waiting at cards. An earlier run is over, so it has none.
    var holds: [PendingHold]
    /// What each card used in this run, by card id. While a run is going, what it has used so far, when the Mac
    /// says. Nil for a moment after it ends: the Mac works a run's share out once the run is over.
    var usage: [String: Usage]?

    /// The Mac's `shownLog`, `view(run:)` and `runUsage(forCard:)`.
    init(_ snapshot: RemoteFlowSnapshot, viewed: RunRecord?) {
        let run = snapshot.run
        earlier = viewed
        isRunning = viewed == nil && run.isRunning
        log = viewed?.log ?? snapshot.log
        results = viewed?.results ?? run.results
        messages = viewed?.messages ?? snapshot.messages
        marks = viewed?.marks ?? run.marks
        holds = viewed == nil ? run.holds : []
        usage = isRunning ? (run.runUsage.isEmpty ? nil : run.runUsage) : (viewed ?? snapshot.runs.last)?.usage
    }
}

/// A card that is waiting on the person.
nonisolated struct WaitingCard: Equatable, Identifiable {
    var id: String
    var name: String
    var kind: CardKind
    /// What it is waiting for, in a few words.
    var reason: String

    static let answer = "Answer on your Mac for now."

    /// The Mac's `cardsNeedingYou`, in canvas order: agents whose session is waiting on the person, approvals
    /// holding a message, and scripts whose command hasn't been allowed. This is always about now, whichever
    /// run is on show.
    static func all(in snapshot: RemoteFlowSnapshot) -> [WaitingCard] {
        let run = snapshot.run
        let held = run.holds.filter { $0.kind == .approval || $0.needsAllow }
        return snapshot.flow.cards.compactMap { card in
            if let hold = held.first(where: { $0.cardID == card.id }) {
                return WaitingCard(id: card.id, name: card.name, kind: card.kind,
                                   reason: hold.kind == .approval ? "Waiting for you to approve"
                                       : hold.allowOnMac == true ? "Waiting for you to allow its command on your Mac" : "Waiting for you to let its command run")
            }
            if card.kind == .agent, run.sessions[card.id] == .needsYou {
                return WaitingCard(id: card.id, name: card.name, kind: card.kind, reason: "Waiting for you in its terminal")
            }
            return nil
        }
    }
}

/// One line of the details panel.
nonisolated struct DetailItem: Equatable {
    enum Style: String {
        /// A one-line setting: its name on the left, what it is set to on the right.
        case row
        /// A setting that is a sentence or more, under its name.
        case text
        /// The same, for a command.
        case code
        /// A sentence of help.
        case note
        /// A sentence to take care over: what changing something from here will do.
        case caution
        /// Something wrong with the card's wiring.
        case warning
        /// The card is holding a message. The value is the message, or the command to be allowed.
        case waiting
        /// The run stopped at the card.
        case stopped
        /// Settings an agent's running session doesn't have yet, as the Mac's "Not in use yet" line says.
        case pending
    }

    var style: Style
    var label: String
    var value = ""
    /// The value is a command, to be read letter for letter.
    var isCode = false
}

/// What the details panel says about the selected card, link or group: the Mac's `InspectorView`, with each
/// setting as words in place of a control. The names and the help are the Mac's. With editing on, `EditForm`
/// takes its place.
nonisolated struct Details: Equatable {
    var icon: String
    var title: String
    /// What kind of thing it is, beside its name.
    var kind: String
    /// An agent's session, for the badge beside its name.
    var state: SessionState?
    var items: [DetailItem] = []
    /// Set while the person is being waited on here.
    var answerLine = false
    /// A link's messages in the run on show, oldest first. Nil for anything but a link.
    var messages: [LinkMessage]?

    static let changes = "Changes are made on your Mac for now."

    init?(selection: CanvasModel.Selection, snapshot: RemoteFlowSnapshot, run: RunOnShow, siblings: [RemoteFlowSummary], roles: [RemoteRole] = []) {
        let flow = snapshot.flow
        switch selection {
        case .none, .cards:
            // Several cards have no details in common to show.
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
        }
    }

    init(card: Card, snapshot: RemoteFlowSnapshot, run: RunOnShow, siblings: [RemoteFlowSummary], roles: [RemoteRole] = []) {
        let flow = snapshot.flow
        icon = CanvasGeometry.icon(for: card.kind)
        title = card.name
        kind = card.kind.label
        func add(_ style: DetailItem.Style, _ label: String, _ value: String = "") { items.append(DetailItem(style: style, label: label, value: value)) }
        func said(_ text: String?) -> String {
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "None" : trimmed
        }
        let hold = run.holds.first { $0.cardID == card.id }

        switch card.kind {
        case .agent:
            state = run.earlier == nil ? snapshot.run.sessions[card.id] ?? .notStarted : nil
            add(.text, "Instructions", said(card.instructions))
            if let id = card.role, !id.isEmpty, let role = roles.first(where: { $0.id == id }) {
                add(.row, "Role", role.name)
                if !role.matches(card) { add(.note, EditForm.roleDrift) }
            }
            let model = card.model ?? ""
            add(.row, "Model", model.isEmpty ? "Your default" : ["fable", "opus", "sonnet", "haiku"].contains(model) ? model.capitalized : model)
            add(.row, "Effort", (card.effort ?? "").isEmpty ? "Model default" : card.effort ?? "")
            if let all = snapshot.run.usage[card.id], !all.isZero {
                let inRun = run.usage?[card.id]
                add(.row, "Cost", inRun.map { $0.isZero ? "\(all.price) in all" : "\($0.price) this run · \(all.price) in all" } ?? "\(all.price) in all")
            }
            let modes = ["": "Your default", "manual": "Manual", "acceptEdits": "Accept edits", "plan": "Plan", "auto": "Auto"]
            add(.row, "Permissions", modes[card.permissionMode ?? ""] ?? card.permissionMode ?? "")
            add(.row, "Browser", card.browser == true ? "On" : "Off")
            if let folder = card.cwd, !folder.isEmpty { add(.row, "Folder", folder) }
            // What the session on the Mac is still going by, which the Mac says beside Restart to apply.
            if let state, state != .notStarted, state != .exited, let names = snapshot.run.awaitingRestart[card.id], !names.isEmpty {
                add(.pending, EditForm.notInUseYet(names))
            }
            if state == .needsYou {
                add(.waiting, "Waiting for you in its terminal.")
                answerLine = true
            }
        case .start:
            add(.text, "What the run starts with", said(card.command))
            if flow.isSubflow == true {
                add(.note, "This is a sub-flow. When a Flow card runs it, the message that card was given is used in place of the text above. The text above is for trying the sub-flow by itself.")
            }
            Self.schedule(card.trigger, isOn: snapshot.edit.armed.contains(card.id), next: snapshot.edit.nextFires[card.id]).forEach { items.append($0) }
        case .ifElse:
            Self.condition(card).forEach { items.append($0) }
        case .loop:
            Self.condition(card).forEach { items.append($0) }
            let tries = card.maxTries ?? 3
            add(.row, "Give up after", "\(tries) \(tries == 1 ? "try" : "tries")")
        case .switchCard:
            add(.text, "Branches", said((card.branches ?? []).joined(separator: ", ")))
            add(.note, "Claude reads each message and sends it down the branch it fits best. A message that fits none of them goes out Other.")
        case .prompt:
            add(.text, "Rewrite the message as", said(card.template))
            add(.note, "{{message}} is where the incoming message goes, and {{from}} is the name of the card it came from. With no {{message}}, the message is added at the end.")
        case .end:
            add(.row, "Save the answer to a file", (card.saveTo ?? "").isEmpty ? "Not saved" : card.saveTo ?? "")
            if let result = run.results[card.id] { add(.text, run.earlier == nil ? "Latest answer" : "Answer in this run", result) }
        case .and:
            add(.note, "Waits until every card linked into it has answered, then passes all their answers on together.")
        case .or:
            add(.note, "Passes on whichever answer arrives first in a run and ignores the rest.")
        case .note:
            add(.text, "Note", said(card.text))
        case .approval:
            add(.text, "What to check before approving", said(card.text))
            if let hold {
                // A card's name may end in a mark of its own, as "Short enough?" does.
                let stop = hold.from.last.map { "?!.".contains($0) } == true ? "" : "."
                add(.waiting, "From \(hold.from)\(stop) Waiting for you.", hold.text)
                answerLine = true
            } else {
                add(.note, "A run stops here and waits for you. On your Mac you can edit the message, then approve or reject it.")
            }
        case .flow:
            add(.row, "Runs", CanvasContent.innerFlow(of: card, in: siblings, excluding: flow.id)?.name ?? "Nothing yet")
            add(.note, "This card runs a whole flow as one step. The message that arrives here goes to that flow's Input, and what reaches its Output comes back out Done. If it stops early or fails, the message goes out Fail.")
            if let hold { add(.waiting, "Running \(hold.command)…") }
        case .script:
            add(.code, "Command", said(card.command))
            add(.note, "Runs this command in the project's folder, as if you had typed it in Terminal. If the command succeeds, the run carries on from Pass. If it fails, from Fail. Whatever the command prints is what gets passed on.")
            if let hold {
                if hold.needsAllow {
                    // In place of the Allow button, for a command a device wrote: the Mac's own words for refusing it.
                    let label = hold.allowOnMac == true ? Remote.allowOnMacRefusal
                        : "You didn't write this command yourself, so it is waiting for you. Read it, then let it run or skip it."
                    items.append(DetailItem(style: .waiting, label: label, value: hold.command, isCode: true))
                    answerLine = true
                } else {
                    add(.waiting, "Running its command…")
                }
            }
        }

        if let warning = QueenBeeCore.warnings(for: flow)[card.id] { add(.warning, warning) }
        if run.marks[card.id]?.failed == true, !run.isRunning { add(.stopped, "The run stopped here.") }
    }

    init(link: QueenBeeCore.Link, flow: Flow, run: RunOnShow) {
        let from = flow.card(link.from)?.name ?? "?", to = flow.card(link.to)?.name ?? "?"
        icon = "arrow.right"
        title = link.port == "out" ? "\(from) → \(to)" : "\(from) · \(portLabel(link.port)) → \(to)"
        kind = "Link"
        items = [
            DetailItem(style: .row, label: "Limit per run", value: "\(link.maxPasses)"),
            DetailItem(style: .note, label: "This link carries at most this many messages in one run. The limit is what stops a loop from going round for ever."),
        ]
        messages = run.messages[link.id] ?? []
    }

    init(group: CardGroup, flow: Flow) {
        let members = flow.cards.filter { group.cardIDs.contains($0.id) }
        icon = "square.on.square.dashed"
        title = group.name
        kind = "Group"
        items = [
            DetailItem(style: .row, label: "Cards", value: "\(members.count)"),
            DetailItem(style: .text, label: "In this group", value: members.map(\.name).joined(separator: ", ")),
            DetailItem(style: .note, label: group.isFolded ? "Folded into one card. Its cards keep working, and links to them meet the group's edge."
                       : "These cards are framed together under a name. On your Mac the group can be folded to show its cards as one."),
        ]
    }

    /// The heading over a link's messages, as the Mac counts them.
    var messagesTitle: String {
        let count = messages?.count ?? 0
        return count == 0 ? "Messages" : count == 1 ? "1 message in this run" : "\(count) messages in this run"
    }

    /// How an If or Loop card checks a message.
    private static func condition(_ card: Card) -> [DetailItem] {
        let check = card.check ?? .judge
        let named = switch check {
        case .judge: "Ask Claude"
        case .contains: "Message contains"
        case .notContains: "Message doesn't contain"
        case .regex: "Matches a pattern"
        }
        let asks = check == .judge ? "What should be true of the message?" : check == .regex ? "Pattern (a regular expression)" : "Text to look for"
        let value = (card.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [DetailItem(style: .row, label: "Check", value: named), DetailItem(style: .text, label: asks, value: value.isEmpty ? "None" : value)]
    }

    /// What starts runs from a Start card besides the Run button.
    private static func schedule(_ trigger: Trigger?, isOn: Bool, next: Date?) -> [DetailItem] {
        guard let trigger else { return [DetailItem(style: .row, label: "Runs", value: "When you press Run")] }
        let clock = String(format: "%02d:%02d", min(max(trigger.hour, 0), 23), min(max(trigger.minute, 0), 59))
        var items: [DetailItem] = []
        switch trigger.kind {
        case .interval:
            items.append(DetailItem(style: .row, label: "Runs", value: "Every so often"))
            items.append(DetailItem(style: .row, label: "Every", value: trigger.summary.replacingOccurrences(of: "Every ", with: "")))
        case .daily:
            items.append(DetailItem(style: .row, label: "Runs", value: "Every day"))
            items.append(DetailItem(style: .row, label: "At", value: clock))
        case .weekly:
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let days = trigger.weekdays.filter { (1...7).contains($0) }.sorted().map { names[$0 - 1] }
            items.append(DetailItem(style: .row, label: "Runs", value: "On chosen days"))
            items.append(DetailItem(style: .row, label: "On", value: days.isEmpty ? "No day chosen" : days.joined(separator: ", ")))
            items.append(DetailItem(style: .row, label: "At", value: clock))
        case .file:
            let path = trigger.path.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(DetailItem(style: .row, label: "Runs", value: "When a file changes"))
            items.append(DetailItem(style: .row, label: "File or folder in the project", value: path.isEmpty ? "No file chosen" : path))
        }
        items.append(DetailItem(style: .note, label: isOn
            ? "This schedule is on. \(next.map { "Next: \(Clock.run($0)). " } ?? "")Queen Bee has to be open on your Mac for it to run."
            : "This schedule is switched off. It only runs once it is turned on."))
        return items
    }
}

/// One earlier run, as the list of runs shows it.
nonisolated struct RunRow: Equatable, Identifiable {
    var id: String
    /// When it began.
    var started: String
    var outcome: RunRecord.Outcome
    var length: String
    var command: String
    var handOffs: String
    /// What it would have cost. Nil until the Mac has worked it out.
    var cost: String?
    /// It is the run the canvas and the panels are showing.
    var isOnShow: Bool

    /// Every kept run, newest first.
    static func all(in snapshot: RemoteFlowSnapshot, viewed: RunRecord?) -> [RunRow] {
        // With nothing picked the latest run is on show, unless another is going now.
        let shown = viewed?.id ?? (snapshot.run.isRunning ? nil : snapshot.runs.last?.id)
        return snapshot.runs.reversed().map { run in
            RunRow(id: run.id, started: Clock.run(run.started), outcome: run.outcome, length: Clock.length(from: run.started, to: run.ended),
                   command: run.command, handOffs: "\(run.handOffs) \(run.handOffs == 1 ? "hand-off" : "hand-offs")",
                   cost: run.usage == nil ? nil : run.cost.price, isOnShow: run.id == shown)
        }
    }

    /// Read out as one sentence.
    var spoken: String {
        "Run from \(started), \(outcome.rawValue), took \(length), \(handOffs)\(cost.map { ", cost \($0)" } ?? ""). \(command)\(isOnShow ? ". On show." : "")"
    }
}

/// Where the cost went: the Mac's `CostBreakdown`, for the flow so far and for the run on show.
nonisolated struct CostSheet: Equatable {
    struct Line: Equatable, Identifiable {
        var id: String
        var name: String
        var icon: String
        var usage: Usage
        /// Its part of the whole, from 0 to 1, for the bar under it.
        var share: Double
    }

    /// Everything the flow's own sessions have used, the orchestrator included.
    var total: Usage
    /// Each session that has used anything, dearest first.
    var sessions: [Line]
    /// "Latest run", or when the earlier run on show began.
    var runTitle: String
    /// What the run on show used, card by card in canvas order. Nil when there is no figure for it yet.
    var runLines: [Line]?
    var runTotal: Usage?
    /// Why there is no figure for the run, when there isn't.
    var runPending: String?
    /// The run's figure is what it has used so far: it is still going.
    var runSoFar = false
    /// The sub-flows below this flow, each with what its own sessions used and how far down it is. Empty when there are none.
    var subflows: [Subflow] = []
    /// What this flow and every sub-flow below it have used, as the Mac's cost pill counts it.
    var withSubflows: Usage?
    /// The flow above, when this is one of its sub-flows: "Part of X", and what that flow has used with all of its own.
    var outer: (id: String, name: String, usage: Usage)?

    struct Subflow: Equatable, Identifiable {
        var id: String
        var name: String
        var depth: Int
        var usage: Usage
        var share: Double
    }

    static func == (a: CostSheet, b: CostSheet) -> Bool {
        a.total == b.total && a.sessions == b.sessions && a.runTitle == b.runTitle && a.runLines == b.runLines && a.runTotal == b.runTotal
            && a.runPending == b.runPending && a.runSoFar == b.runSoFar && a.subflows == b.subflows && a.withSubflows == b.withSubflows
            && a.outer?.id == b.outer?.id && a.outer?.usage == b.outer?.usage
    }

    static let orchestratorKey = "orchestrator"
    static let explanation = "An estimate of what this work would cost if you paid Anthropic by usage. On a Claude subscription you don't pay this, so read it as a measure of how much the flow uses. It updates each time an agent finishes a reply. A run's figure covers the agents and sub-flows it used, not the orchestrator."

    /// - Parameter flows: the project's flows as the Mac lists them, for the sub-flows below this one and the flow above.
    init(_ snapshot: RemoteFlowSnapshot, run: RunOnShow, flows: [RemoteFlowSummary] = []) {
        let flow = snapshot.flow, used = snapshot.run.usage
        total = used.values.reduce(Usage(), +)
        let whole = max(total.cost, 0.000001)
        var rows: [Line] = []
        if let orchestrator = used[Self.orchestratorKey], !orchestrator.isZero {
            rows.append(Line(id: Self.orchestratorKey, name: "Orchestrator", icon: "sparkles", usage: orchestrator, share: orchestrator.cost / whole))
        }
        for card in flow.cards where card.kind == .agent {
            if let usage = used[card.id], !usage.isZero {
                rows.append(Line(id: card.id, name: card.name, icon: "terminal", usage: usage, share: usage.cost / whole))
            }
        }
        sessions = rows.sorted { $0.usage.cost > $1.usage.cost }

        runTitle = run.earlier.map { "Run from \(Clock.run($0.started))" } ?? "Latest run"
        if let spent = run.usage {
            let all = spent.values.reduce(Usage(), +)
            let most = max(all.cost, 0.000001)
            var lines = flow.cards.compactMap { card -> Line? in
                guard let usage = spent[card.id], !usage.isZero else { return nil }
                return Line(id: card.id, name: card.name, icon: CanvasGeometry.icon(for: card.kind), usage: usage, share: usage.cost / most)
            }
            // A card that used something and has since been deleted still counts towards the run.
            let gone = spent.filter { flow.card($0.key) == nil }.values.reduce(Usage(), +)
            if !gone.isZero { lines.append(Line(id: "", name: "Cards since deleted", icon: "trash", usage: gone, share: gone.cost / most)) }
            runLines = lines
            runTotal = all
            runSoFar = run.isRunning
        } else if run.isRunning {
            runPending = "This run's figure appears a moment after it ends."
        } else if run.earlier != nil || !snapshot.runs.isEmpty {
            runPending = "There is no figure for this run."
        } else {
            runPending = "No run yet."
        }
        // The Mac's breakdown has the sub-flows below this one, each under the flow that runs it.
        let listed = flows.first { $0.id == flow.id }
        withSubflows = listed?.usageWithSubflows
        var below: [Subflow] = []
        func add(under parent: String, depth: Int) {
            for child in flows where child.parentID == parent && !below.contains(where: { $0.id == child.id }) {
                below.append(Subflow(id: child.id, name: child.name, depth: depth, usage: child.usage ?? Usage(), share: 0))
                add(under: child.id, depth: depth + 1)
            }
        }
        add(under: flow.id, depth: 0)
        let all = max((withSubflows ?? total).cost, 0.000001)
        subflows = below.map { var line = $0; line.share = line.usage.cost / all; return line }
        if let parent = listed?.parentID, let above = flows.first(where: { $0.id == parent }) {
            outer = (above.id, above.name, above.usageWithSubflows ?? above.usage ?? Usage())
        }
    }
}
