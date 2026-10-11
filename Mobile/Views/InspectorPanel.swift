import QueenBeeCore
import SwiftUI

/// What the panel beside the canvas can show, one at a time, as the Mac's side panel does. A new kind of
/// panel is a new case here and a new view in `InspectorPanel.page`.
enum InspectorTab: String, CaseIterable, Identifiable {
    case details, orchestrator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: "Details"
        case .orchestrator: "Orchestrator"
        }
    }
}

/// The panel beside the canvas, for what the open flow and its cards have to say. On an iPhone it comes up as a sheet.
struct InspectorPanel: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var tab = InspectorTab.details

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(InspectorTab.allCases) { TabButton(tab: $0, selected: $tab) }
                Spacer(minLength: Theme.Space.s)
                // A sheet needs its own way out. Beside the canvas, the bar's button hides the panel.
                if sizeClass == .compact {
                    Button("Done") { dismiss() }.buttonStyle(.panel(.quiet))
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: Theme.Touch.target)
            .background(Theme.bar.ui)
            Hairline()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .dimmedWhileAway(client.state == .connected)
        }
        .background(Theme.surface.ui)
        #if DEBUG
        .task { if DebugLaunch.show == "orchestrator" { tab = .orchestrator } }
        #endif
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .details:
            ScrollView {
                details
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .orchestrator:
            OrchestratorPanel()
        }
    }

    @ViewBuilder private var details: some View {
        if let open = client.openFlow {
            PanelSection(title: "Flow") {
                PanelRow(label: "Name", value: open.flow.name)
                Hairline()
                PanelRow(label: "Project", value: open.project.name)
                if let flow = client.mirror.snapshot?.flow {
                    Hairline()
                    PanelRow(label: "Cards", value: "\(flow.cards.count)")
                }
            }
        } else {
            NothingOpen(text: "Open a flow to see its details here.")
        }
    }
}

/// What a page of the panel says when no flow is open.
struct NothingOpen: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("No flow open").dsMono(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
            Text(text).dsSans().foregroundStyle(Theme.inkSecondary.ui)
        }
    }
}

/// One of the panel's tabs: its name, ruled underneath when it is the one on show.
private struct TabButton: View {
    let tab: InspectorTab
    @Binding var selected: InspectorTab

    var body: some View {
        let isOn = tab == selected
        Button { selected = tab } label: {
            Text(tab.title)
                .dsMono(Theme.Touch.body, isOn ? .medium : .regular)
                .foregroundStyle((isOn ? Theme.ink : Theme.inkSecondary).ui)
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: Theme.Touch.target)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isOn ? Theme.ink.ui : .clear).frame(height: Theme.Stroke.selected)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// The session that runs the open flow: what it is doing, and its terminal as the Mac's side panel has it.
/// The terminal here is a picture that follows the session. Reading back through it is done full screen.
struct OrchestratorPanel: View {
    @Environment(RemoteClient.self) private var client
    private let key = TerminalRegistry.orchestratorKey

    var body: some View {
        if client.openFlow == nil {
            NothingOpen(text: "Open a flow to see the session that runs it.")
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if client.terminals.sizes[key] != nil {
            let caption = SessionCaption(key: key, client: client)
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Text("Runs this flow").dsSans().foregroundStyle(Theme.inkSecondary.ui)
                    if let badge = caption.badge { Badge(text: badge.text, tone: badge.tone) }
                    Spacer(minLength: Theme.Space.s)
                    Button { client.terminals.expand(key) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.ink.ui)
                            .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the terminal full screen")
                }
                .padding(.leading, Theme.Space.l)
                Hairline()
                // The Mac's padding around its terminal, on the terminal's own colour.
                TerminalPicture(key: key)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.terminal.ui)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Not started").dsMono(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
                Text("The session that runs this flow hasn't been started on your Mac.").dsSans().foregroundStyle(Theme.inkSecondary.ui)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
