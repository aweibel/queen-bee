import QueenBeeCore
import SwiftUI

/// The Mac's projects and their flows. Each flow's row says what it needs from you, in the Mac's words.
/// It is the sidebar on an iPad and the first screen on an iPhone. When this device may control the Mac,
/// a + beside a project's name makes a flow there, and a finger held on a row offers to rename or delete it.
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
                                if let refusal = client.settings.refusal {
                                    RefusalNotice(text: refusal, alignment: .leading) { client.settings.refusal = nil }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, Theme.Space.s)
                                }
                                ForEach(library.projects) { project in
                                    section(for: project)
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

    /// The device is told which flows are sub-flows, and not which flow uses each one. So they are not
    /// tucked under a flow, as on the Mac, but listed together after the project's own flows.
    @ViewBuilder
    private func section(for project: RemoteProject) -> some View {
        let subflows = project.flows.filter(\.isSubflow)
        header(project)
        ForEach(project.flows.filter { !$0.isSubflow }) { row(for: $0) }
        if !subflows.isEmpty {
            Text("Sub-flows")
                .dsMono(Theme.Touch.caption)
                .foregroundStyle(Theme.inkSecondary.ui)
                .padding(.leading, Theme.Space.l + 2)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(subflows) { row(for: $0) }
        }
    }

    private func header(_ project: RemoteProject) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Text(project.name)
                    .dsMono(Theme.Touch.caption, .medium)
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

    @ViewBuilder
    private func row(for flow: RemoteFlowSummary) -> some View {
        let isOpen = client.mirror.openFlowID == flow.id
        let menu = client.flowMenu(for: flow), isMenuOut = client.settings.flowMenu == flow.id && !menu.isEmpty
        FlowRow(flow: flow, isOpen: isOpen, isMenuOut: isMenuOut) {
            client.settings.flowMenu = nil
            // Asking for the flow already on show would blank it for a moment for nothing. Unless it went from
            // the Mac's list and has come back: the Mac stopped sending it then, and what is on show is old.
            if !isOpen || client.mirror.openFlowWentAway { client.open(flow.id) }
        } hold: {
            // Held again, the menu goes.
            if !menu.isEmpty { client.settings.flowMenu = isMenuOut ? nil : flow.id }
        }
        .id(flow.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(flow.isSubflow ? "\(flow.name), sub-flow" : flow.name)
        .accessibilityValue(flow.activity.words ?? "")
        .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if !isOpen || client.mirror.openFlowWentAway { client.open(flow.id) } }
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
            Text(title).dsMono(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
            if !text.isEmpty { Text(text).dsSans(Theme.Touch.body).foregroundStyle(Theme.inkSecondary.ui) }
        }
        .multilineTextAlignment(.center)
        .padding(Theme.Space.xl)
    }
}

/// One flow in the list: tinted under the finger, marked with an ink rule when it is the one on the canvas.
/// A tap opens it. A finger held on it brings out its menu, under it.
private struct FlowRow: View {
    let flow: RemoteFlowSummary
    let isOpen: Bool
    let isMenuOut: Bool
    let open: () -> Void
    let hold: () -> Void
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Rectangle()
                .fill(isOpen ? Theme.ink.ui : .clear)
                .frame(width: 2, height: 18)
            if flow.isSubflow {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary.ui)
            }
            Text(flow.name)
                .dsMono(Theme.Touch.body, isOpen ? .medium : .regular)
                .foregroundStyle((flow.isSubflow && !isOpen ? Theme.inkSecondary : Theme.ink).ui)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            FlowActivityBadge(activity: flow.activity)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
        .background(isOpen ? Theme.bar.ui : isPressed || isMenuOut ? Theme.barHover.ui : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
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
                        Text(item.title).dsMono(Theme.Touch.body, .medium).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle((item.kind == .delete ? Theme.failInk : Theme.ink).ui)
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
