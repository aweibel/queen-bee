import QueenBeeCore
import SwiftUI

/// The Mac's projects and their flows. Each flow's row says what it needs from you, in the Mac's words.
/// It is the sidebar on an iPad and the first screen on an iPhone.
struct FlowList: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        let isConnected = client.state == .connected
        Group {
            if let library = client.mirror.library {
                if library.projects.allSatisfy(\.flows.isEmpty) {
                    note("No flows yet", "Add a project folder in Queen Bee on your Mac, and its flows show up here.")
                } else {
                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
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
        header(project.name)
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

    private func header(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .dsMono(Theme.Touch.caption, .medium)
                .foregroundStyle(Theme.inkSecondary.ui)
                .lineLimit(1)
            Hairline()
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.xs)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(for flow: RemoteFlowSummary) -> some View {
        let isOpen = client.mirror.openFlowID == flow.id
        return Button {
            // Asking for the flow already on show would blank it for a moment for nothing.
            if !isOpen { client.open(flow.id) }
        } label: {
            HStack(spacing: Theme.Space.s) {
                if flow.isSubflow {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary.ui)
                        .accessibilityHidden(true)
                }
                Text(flow.name)
                    .dsMono(Theme.Touch.body, isOpen ? .medium : .regular)
                    .foregroundStyle((flow.isSubflow && !isOpen ? Theme.inkSecondary : Theme.ink).ui)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                FlowActivityBadge(activity: flow.activity)
            }
        }
        .buttonStyle(FlowRowStyle(isOpen: isOpen))
        .id(flow.id)
        .accessibilityLabel(flow.isSubflow ? "\(flow.name), sub-flow" : flow.name)
        .accessibilityValue(flow.activity.words ?? "")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
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
private struct FlowRowStyle: ButtonStyle {
    let isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Space.s) {
            Rectangle()
                .fill(isOpen ? Theme.ink.ui : .clear)
                .frame(width: 2, height: 18)
            configuration.label
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
        .background(isOpen ? Theme.bar.ui : configuration.isPressed ? Theme.barHover.ui : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
        .contentShape(Rectangle())
        .animation(Theme.Motion.quick, value: configuration.isPressed)
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
