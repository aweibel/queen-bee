import QueenBeeCore
import QueenBeeDesign
import SwiftUI

/// The Mac's projects and their flows. Each flow's row says what it needs from you, in the Mac's words.
/// It is the sidebar on an iPad and the first screen on an iPhone. Pinned flows come first, and each sub-flow is
/// under the flow that runs it, as in the Mac's sidebar. Find, over the list, finds flows and cards in every
/// project. When this device may control the Mac, a + beside a project's name makes a flow there, and a finger
/// held on a row offers to rename, pin, stop or delete it.
struct FlowList: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        let isConnected = client.state == .connected
        Group {
            if let library = client.mirror.library {
                // A project with no flows still has its +, when a flow can be made from here.
                if library.projects.isEmpty || (library.projects.allSatisfy(\.flows.isEmpty) && !client.canChangeFlows) {
                    note("No flows yet", "Add a project folder in Queen Bee on your Mac, and its flows show up here.")
                } else {
                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                FindField()
                                    .padding(.top, Theme.Space.s)
                                if let refusal = client.settings.refusal {
                                    RefusalNotice(text: refusal, alignment: .leading) { client.settings.refusal = nil }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, Theme.Space.s)
                                }
                                if let found = client.found {
                                    FindList(found: found)
                                } else {
                                    let pinned = client.pinnedFlows
                                    if !pinned.isEmpty {
                                        heading("Pinned")
                                        ForEach(pinned) { row(for: $0, depth: 0, key: "pinned/") }
                                    }
                                    ForEach(library.projects) { project in
                                        section(for: project)
                                    }
                                }
                            }
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.bottom, Theme.Space.l)
                        }
                        // The open flow may be far down a long list, as when the app comes back to it.
                        .onChange(of: client.mirror.openFlowID, initial: true) { _, open in
                            if let open { scroll.scrollTo(open) }
                        }
                    }
                }
            } else if isConnected {
                note("Getting your flows…", "")
            } else {
                note("No flows to show yet", "They show up here once your Mac is found.")
            }
        }
        .dimmedWhileAway(isConnected)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface.ui)
    }

    /// A project's flows, each sub-flow under the flow whose Flow card runs it, as on the Mac.
    @ViewBuilder
    private func section(for project: RemoteProject) -> some View {
        header(project)
        ForEach(FlowNesting.rows(project.flows)) { row(for: $0.flow, depth: $0.depth) }
    }

    private func heading(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .dsSans(Theme.Touch.caption, .medium)
                .foregroundStyle(Theme.inkSecondary.ui)
                .accessibilityAddTraits(.isHeader)
            Hairline()
        }
        .padding(.leading, Theme.Space.s)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.xs)
    }

    private func header(_ project: RemoteProject) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Text(project.name)
                    .dsSans(Theme.Touch.caption, .medium)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.xs)
                if client.canChangeFlows {
                    Button { client.askForNewFlow(in: project) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink.ui)
                            .frame(width: Theme.Touch.target, height: Theme.Touch.target - Theme.Space.s)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New flow in \(project.name)")
                }
            }
            Hairline()
        }
        .padding(.leading, Theme.Space.s)
        .padding(.top, client.canChangeFlows ? Theme.Space.s : Theme.Space.l)
        .padding(.bottom, Theme.Space.xs)
    }

    /// - Parameter depth: how far down a sub-flow is, under the flow that runs it.
    /// - Parameter key: tells a pinned flow's row from its row in its project, where it is listed too.
    @ViewBuilder
    private func row(for flow: RemoteFlowSummary, depth: Int, key: String = "") -> some View {
        let isOpen = client.mirror.openFlowID == flow.id
        let menu = client.flowMenu(for: flow), isMenuOut = client.settings.flowMenu == key + flow.id && !menu.isEmpty
        FlowRow(flow: flow, depth: depth, isOpen: isOpen, isMenuOut: isMenuOut) {
            client.settings.flowMenu = nil
            // Asking for the flow already on show would blank it for a moment for nothing. Unless it went from
            // the Mac's list and has come back: the Mac stopped sending it then, and what is on show is old.
            // One whose id another project's flow has too is not opened: the row says why.
            if flow.sharedID != true, !isOpen || client.mirror.openFlowWentAway { client.open(flow.id) }
        } hold: {
            // Held again, the menu goes.
            if !menu.isEmpty { client.settings.flowMenu = isMenuOut ? nil : key + flow.id }
        }
        .id(key + flow.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([flow.name, flow.isSubflow ? "sub-flow" : nil, flow.pinned ? "pinned" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(flow.sharedID == true ? Remote.sharedFlowIDRefusal : flow.activity.words ?? "")
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if flow.sharedID != true, !isOpen || client.mirror.openFlowWentAway { client.open(flow.id) } }
        // VoiceOver can't hold a finger down, so what the menu offers is offered as the row's own actions.
        .accessibilityActions {
            ForEach(menu) { item in
                Button(item.title) { client.choose(item.kind, for: flow) }
            }
        }
        if isMenuOut {
            FlowRowMenu(title: flow.name, items: menu) { client.choose($0, for: flow) }
                .padding(.leading, Theme.Space.l)
                .padding(.trailing, Theme.Space.s)
                .padding(.bottom, Theme.Space.xs)
                .transition(.opacity)
        }
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(spacing: Theme.Space.s) {
            Text(title).dsSans(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
            if !text.isEmpty { Text(text).dsSans(Theme.Touch.body).foregroundStyle(Theme.inkSecondary.ui) }
        }
        .multilineTextAlignment(.center)
        .padding(Theme.Space.xl)
    }
}

/// One flow in the list: a dot for its state, tinted under the finger, and filled when it is the one on the canvas.
/// A tap opens it. A finger held on it brings out its menu, under it.
private struct FlowRow: View {
    let flow: RemoteFlowSummary
    var depth = 0
    let isOpen: Bool
    let isMenuOut: Bool
    let open: () -> Void
    let hold: () -> Void
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if flow.isSubflow {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .padding(.leading, CGFloat(max(0, depth - 1)) * 14)
            } else {
                StatusDot(flow.activity.tone, size: 9).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.name)
                    .dsSans(Theme.Touch.body, isOpen ? .medium : .regular)
                    .foregroundStyle((flow.isSubflow && !isOpen ? Theme.inkSecondary : Theme.ink).ui)
                    .lineLimit(1)
                // The Mac opens and changes neither of two flows with one id, so the row says why it won't open.
                if flow.sharedID == true {
                    Text(Remote.sharedFlowIDRefusal)
                        .dsSans(Theme.Touch.caption)
                        .foregroundStyle(Theme.inkSecondary.ui)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, flow.sharedID == true ? Theme.Space.xs : 0)
            Spacer(minLength: Theme.Space.xs)
            if flow.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkSecondary.ui).accessibilityHidden(true)
            }
            FlowActivityBadge(activity: flow.activity)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
        .background(isOpen ? Palette.selected.color : isPressed || isMenuOut ? Palette.hover.color : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onLongPressGesture(minimumDuration: 0.4, perform: hold) { isPressed = $0 }
        .animation(Theme.Motion.quick, value: isPressed)
    }
}

/// What can be done to a flow, under its row: a panel on the paper, as the canvas's own menus are, where
/// the system's menu would be a sheet of frosted glass.
private struct FlowRowMenu: View {
    let title: String
    let items: [FlowMenuItem]
    let choose: (FlowMenuItem.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Hairline() }
                Button { choose(item.kind) } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(item.title).dsSans(Theme.Touch.body, .medium).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle((item.kind == .delete || item.kind == .stopAgents ? Theme.failInk : Theme.ink).ui)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(minHeight: Theme.Touch.target)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title) \(title)")
            }
        }
        .floatingPanel()
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

extension FlowActivity {
    /// What the Mac's sidebar calls each state. Nothing for a flow that is doing nothing.
    var words: String? {
        switch self {
        case .needsYou: "needs you"
        case .running: "running"
        case .failed: "stopped"
        case .quiet: nil
        }
    }
}

/// The flow's state as the Mac's sidebar badges it.
struct FlowActivityBadge: View {
    let activity: FlowActivity

    var body: some View {
        if let words = activity.words {
            Badge(text: words, tone: activity == .failed ? .fail : .live)
        }
    }
}

/// Find, over the list of flows: what is written finds flows by their names and cards by theirs, in every project.
private struct FindField: View {
    @Environment(RemoteClient.self) private var client
    @FocusState private var isWriting: Bool

    var body: some View {
        @Bindable var settings = client.settings
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.inkSecondary.ui).accessibilityHidden(true)
            TextField("Flows and cards", text: $settings.search)
                .dsSans()
                .foregroundStyle(Theme.ink.ui)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isWriting)
                .accessibilityLabel("Find flows and cards")
            if !settings.search.isEmpty {
                Button { settings.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.inkSecondary.ui)
                        .frame(width: 32, height: Theme.Touch.target).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Find")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: Theme.Touch.target)
        .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(isWriting ? Theme.select.ui : Theme.hairline.ui,
                                                                                  lineWidth: isWriting ? Theme.Stroke.selected : Theme.Stroke.card))
    }
}

/// What Find found: the flows, then the cards, each with the flow and the project it is in. A tap goes there.
private struct FindList: View {
    @Environment(RemoteClient.self) private var client
    let found: FindResults

    var body: some View {
        if found.isEmpty {
            Text("No card or flow has that in its name.")
                .dsSans()
                .foregroundStyle(Theme.inkSecondary.ui)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.l)
        }
        if !found.flows.isEmpty {
            title("Flows")
            ForEach(found.flows) { hit($0, icon: "point.3.connected.trianglepath.dotted", name: $0.flowName, place: $0.project) }
        }
        if !found.cards.isEmpty {
            title("Cards")
            ForEach(found.cards) { hit($0, icon: "square.on.square", name: $0.card ?? "", place: $0.flowName) }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .dsSans(Theme.Touch.caption, .medium)
            .foregroundStyle(Theme.inkSecondary.ui)
            .padding(.leading, Theme.Space.s)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func hit(_ hit: FindResults.Hit, icon: String, name: String, place: String) -> some View {
        Button { client.go(to: hit) } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 18).accessibilityHidden(true)
                Text(name).dsSans(Theme.Touch.body, .medium).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Text(place).dsSans(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui).lineLimit(1)
            }
            .foregroundStyle(Theme.ink.ui)
            .padding(.horizontal, Theme.Space.s)
            .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hit.card == nil ? "Flow \(name), in \(place)" : "Card \(name), in \(place)")
        .accessibilityHint(hit.card == nil ? "Opens the flow." : "Opens its flow and goes to the card.")
    }
}
