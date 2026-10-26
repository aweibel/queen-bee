import QueenBeeCore
import QueenBeeDesign
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

/// The app's one window, in Linear's frame: the sidebar sits on the window's own colour, and the flow sits in a
/// rounded panel inset from the window's edges, with its header and tabs along the top and the side panel
/// down its right.
struct WorkspaceView: View {
    static let gap = Theme.Space.m

    @AppStorage("showsSidebar") private var showsSidebar = true
    @AppStorage("showsPanel") private var showsPanel = true
    @AppStorage("panelWidth") private var panelWidth = 420.0
    @State private var tab = PanelTab.orchestrator
    @Environment(\.openWindow) private var openWindow
    private var services: AppServices { AppServices.shared }

    var body: some View {
        ZStack {
            Palette.chrome.color.ignoresSafeArea()
            HStack(spacing: 0) {
                if showsSidebar {
                    SidebarView()
                        .frame(width: DS.Size.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                panel
                    .insetPanel()
                    .padding(.vertical, DS.Size.panelInset)
                    .padding(.trailing, DS.Size.panelInset)
                    .padding(.leading, showsSidebar ? 0 : DS.Size.panelInset)
            }
            .ignoresSafeArea()

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
        // The first time a flow opens in a git repository, it asks where it works. Its agents wait for the answer.
        .sheet(isPresented: Binding(get: { services.current?.asksForWorkplace == true }, set: { shown in
            guard !shown, let controller = services.current, controller.asksForWorkplace else { return }
            Task { await controller.answerWorkplaceQuestion(nil) }
        })) {
            if let controller = services.current {
                WorkplaceForm(controller: controller, isFirstRun: true) {}
                    .presentationBackground(Theme.surface.ui)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    /// The inset panel: the header, the tabs, and the flow with the side panel beside it.
    private var panel: some View {
        VStack(spacing: 0) {
            FlowHeader(controller: services.current, showsSidebar: $showsSidebar, showsPanel: $showsPanel)
            DSDivider()
            if let controller = services.current {
                FlowTabs(controller: controller)
                DSDivider()
            }
            HStack(spacing: 0) {
                ZStack {
                    if let controller = services.current {
                        CanvasRepresentable(controller: controller)
                            .id(controller.flow.id)
                        CanvasControls(controller: controller) {
                            tab = .log
                            showsPanel = true
                        } showOrchestrator: {
                            tab = .orchestrator
                            showsPanel = true
                        }
                        .environment(\.orchestratorIsShowing, showsPanel && tab == .orchestrator)
                        .padding(Self.gap)
                        .id(controller.flow.id)
                        if controller.showsFlowSettings {
                            // Over the canvas rather than in its place, so the agents' terminals keep their views.
                            ScrollView {
                                FlowSettingsView(controller: controller)
                                    .frame(maxWidth: 520)
                                    .padding(DS.Space.xl)
                                    .frame(maxWidth: .infinity)
                            }
                            .background(Palette.panel.color)
                            .transition(.opacity)
                        }
                    } else if services.projects.isEmpty {
                        WelcomeView()
                    } else {
                        ContentUnavailableView("No flow selected", systemImage: "point.3.connected.trianglepath.dotted",
                                               description: Text("Pick a flow on the left, or add one to a project."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                if showsPanel, let controller = services.current {
                    DSDivider(vertical: true)
                    SidePanel(controller: controller, tab: $tab, width: $panelWidth)
                        .frame(width: panelWidth)
                        .id(controller.flow.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Theme.Motion.standard, value: services.current?.showsFlowSettings)
        }
    }

    /// How much of the canvas's left and right the floating controls cover, so "fit" can keep the flow clear of them.
    private var obstruction: CanvasObstruction {
        CanvasObstruction(left: Self.gap + PaletteView.width + Self.gap, right: Self.gap)
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
