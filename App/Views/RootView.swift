import QueenBeeCore
import SwiftUI

/// The tabs of the panel beside the canvas.
enum PanelTab: String, CaseIterable {
    case orchestrator, log, output

    var label: String {
        switch self {
        case .orchestrator: "Orchestrator"
        case .log: "Log"
        case .output: "Output"
        }
    }
}

/// The app's one window. The canvas fills it edge to edge. Everything else floats over the
/// canvas: the projects panel on the left, the orchestrator panel on the right, and the
/// canvas's own controls between them.
struct WorkspaceView: View {
    static let gap = Theme.Space.m
    static let sidebarWidth: CGFloat = 236

    @AppStorage("showsSidebar") private var showsSidebar = true
    @AppStorage("showsPanel") private var showsPanel = true
    @AppStorage("panelWidth") private var panelWidth = 420.0
    @State private var tab = PanelTab.orchestrator
    @Environment(\.openWindow) private var openWindow
    private var services: AppServices { AppServices.shared }

    var body: some View {
        ZStack {
            Theme.paper.ui.ignoresSafeArea()
            if let controller = services.current {
                // Under the title bar too: the bar is see-through, so the canvas is the whole window.
                CanvasRepresentable(controller: controller)
                    .ignoresSafeArea()
                    .id(controller.flow.id)
            } else if services.projects.isEmpty {
                WelcomeView()
            } else {
                ContentUnavailableView("No flow selected", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Pick a flow on the left, or add one to a project."))
            }

            HStack(alignment: .top, spacing: Self.gap) {
                if showsSidebar {
                    SidebarView()
                        .frame(width: Self.sidebarWidth)
                        .floatingPanel()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if let controller = services.current {
                    CanvasControls(controller: controller) {
                        tab = .log
                        showsPanel = true
                    } showOrchestrator: {
                        tab = .orchestrator
                        showsPanel = true
                    }
                    .environment(\.orchestratorIsShowing, showsPanel && tab == .orchestrator)
                    .id(controller.flow.id)
                } else {
                    Spacer(minLength: 0)
                }
                if showsPanel, let controller = services.current {
                    SidePanel(controller: controller, tab: $tab, width: $panelWidth)
                        .frame(width: panelWidth)
                        .floatingPanel()
                        .id(controller.flow.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(Self.gap)

            if services.showsFind {
                // Over everything, near the top, like a search field that came to you.
                VStack {
                    FindPanel { services.showsFind = false }
                        .padding(.top, 90)
                    Spacer()
                }
                .background {
                    Color.clear.contentShape(Rectangle()).onTapGesture { services.showsFind = false }
                }
                .transition(.opacity.combined(with: .offset(y: -8)))
            }

            if services.showsPalette, let controller = services.current {
                VStack {
                    CommandPalette(controller: controller) { services.showsPalette = false }
                        .padding(.top, 90)
                    Spacer()
                }
                .background {
                    Color.clear.contentShape(Rectangle()).onTapGesture { services.showsPalette = false }
                }
                .transition(.opacity.combined(with: .offset(y: -8)))
            }

            if services.showsWelcome {
                OnboardingView { services.closeWelcome() }
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.standard, value: services.showsWelcome)
        .animation(Theme.Motion.standard, value: services.showsFind)
        .animation(Theme.Motion.standard, value: services.showsPalette)
        // The menu bar item normally gives the way to open the window again; this is for when it hasn't appeared.
        .onAppear { if services.openWorkspace == nil { services.openWorkspace = { openWindow(id: AppServices.workspaceID) } } }
        .animation(Theme.Motion.standard, value: showsSidebar)
        .animation(Theme.Motion.standard, value: showsPanel)
        .onChange(of: obstruction, initial: true) { services.canvasObstruction = obstruction }
        .navigationTitle(services.current?.flow.name ?? "Queen Bee")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .toolbar(removing: .title)
        // The first time a flow opens in a git repository, it asks where it works. Its agents wait for the answer.
        .sheet(isPresented: Binding(get: { services.current?.asksForWorkplace == true }, set: { shown in
            guard !shown, let controller = services.current, controller.asksForWorkplace else { return }
            Task { await controller.answerWorkplaceQuestion(nil) }
        })) {
            if let controller = services.current {
                WorkplaceForm(controller: controller, isFirstRun: true) {}
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 900, minHeight: 560)
    }

    /// How much of the canvas's left and right the floating panels and the palette cover,
    /// so "fit" can keep the flow clear of them.
    private var obstruction: CanvasObstruction {
        let left = (showsSidebar ? Self.sidebarWidth + Self.gap : 0) + Self.gap + PaletteView.width + Self.gap
        let right = showsPanel && services.current != nil ? panelWidth + Self.gap * 2 : Self.gap
        return CanvasObstruction(left: left, right: right)
    }

    private var subtitle: String {
        guard let controller = services.current else { return "" }
        let project = controller.project.name
        if controller.isRunning { return "\(project) · running, \(controller.handOffs) \(controller.handOffs == 1 ? "hand-off" : "hand-offs")" }
        return project
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showsSidebar.toggle() } label: { Label("Projects", systemImage: "sidebar.leading") }
                .help("Show or hide projects and flows")
        }
        // The flow's name sits in a toolbar item of its own, so it gets the same container
        // the buttons have and doesn't float bare over the canvas.
        ToolbarItem(placement: .navigation) {
            TitlePlate(controller: services.current, subtitle: subtitle)
        }
        // With the system title gone nothing pushes the actions to the right, so a spacer does.
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            if let controller = services.current {
                let waiting = controller.cardsNeedingYou
                if let first = waiting.first {
                    Button {
                        controller.select(.card(first.id))
                        controller.canvas?.zoom(toCard: first.id)
                    } label: {
                        Label(waiting.count == 1 ? "1 needs you" : "\(waiting.count) need you", systemImage: "hand.raised")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(Theme.live.ui)
                    .help("Go to the card that is waiting on you")
                }
                // Run and Stop are filled and named, so it is plain which one is on offer and
                // whether it can be pressed. Greyed out means there is nothing to run yet.
                if controller.isRunning {
                    Button { Task { await controller.stop() } } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.live.ui)
                        .help("Stop the run")
                } else if controller.startCards.count > 1 {
                    // Several Start cards: say which one. The selected one runs on a plain click.
                    Menu {
                        ForEach(controller.startCards) { start in
                            Button("Run from \(start.name)") { Task { await controller.run(startCardID: start.id) } }
                        }
                    } label: {
                        Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
                    } primaryAction: {
                        Task { await controller.run() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.select.ui)
                    .disabled(!controller.canRun)
                    .help("This flow has \(controller.startCards.count) Start cards. Click to run from the selected one, or the first. Hold or use the arrow to choose.")
                } else {
                    Button { Task { await controller.run() } } label: { Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.select.ui)
                        .disabled(!controller.canRun)
                        .help(controller.canRun ? "Run the flow from its Start card" : controller.flow.isSubflow == true
                              ? "To try this sub-flow by itself, give its Input something to start with and link it to a card"
                              : "Nothing to run yet: give the Start card something to start with and link it to a card")
                }
                Button {
                    controller.select(.none)
                    controller.showsFlowSettings.toggle()
                } label: { Label("Flow Settings", systemImage: "slider.horizontal.3") }
                    .help("Settings for this flow: its name, how deep sub-flows may go, and whether its orchestrator hears when a run ends")
                Button { showsPanel.toggle() } label: { Label("Panel", systemImage: "sidebar.trailing") }
                    .help("Show or hide the orchestrator, the log and the run's output")
            }
        }
    }

    static func pickProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose the folder your agents should work in. Your flows are saved inside it."
        if panel.runModal() == .OK, let url = panel.url, AppServices.shared.confirmTrust(url) {
            let project = AppServices.shared.addProject(url)
            if project.controllers.isEmpty { project.newFlow() }
        }
    }
}

/// The flow's name and its project, in the title bar. Click the name to rename the flow.
private struct TitlePlate: View {
    let controller: FlowController?
    let subtitle: String
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isRenaming, let controller {
                TextField("Flow name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 140)
                    .focused($isFocused)
                    .onSubmit {
                        controller.rename(to: draft)
                        isRenaming = false
                    }
                    .onExitCommand { isRenaming = false }
                    .onChange(of: isFocused) { if !isFocused { isRenaming = false } }
            } else {
                HStack(spacing: 4) {
                    // Inside a sub-flow, the flows it was opened from lead the way back.
                    ForEach(trail, id: \.flow.id) { outer in
                        Button { AppServices.shared.goBack(to: outer.flow.id) } label: {
                            Text(outer.flow.name).font(.system(size: 13)).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Back to \(outer.flow.name)")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    Text(controller?.flow.name ?? "Queen Bee")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture {
                            guard let controller, !isRenaming else { return }
                            draft = controller.flow.name
                            isRenaming = true
                            isFocused = true
                        }
                }
            }
            if !subtitle.isEmpty {
                HStack(spacing: 4) {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // The branch the flow works on, or its worktree's: one place for the whole flow.
                    if let controller, let chip = controller.workplaceChip {
                        Text("·").font(.system(size: 11)).foregroundStyle(.secondary)
                        WorkplaceChip(controller: controller, text: chip)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .help(controller == nil ? "" : "Click the flow's name to rename it")
    }

    /// The flows this one was opened from, outermost first.
    private var trail: [FlowController] {
        let services = AppServices.shared
        return services.flowTrail.dropLast().compactMap { id in services.allFlows.first { $0.flow.id == id } }
    }
}

/// What floats over the canvas between the two panels: the palette, the selected card's
/// settings, a banner, the status line, the zoom control, and an empty flow's pointer to the
/// orchestrator. Its empty
/// areas let clicks through to the canvas underneath.
struct CanvasControls: View {
    let controller: FlowController
    let showLog: () -> Void
    let showOrchestrator: () -> Void
    @Environment(\.orchestratorIsShowing) private var orchestratorIsShowing
    @AppStorage("showsMinimap") private var showsMinimap = true
    private var services: AppServices { AppServices.shared }

    /// An empty flow points at the orchestrator until it is built in, or the note is closed.
    private var showsCallout: Bool {
        controller.isBlank && controller.selection == .none && !services.dismissedHints.contains(controller.flow.id)
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { PaletteView(controller: controller) }
            .overlay(alignment: .topTrailing) {
                if controller.selection != .none {
                    InspectorView(controller: controller)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                } else if controller.showsFlowSettings {
                    FlowSettingsView(controller: controller)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                }
            }
            .overlay(alignment: .top) {
                if let message = services.problem ?? controller.banner {
                    BannerView(text: message) {
                        if services.problem != nil { services.dismissProblem() } else { controller.banner = nil }
                    }
                }
            }
            .overlay(alignment: .bottomLeading) { StatusStrip(controller: controller, showLog: showLog) }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: Theme.Space.s) {
                    if showsMinimap, !controller.flow.cards.isEmpty, !controller.showsCost {
                        Minimap(controller: controller)
                            .transition(.opacity)
                    }
                    if controller.showsCost {
                        CostBreakdown(controller: controller) { controller.showsCost = false }
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    HStack(spacing: Theme.Space.s) {
                        CostPill(controller: controller, showsBreakdown: Binding(get: { controller.showsCost }, set: { controller.showsCost = $0 }))
                        ZoomPill(controller: controller)
                    }
                }
                .animation(Theme.Motion.standard, value: controller.showsCost)
            }
            .overlay(alignment: .trailing) {
                if showsCallout {
                    // Below the middle of the panel's edge: clear of a new flow's cards, which sit at
                    // the top or, in a sub-flow shown whole, across the middle, and of the map at the foot.
                    OrchestratorCallout(controller: controller, orchestratorIsShowing: orchestratorIsShowing, showOrchestrator: showOrchestrator)
                        .padding(.top, 230)
                        .transition(.opacity.combined(with: .offset(x: -8)))
                }
            }
            .animation(Theme.Motion.standard, value: controller.selection)
            .animation(Theme.Motion.standard, value: controller.showsFlowSettings)
            .animation(Theme.Motion.standard, value: showsCallout)
    }
}

extension EnvironmentValues {
    /// The side panel is open on the orchestrator's tab.
    @Entry var orchestratorIsShowing = false
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.ink.ui)
            Text("Queen Bee")
                .font(.dsMono(22, .medium))
                .foregroundStyle(Theme.ink.ui)
            Text("To start, choose the folder your agents should work in. Queen Bee saves your flows inside it.")
                .font(.dsSans(Theme.Size.title))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.inkSecondary.ui)
                .frame(maxWidth: 420)
            Button("Add Project Folder…") { WorkspaceView.pickProjectFolder() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}
