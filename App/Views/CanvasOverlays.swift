import QueenBeeCore
import QueenBeeDesign
import SwiftUI
import UniformTypeIdentifiers

/// The card types, floating at the canvas's corner. Click one to add it at the middle of
/// what's on screen, or drag it to where you want it.
struct PaletteView: View {
    static let width: CGFloat = 132
    let controller: FlowController
    private var services: AppServices { AppServices.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CardKindMenu.kinds, id: \.self) { kind in
                PaletteRow(kind: kind) { controller.addCard(kind) }
                if kind == .agent {
                    // Saved roles sit under Agent: each makes an agent that is already set up.
                    ForEach(services.roles) { role in
                        PaletteRow(kind: .agent, role: role) { controller.addCard(.agent, role: role) }
                            .contextMenu {
                                if role.earlier != nil {
                                    Button("Put Back the Earlier Version") { services.putBackEarlierVersion(of: role.id) }
                                }
                                Button("Delete Role", role: .destructive) { services.deleteRole(role.id) }
                            }
                    }
                    Rectangle().fill(Theme.hairline.ui).frame(height: 1).padding(.vertical, 3)
                }
            }
        }
        .padding(Theme.Space.xs)
        .frame(width: Self.width)
        .floatingPanel()
    }
}

private struct PaletteRow: View {
    let kind: CardKind
    /// A saved role, when the row stands for one and not for the plain kind.
    var role: AgentRole?
    let add: () -> Void
    @State private var isHovered = false
    /// The pointer has rested on the row long enough to want to know what the card is.
    @State private var showsHelp = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: role == nil ? CanvasGeometry.icon(for: kind) : "person.crop.square")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16)
            Text(role?.name ?? kind.label)
                .font(.dsSans(Theme.Size.caption, role == nil ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            // A role a paired device saved or changed, which the Mac asks about before it is first used.
            if let changed = role?.changedLine {
                Image(systemName: "ipad.and.iphone")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .help(changed)
                    .accessibilityLabel(changed)
            }
        }
        .foregroundStyle(Theme.ink.ui)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 5)
        .background(isHovered ? Theme.barHover.ui : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .task(id: isHovered) {
            guard isHovered else { return showsHelp = false }
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { showsHelp = true }
        }
        // Beside the palette, level with the row, and never in the pointer's way.
        .overlay(alignment: .topLeading) {
            if showsHelp {
                CardHelpView(kind: kind, role: role)
                    .offset(x: PaletteView.width + Theme.Space.xs)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(x: -6)))
            }
        }
        .zIndex(showsHelp ? 1 : 0)
        .animation(Theme.Motion.standard, value: showsHelp)
        .onTapGesture(perform: add)
        .onDrag {
            // A type of the app's own, so a terminal under the pointer leaves the drop for the canvas.
            let provider = NSItemProvider()
            let type = CanvasDocumentView.cardKindType.rawValue
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { done in
                done(Data((role.map { "\(kind.rawValue)@\($0.id)" } ?? kind.rawValue).utf8), nil)
                return nil
            }
            return provider
        }
        .animation(Theme.Motion.quick, value: isHovered)
    }
}

/// What a kind of card does, in a sentence anyone can follow, and one small example.
struct CardHelpView: View {
    let kind: CardKind
    var role: AgentRole?

    var body: some View {
        let help = role.map(CardHelp.text(for:)) ?? CardHelp.text(for: kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: role == nil ? CanvasGeometry.icon(for: kind) : "person.crop.square").font(.system(size: 11, weight: .medium))
                Text(role?.name ?? kind.label).font(.dsSans(Theme.Size.body, .medium))
            }
            Text(help.what)
                .font(.dsSans(Theme.Size.body))
                .fixedSize(horizontal: false, vertical: true)
            if let changed = role?.changedLine {
                Text("\(changed). You're asked before it is first used.")
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(role == nil ? "For example" : "Its instructions").font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui)
                Text(help.example)
                    .font(.dsSans(Theme.Size.caption))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
            Text("Click to add it, or drag it onto the canvas.")
                .font(.dsSans(Theme.Size.caption))
                .foregroundStyle(Theme.inkSecondary.ui)
        }
        .foregroundStyle(Theme.ink.ui)
        .padding(Theme.Space.m)
        .frame(width: 250, alignment: .leading)
        .floatingPanel()
    }
}

enum CardHelp {
    /// A saved role: what it is, and the start of what it tells its agent.
    static func text(for role: AgentRole) -> (what: String, example: String) {
        let settings = [role.model.isEmpty ? nil : role.model.capitalized, role.effort.isEmpty ? nil : "\(role.effort) effort",
                        role.permissionMode.isEmpty ? nil : role.permissionMode].compactMap { $0 }.joined(separator: ", ")
        let brief = role.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return ("A saved role. It adds an agent that is already set up\(settings.isEmpty ? "" : ": \(settings)"). Right-click to delete the role.",
                brief.isEmpty ? "No instructions." : String(brief.prefix(220)) + (brief.count > 220 ? "…" : ""))
    }

    static func text(for kind: CardKind) -> (what: String, example: String) {
        switch kind {
        case .agent:
            ("A live Claude Code agent that does one job. It is given a message, does the work, and its reply goes to whatever it is linked to.",
             "A Writer drafts a slogan, and the draft goes on to a Reviewer.")
        case .start:
            ("Where a run begins. It holds the first message and sends it when you press Run.",
             "“Write a slogan for a neighbourhood bakery.”")
        case .ifElse:
            ("Asks a yes-or-no question about the message. The message goes out Yes or out No.",
             "“Does the review approve the draft?” Yes goes to Done. No goes back to the Writer.")
        case .switchCard:
            ("Sorts each message into one of several branches that you name. Claude reads the message and picks the branch that fits. A message that fits none goes out Other.",
             "With branches bug, feature and question, a crash report goes out bug and reaches the agent that fixes bugs.")
        case .and:
            ("Waits until every card linked into it has answered, then passes all the answers on together.",
             "Three researchers each report back, and one Writer gets all three reports at once.")
        case .or:
            ("Passes on the first answer to arrive and ignores the ones that come after.",
             "Ask two agents the same question and use whichever answers first.")
        case .prompt:
            ("Rewrites the message before it goes on, using a template you write.",
             "“Summarise this in one line: {{message}}” turns a long report into a short brief for the next agent.")
        case .loop:
            ("Sends the work round again until a condition is met, or until it has tried enough times.",
             "Again goes back to the Writer until the review approves, for at most 3 tries. Then Done, or Gave up if it never did.")
        case .approval:
            ("Stops the run and waits for you. You read the message, change it if you like, then approve or reject it.",
             "Before an agent sends an email: Approved goes to the sender, Rejected goes back to the Writer.")
        case .script:
            ("Runs a command on your Mac and checks whether it worked. No AI is involved, so it is quick and certain.",
             "Run “npm test”. Pass goes to Done. Fail goes back to the Coder with the errors.")
        case .forEach:
            ("Splits a list into items and sends them on one at a time. What comes back for each is collected, and when every item is done they all go out Done together.",
             "A list of ten links goes to a Reader one at a time, and the ten summaries go on to a Writer together.")
        case .flow:
            ("Runs another of the project's flows as a single step. Build a piece once, then use it wherever you need it.",
             "A “Review loop” flow of four cards becomes one card in three other flows.")
        case .end:
            ("Where a run's answer lands. It shows the final answer and can save it to a file.",
             "Save the approved slogan to slogan.txt.")
        case .note:
            ("A sticky note for people. Agents never see it.",
             "“Ask Priya before changing the Reviewer's instructions.”")
        }
    }
}

/// Zoom out, the zoom level, zoom in, and fit, pinned to the canvas's corner.
struct ZoomPill: View {
    let controller: FlowController
    @AppStorage("showsMinimap") private var showsMinimap = true

    var body: some View {
        HStack(spacing: 2) {
            button("minus", help: "Zoom out") { controller.canvas?.zoom(by: 0.8) }
            Button { controller.canvas?.zoomToActualSize() } label: {
                Text("\(Int((controller.zoom * 100).rounded()))%")
                    .textRole(.monoCaption)
                    .foregroundStyle(Palette.textMuted.color)
                    .frame(width: 40)
            }
            .buttonStyle(.plain)
            .help("Back to 100%")
            button("plus", help: "Zoom in") { controller.canvas?.zoom(by: 1.25) }
            DSDivider(vertical: true).frame(height: 14).padding(.horizontal, 2)
            button("arrow.up.left.and.arrow.down.right", help: "Fit the whole flow") { controller.canvas?.zoomToFit() }
            button(showsMinimap ? "map.fill" : "map", help: showsMinimap ? "Hide the map of the flow" : "Show a map of the whole flow") { showsMinimap.toggle() }
        }
        .padding(.horizontal, 3)
        .frame(height: 30)
        .floatingPanel()
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.dsIcon)
            .controlSize(.small)
            .frame(width: 24, height: 24)
            .accessibilityLabel(help)
            .help(help)
    }
}

/// The whole flow in a corner: every card, what is live or waiting, and the part the window
/// is showing. Click or drag in it to go there.
struct Minimap: View {
    static let size = CGSize(width: 190, height: 124)
    let controller: FlowController

    var body: some View {
        let flow = controller.flow
        let frames = flow.cards.map(CanvasGeometry.frame(of:))
        // The map is of the flow, so the cards fill it. The window's view is drawn over them and
        // runs off the map's edge when it takes in more than the flow.
        let world = (frames.isEmpty ? controller.viewport : frames.reduce(CGRect.null) { $0.union($1) }).insetBy(dx: -80, dy: -80)
        let scale = world.isNull || world.width <= 0 ? 1 : min(Self.size.width / world.width, Self.size.height / world.height)
        // The flow is drawn in the middle of the map, whatever its shape.
        let inset = CGSize(width: (Self.size.width - world.width * scale) / 2, height: (Self.size.height - world.height * scale) / 2)
        let waiting = Set(controller.cardsNeedingYou.map(\.id))
        let selected = controller.selection.cardIDs

        Canvas { context, _ in
            func place(_ rect: CGRect) -> CGRect {
                CGRect(x: inset.width + (rect.minX - world.minX) * scale, y: inset.height + (rect.minY - world.minY) * scale,
                       width: max(2, rect.width * scale), height: max(2, rect.height * scale))
            }
            for card in flow.cards {
                let rect = place(CanvasGeometry.frame(of: card))
                let failed = controller.marks[card.id]?.failed == true
                let live = waiting.contains(card.id) || controller.holds.contains { $0.cardID == card.id }
                    || (card.kind == .agent && [.working, .needsYou].contains(controller.sessions[card.id]?.state ?? .notStarted))
                let fill = failed ? Palette.fail : live ? Palette.live : card.kind == .agent ? Palette.textMuted : Palette.textFaint
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(fill.color.opacity(waiting.contains(card.id) || failed || live ? 1 : 0.55)))
                if selected.contains(card.id) {
                    context.stroke(Path(rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(Palette.accent.color), lineWidth: 1.5)
                }
            }
            if !controller.viewport.isEmpty {
                context.stroke(Path(roundedRect: place(controller.viewport), cornerRadius: 3), with: .color(Palette.accent.color), lineWidth: 1)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Palette.panel.color)
        .floatingPanel()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            guard scale > 0 else { return }
            controller.canvas?.center(on: CGPoint(x: world.minX + (drag.location.x - inset.width) / scale,
                                                  y: world.minY + (drag.location.y - inset.height) / scale))
        })
        .help("The whole flow. Click or drag to go to a part of it.")
    }
}

/// Finds a card by name in any flow and goes to it.
struct FindPanel: View {
    let close: () -> Void
    @State private var query = ""
    @State private var picked = 0
    @FocusState private var isFocused: Bool
    private var services: AppServices { AppServices.shared }

    private struct Match: Identifiable {
        let controller: FlowController
        let card: Card?
        var id: String { controller.flow.id + "/" + (card?.id ?? "") }
    }

    private var matches: [Match] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        var found: [Match] = []
        // The flow on screen first, then the others.
        let current = services.allFlows.filter { $0.flow.id == services.selectedFlowID }
        let flows = current + services.allFlows.filter { $0.flow.id != services.selectedFlowID }
        for controller in flows {
            if controller.flow.name.localizedCaseInsensitiveContains(wanted) { found.append(Match(controller: controller, card: nil)) }
            for card in controller.flow.cards where card.name.localizedCaseInsensitiveContains(wanted)
                || card.kind.label.localizedCaseInsensitiveContains(wanted) {
                found.append(Match(controller: controller, card: card))
            }
        }
        return Array(found.prefix(12))
    }

    var body: some View {
        let found = matches
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.inkSecondary.ui)
                TextField("Find a card or a flow", text: $query)
                    .textFieldStyle(.plain)
                    .font(.dsSans(Theme.Size.heading))
                    .focused($isFocused)
                    .onSubmit { if found.indices.contains(picked) { go(to: found[picked]) } }
                    .onKeyPress(.downArrow) { picked = min(picked + 1, max(found.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { picked = max(picked - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { picked = 0 }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 10)

            if !found.isEmpty {
                Rectangle().fill(Theme.hairline.ui).frame(height: 1)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, match in
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: match.card.map { CanvasGeometry.icon(for: $0.kind) } ?? "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 16)
                            Text(match.card?.name ?? match.controller.flow.name)
                                .font(.dsSans(Theme.Size.body, .medium))
                                .lineLimit(1)
                            Spacer(minLength: Theme.Space.s)
                            Text(match.card == nil ? "flow in \(match.controller.project.name)" : match.controller.flow.name)
                                .font(.dsSans(Theme.Size.caption))
                                .foregroundStyle(Theme.inkSecondary.ui)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, 5)
                        .background(index == picked ? Theme.barHover.ui : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                        .contentShape(Rectangle())
                        .onTapGesture { go(to: match) }
                        .onHover { if $0 { picked = index } }
                    }
                }
                .padding(Theme.Space.xs)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Rectangle().fill(Theme.hairline.ui).frame(height: 1)
                Text("No card or flow has that in its name.")
                    .font(.dsSans(Theme.Size.body))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .padding(Theme.Space.m)
            }
        }
        .foregroundStyle(Theme.ink.ui)
        .frame(width: 440)
        .floatingPanel()
        .onAppear { isFocused = true }
    }

    private func go(to match: Match) {
        services.selectedFlowID = match.controller.flow.id
        close()
        guard let card = match.card else { return }
        match.controller.select(.card(card.id))
        // A flow that wasn't on screen needs a moment for its canvas to appear.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            // A card folded away in a group can't be shown until the group is unfolded.
            if let group = match.controller.flow.group(containing: card.id), group.isFolded { match.controller.setFolded(false, group: group.id) }
            match.controller.canvas?.zoom(toCard: card.id)
        }
    }
}

/// What the flow has cost so far, beside the zoom control: this flow and every sub-flow
/// below it. Click it for where the cost went.
struct CostPill: View {
    let controller: FlowController
    @Binding var showsBreakdown: Bool

    var body: some View {
        let total = controller.usageWithSubflows
        Button { showsBreakdown.toggle() } label: {
            HStack(spacing: 5) {
                Text(total.price)
                    .textRole(.monoCaption)
                    .contentTransition(.numericText())
                if controller.isRunning { StatusDot(.live, size: 5) }
            }
            .foregroundStyle((total.isZero ? Palette.textMuted : Palette.text).color)
            .padding(.horizontal, DS.Space.m)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floatingPanel()
        .help(total.isZero ? "This flow hasn't used anything yet. The figure appears once an agent has replied."
              : "An estimate of what this flow's work has cost so far, sub-flows included. Click to see where it went.")
        .animation(Theme.Motion.standard, value: total.price)
    }
}

/// Where a flow's cost went: its own agents, the sub-flows below it, then run by run.
struct CostBreakdown: View {
    let controller: FlowController
    let close: () -> Void
    private var services: AppServices { AppServices.shared }

    private var sessions: [(name: String, icon: String, usage: Usage)] {
        var rows: [(String, String, Usage)] = []
        if let used = controller.usage[FlowController.orchestratorKey], !used.isZero { rows.append(("Orchestrator", "sparkles", used)) }
        for card in controller.flow.cards where card.kind == .agent {
            if let used = controller.usage[card.id], !used.isZero { rows.append((card.name, "terminal", used)) }
        }
        return rows.sorted { $0.2.cost > $1.2.cost }
    }

    var body: some View {
        let own = controller.totalUsage
        let inner = controller.subflows()
        let total = controller.usageWithSubflows
        // Every bar is a share of the whole, so the eye can compare an agent with a sub-flow.
        let whole = max(total.cost, 0.000001)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cost of \(controller.flow.name)").font(.dsSans(Theme.Size.title, .medium)).lineLimit(1)
                Spacer()
                Text(total.price).font(.dsMono(Theme.Size.title, .medium))
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkSecondary.ui)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.bar.ui)

            if total.isZero {
                Text("Nothing yet. A figure appears here once an agent in this flow has replied.")
                    .font(.dsSans(Theme.Size.body))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .padding(Theme.Space.m)
                    .overlay(alignment: .top) { divider }
            }

            if !sessions.isEmpty {
                part(inner.isEmpty ? nil : "This flow's own agents", trailing: inner.isEmpty ? nil : own.price) {
                    ForEach(sessions, id: \.name) { row in
                        line(icon: row.icon, name: row.name, usage: row.usage, share: row.usage.cost / whole)
                    }
                }
            }

            if !inner.isEmpty {
                part("Sub-flows", trailing: inner.reduce(Usage()) { $0 + $1.controller.totalUsage }.price) {
                    ForEach(inner, id: \.controller.flow.id) { entry in
                        Button { open(entry.controller) } label: {
                            line(icon: "arrow.turn.down.right", name: entry.controller.flow.name, usage: entry.controller.totalUsage,
                                 share: entry.controller.totalUsage.cost / whole, indent: CGFloat(entry.depth) * 12, opens: true)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(entry.controller.flow.name) to see its own breakdown")
                    }
                }
            }

            let costed = controller.runs.reversed().filter { $0.usage != nil }.prefix(5)
            if !costed.isEmpty {
                part("Recent runs", trailing: nil) {
                    ForEach(Array(costed)) { run in
                        HStack {
                            Text("\(RunPicker.label(for: run.started)) · \(run.summary)").font(.dsSans(Theme.Size.caption))
                            Spacer()
                            Text(run.cost.price).font(.dsMono(Theme.Size.caption, .medium))
                        }
                    }
                }
            }

            // Inside a sub-flow, the figure above is only this part of something larger.
            if let outer = services.flowTrail.dropLast().last.flatMap({ id in services.allFlows.first { $0.flow.id == id } }) {
                Button { services.goBack(to: outer.flow.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.left.up").font(.system(size: 10, weight: .medium)).frame(width: 14)
                        Text("Part of \(outer.flow.name)").font(.dsSans(Theme.Size.caption, .medium)).lineLimit(1)
                        Spacer(minLength: Theme.Space.s)
                        Text("\(outer.usageWithSubflows.price) in all").font(.dsMono(Theme.Size.caption))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.bar.ui)
                .overlay(alignment: .top) { divider }
                .help("Go back to \(outer.flow.name)")
            }

            Text("An estimate of what this work would cost if you paid Anthropic by usage. On a Claude subscription you don't pay this, so read it as a measure of how much the flow uses. It updates each time an agent finishes a reply. A run's figure covers the agents and sub-flows it used, not the orchestrator.")
                .font(.dsSans(Theme.Size.caption))
                .foregroundStyle(Theme.inkSecondary.ui)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Space.m)
                .overlay(alignment: .top) { divider }
        }
        .foregroundStyle(Theme.ink.ui)
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .floatingPanel()
        .task(id: controller.flow.id) { await controller.refreshUsageWithSubflows() }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline.ui).frame(height: 1) }

    /// One titled part of the breakdown, with its subtotal on the right.
    private func part<Content: View>(_ title: String?, trailing: String?, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                HStack {
                    Text(title).font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui)
                    Spacer()
                    if let trailing { Text(trailing).font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui) }
                }
            }
            rows()
        }
        .padding(Theme.Space.m)
        .overlay(alignment: .top) { divider }
    }

    /// One agent or sub-flow: its name, what it used, and a bar for its share of the whole.
    private func line(icon: String, name: String, usage: Usage, share: Double, indent: CGFloat = 0, opens: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium)).frame(width: 14)
                Text(name).font(.dsSans(Theme.Size.caption, .medium)).lineLimit(1)
                if opens { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.inkSecondary.ui) }
                Spacer(minLength: Theme.Space.s)
                Text(usage.tokenCount).font(.dsMono(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui)
                Text(usage.price).font(.dsMono(Theme.Size.caption, .medium)).frame(minWidth: 44, alignment: .trailing)
            }
            GeometryReader { space in
                Rectangle().fill(Theme.ink.ui)
                    .frame(width: max(usage.isZero ? 0 : 2, space.size.width * min(1, max(0, share))), height: 2)
            }
            .frame(height: 2)
        }
        .padding(.leading, indent)
        .contentShape(Rectangle())
    }

    /// Goes into a sub-flow and keeps the breakdown open there.
    private func open(_ inner: FlowController) {
        close()
        services.enter(inner, from: controller)
        inner.showsCost = true
    }
}

/// The run's latest step in one line. Click it for the whole log.
struct StatusStrip: View {
    let controller: FlowController
    let showLog: () -> Void

    var body: some View {
        if let last = controller.log.last {
            Button(action: showLog) {
                HStack(spacing: Theme.Space.s) {
                    StatusDot(controller.isRunning ? .live : .neutral, size: 6)
                    Text(last.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if controller.handOffs > 0 {
                        Text("\(controller.handOffs) \(controller.handOffs == 1 ? "hand-off" : "hand-offs")")
                            .foregroundStyle(Palette.textMuted.color)
                            .contentTransition(.numericText())
                    }
                }
                .textRole(.caption)
                .foregroundStyle(Palette.text.color)
                .padding(.horizontal, DS.Space.m)
                .frame(height: 30)
                .frame(maxWidth: 460, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .floatingPanel()
            .help("Show everything the run has done")
            .animation(Theme.Motion.standard, value: controller.handOffs)
        }
    }
}

/// A one-line message about something that didn't work. Click to dismiss.
struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Text(text)
            .textRole(.body)
            .foregroundStyle(Palette.failText.color)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(Palette.failTint.color, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Palette.fail.opacity(0.4).color, lineWidth: DS.Stroke.hairline))
            .frame(maxWidth: 520)
            .onTapGesture(perform: dismiss)
            .help("Click to dismiss")
    }
}

/// What an empty flow shows: a short note beside the orchestrator, pointing at it. The
/// orchestrator is where a flow gets described, so the note sends you there and stays out
/// of the canvas's way.
struct OrchestratorCallout: View {
    let controller: FlowController
    /// The orchestrator's terminal is on screen for the arrow to point at.
    let orchestratorIsShowing: Bool
    let showOrchestrator: () -> Void
    @State private var nudged = false

    var body: some View {
        let session = controller.orchestrator
        let isOff = session.state == .notStarted || session.state == .exited
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Describe the flow you want")
                        .font(.dsSans(Theme.Size.body, .medium))
                    Spacer(minLength: Theme.Space.s)
                    Button { AppServices.shared.dismissHint(forFlow: controller.flow.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .help("Build it by hand")
                }
                Text(isOff ? "The orchestrator builds it on the canvas, but it isn't running yet."
                           : "Tell the orchestrator and it builds it here. Or drag cards in from the palette.")
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .fixedSize(horizontal: false, vertical: true)
                if isOff {
                    Button("Start the orchestrator") {
                        controller.startOrchestrator()
                        showOrchestrator()
                    }
                    .buttonStyle(.panel())
                    .padding(.top, 3)
                } else if !orchestratorIsShowing {
                    Button("Show the orchestrator", action: showOrchestrator)
                        .buttonStyle(.panel())
                        .padding(.top, 3)
                }
            }
            .foregroundStyle(Theme.ink.ui)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 9)
            .frame(width: 250, alignment: .leading)
            .floatingPanel()

            if orchestratorIsShowing, !isOff {
                // The arrow reaches across the gap to the panel, and leans toward it now and then.
                Arrow()
                    .stroke(Theme.ink.ui, style: StrokeStyle(lineWidth: Theme.Stroke.link, lineCap: .round, lineJoin: .round))
                    .frame(width: 30, height: 12)
                    .offset(x: nudged ? 4 : 0)
                    .onAppear {
                        guard Theme.Motion.isAllowed else { return }
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { nudged = true }
                    }
            }
        }
    }

    private struct Arrow: Shape {
        nonisolated func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            path.move(to: CGPoint(x: rect.maxX - 8, y: rect.minY + 1))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.maxY - 1))
            return path
        }
    }
}
