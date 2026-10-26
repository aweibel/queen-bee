import QueenBeeCore
import QueenBeeDesign
import SwiftUI

/// The strip across the top of the inset panel: where you are (project › flow), and what you can do with the
/// flow (answer what waits on you, choose where it works, run or stop it, show the side panel).
struct FlowHeader: View {
    let controller: FlowController?
    @Binding var showsSidebar: Bool
    @Binding var showsPanel: Bool
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    private var services: AppServices { AppServices.shared }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if !showsSidebar {
                // The window's buttons sit over this corner when the sidebar is hidden.
                Spacer().frame(width: 64)
            }
            Button { showsSidebar.toggle() } label: { Image(systemName: "sidebar.leading") }
                .buttonStyle(.dsIcon)
                .accessibilityLabel(showsSidebar ? "Hide projects" : "Show projects")
                .help("Show or hide projects and flows")
            breadcrumb
            if let controller {
                Button { services.togglePin(controller.flow.id) } label: {
                    Image(systemName: services.pinnedFlowIDs.contains(controller.flow.id) ? "pin.fill" : "pin")
                }
                .buttonStyle(.dsIcon)
                .accessibilityLabel(services.pinnedFlowIDs.contains(controller.flow.id) ? "Unpin" : "Pin")
                .help("Pin this flow to the top of the sidebar")
                Menu {
                    Button("Rename…") { startRenaming(controller) }
                    Button("Flow Settings…") {
                        controller.select(.none)
                        controller.showsFlowSettings = true
                    }
                    Button("Stop Its Agents") { controller.shutDown() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.dsIcon)
                    .fixedSize()
                    .accessibilityLabel("More")
            }
            Spacer(minLength: DS.Space.s)
            if let controller { actions(controller) }
            if controller != nil {
                Button { showsPanel.toggle() } label: { Image(systemName: "sidebar.trailing") }
                    .buttonStyle(.dsIcon)
                    .accessibilityLabel(showsPanel ? "Hide panel" : "Show panel")
                    .help("Show or hide the orchestrator, the log and the run's output")
            }
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.m)
        .frame(height: DS.Size.header)
    }

    // MARK: Where you are

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            if let controller {
                Text(controller.project.name)
                    .foregroundStyle(Palette.textMuted.color)
                chevron
                // Inside a sub-flow, the flows it was opened from lead the way back.
                ForEach(trail, id: \.flow.id) { outer in
                    Button { services.goBack(to: outer.flow.id) } label: { Text(outer.flow.name) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textMuted.color)
                        .help("Back to \(outer.flow.name)")
                    chevron
                }
                if isRenaming {
                    TextField("Flow name", text: $draft)
                        .textFieldStyle(.plain)
                        .fontWeight(.medium)
                        .frame(minWidth: 140)
                        .focused($isFocused)
                        .onSubmit {
                            controller.rename(to: draft)
                            isRenaming = false
                        }
                        .onExitCommand { isRenaming = false }
                        .onChange(of: isFocused) { if !isFocused { isRenaming = false } }
                } else {
                    Text(controller.flow.name)
                        .fontWeight(.medium)
                        .foregroundStyle(Palette.text.color)
                        .onTapGesture(count: 2) { startRenaming(controller) }
                        .help("Double-click to rename this flow")
                }
            } else {
                Text("Queen Bee").fontWeight(.medium).foregroundStyle(Palette.text.color)
            }
        }
        .textRole(.body)
        .lineLimit(1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Palette.textFaint.color)
            .accessibilityHidden(true)
    }

    /// The flows this one was opened from, outermost first.
    private var trail: [FlowController] {
        services.flowTrail.dropLast().compactMap { id in services.allFlows.first { $0.flow.id == id } }
    }

    private func startRenaming(_ controller: FlowController) {
        draft = controller.flow.name
        isRenaming = true
        isFocused = true
    }

    // MARK: What you can do

    @ViewBuilder
    private func actions(_ controller: FlowController) -> some View {
        let waiting = controller.cardsNeedingYou
        if let first = waiting.first {
            Button {
                controller.showsFlowSettings = false
                controller.select(.card(first.id))
                controller.canvas?.zoom(toCard: first.id)
            } label: {
                StatusPill(waiting.count == 1 ? "1 needs you" : "\(waiting.count) need you", tone: .live)
            }
            .buttonStyle(.plain)
            .help("Go to the card that is waiting on you")
        } else if controller.isRunning {
            StatusPill("Running · \(controller.handOffs) \(controller.handOffs == 1 ? "hand-off" : "hand-offs")", tone: .live)
        }
        // The branch the flow works on, or its worktree's: one place for the whole flow.
        if let chip = controller.workplaceChip {
            WorkplaceChip(controller: controller, text: chip)
        }
        // Run and Stop are named, so it is plain which one is on offer and whether it can be pressed.
        // Greyed out means there is nothing to run yet.
        if controller.isRunning {
            Button { Task { await controller.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.ds(.live))
                .help("Stop the run (⌘.)")
        } else {
            HStack(spacing: 2) {
                Button { Task { await controller.run() } } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.ds(.primary))
                    .disabled(!controller.canRun)
                    .help(runHelp(controller))
                if controller.startCards.count > 1 {
                    // Several Start cards: say which one. A plain click on Run uses the selected one, or the first.
                    Menu {
                        ForEach(controller.startCards) { start in
                            Button("Run from \(start.name)") { Task { await controller.run(startCardID: start.id) } }
                        }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.dsIcon)
                        .fixedSize()
                        .disabled(!controller.canRun)
                        .accessibilityLabel("Run from…")
                        .help("This flow has \(controller.startCards.count) Start cards. Choose which one to run from.")
                }
            }
        }
    }

    private func runHelp(_ controller: FlowController) -> String {
        if controller.canRun { return "Run the flow from its Start card (⌘R)" }
        return controller.flow.isSubflow == true
            ? "To try this sub-flow by itself, give its Input something to start with and link it to a card"
            : "Nothing to run yet: give the Start card something to start with and link it to a card"
    }
}

/// The tabs under the header: the flow's canvas, and its settings.
struct FlowTabs: View {
    let controller: FlowController

    private enum Tab: Hashable { case canvas, settings }

    var body: some View {
        HStack {
            PillTabs([.init(Tab.canvas, "Canvas"), .init(Tab.settings, "Settings")], selection: Binding(
                get: { controller.showsFlowSettings ? .settings : .canvas },
                set: { tab in
                    if tab == .settings { controller.select(.none) }
                    controller.showsFlowSettings = tab == .settings
                }))
            Spacer()
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: DS.Size.tabRow)
    }
}
