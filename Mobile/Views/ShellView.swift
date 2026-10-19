import SwiftUI

/// The app once it has a Mac: the flows, the open flow's canvas, and the panel with the details of what is
/// selected. Three columns where there is room, as on an iPad; one screen after another where there isn't,
/// as on an iPhone, with the panel and the details in sheets.
struct ShellView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsSettings = false

    /// The session whose terminal is open full screen. Closing the cover gives the terminal back.
    private var expanded: Binding<ExpandedTerminal?> {
        Binding {
            client.terminals.expandedKey.map(ExpandedTerminal.init)
        } set: { new in
            if new == nil { client.terminals.expand(nil) }
        }
    }

    /// The agent card whose browser is open full screen. Closing the cover stops it being watched full screen.
    private var expandedBrowser: Binding<ExpandedTerminal?> {
        Binding {
            client.browsers.expandedCard.map(ExpandedTerminal.init)
        } set: { new in
            if new == nil { client.openBrowser(nil) }
        }
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                StackShell { showsSettings = true }
            } else {
                SplitShell { showsSettings = true }
            }
        }
        // On the shells, not beside the terminal's cover: one view presents one cover at a time.
        .fullScreenCover(item: expandedBrowser) { BrowserViewer(cardID: $0.id) }
        .sheet(isPresented: $showsSettings) { SettingsSheet() }
        .fullScreenCover(item: expanded) { TerminalViewer(key: $0.id) }
        .asksBeforeActing()
        .asksBeforeEditing()
        .asksAboutFlows()
        #if DEBUG
        .task { if DebugLaunch.show == "settings" { showsSettings = true } }
        #endif
    }
}

/// A session's key, or a card's id, as something a cover can be shown for.
private struct ExpandedTerminal: Identifiable {
    let id: String
}

/// The connection and the way to the settings, in one strip at the foot of the paper, where the Mac has its status line.
struct ConnectionBar: View {
    @Environment(RemoteClient.self) private var client
    let showSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ConnectionPill()
                    .padding(.horizontal, Theme.Space.m)
                Rectangle().fill(Theme.hairline.ui).frame(width: 1, height: Theme.Touch.target)
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.ink.ui)
                        .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            if ConnectionStatus(client) == .macNotFound {
                Hairline()
                Text(ConnectionStatus.help(client))
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    // The strip is as wide as what is in it, and this sentence on one line would be the whole screen.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(Theme.Space.m)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .floatingPanel()
        .animation(Theme.Motion.standard, value: ConnectionStatus(client))
    }
}

/// iPad: the flows on the left, the canvas in the middle, the panel on the right, with the details of what is
/// selected over it.
private struct SplitShell: View {
    @Environment(RemoteClient.self) private var client
    let showSettings: () -> Void
    @State private var columns = NavigationSplitViewVisibility.automatic
    @AppStorage("showsDetails") private var showsDetails = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            FlowList()
                .edgeRule(.trailing)
                .navigationTitle("Flows")
                .navigationBarTitleDisplayMode(.inline)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            NavigationStack {
                CanvasArea(showFlows: columns == .detailOnly ? { columns = .all } : nil, showSettings: showSettings)
                    .navigationTitle(client.openFlow?.flow.name ?? "Queen Bee")
                    .navigationSubtitle(client.openFlow?.project.name ?? "")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { showsDetails.toggle() } label: { Label("Panel", systemImage: "sidebar.trailing") }
                                .accessibilityHint(showsDetails ? "Hides the panel beside the canvas." : "Shows the panel beside the canvas.")
                        }
                    }
            }
        }
        // Outside the columns, so the panel keeps its place and its full height when the list of flows slides
        // over the canvas on an iPad held upright.
        .inspector(isPresented: $showsDetails) {
            PanelColumn().edgeRule(.leading).inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        // What is selected has its details in the panel, so a panel put away comes back for them, as the Mac's
        // inspector does. Hidden again, it stays hidden until something else is selected.
        .onChange(of: client.canvas.selection) { _, selection in
            if selection != .none { showsDetails = true }
        }
        #if DEBUG
        // Upright, an iPad starts with the list of flows tucked away, and a test can't tap to bring it out.
        .task { if DebugLaunch.show == "flows" { columns = .all } }
        #endif
    }
}

/// iPhone: the list of flows, then the open flow's canvas. What is selected has its details in a sheet, which
/// comes up as it is selected and takes the selection with it when it is put away. The panel's tabs are a
/// sheet of their own, from the bar's button. One of the two at a time: either puts the other away.
private struct StackShell: View {
    @Environment(RemoteClient.self) private var client
    let showSettings: () -> Void
    /// The sheet that is up, as the sheet itself last said. Pulling it down puts away that one and no other.
    @State private var presented: PanelSheet?
    /// Where on the screen the top of the sheet is, and where the foot of this view is.
    @State private var sheetTop: CGFloat = 0
    @State private var foot: CGFloat = 0
    /// How far up the sheet is pulled.
    @State private var detent = PresentationDetent.medium

    private var sheet: Binding<PanelSheet?> {
        Binding {
            client.sheet
        } set: { new in
            // Only the sheet that was put away is closed. One changing for the other, or stepping aside for a
            // terminal full screen, is not putting either away.
            if new == nil, let presented, presented == client.sheet { client.closeSheet(presented) }
        }
    }

    /// How much of the canvas's foot the sheet covers. No more than two thirds: pulled up to full height it
    /// covers the canvas whole, and there is nothing left to fit the flow into.
    private var cover: CGFloat { presented != nil && sheetTop > 0 ? min(max(0, foot - sheetTop), foot * 2 / 3) : 0 }

    /// The canvas is on screen exactly when a flow is open, so going back closes the flow.
    private var path: Binding<[String]> {
        Binding {
            client.mirror.openFlowID.map { [$0] } ?? []
        } set: { new in
            if new.isEmpty, client.mirror.openFlowID != nil { client.open(nil) }
        }
    }

    var body: some View {
        NavigationStack(path: path) {
            FlowList()
                .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
                    ConnectionBar(showSettings: showSettings).padding(Theme.Space.m)
                }
                .background(Theme.surface.ui)
                .navigationTitle("Flows")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: String.self) { _ in
                    CanvasArea(showSettings: showSettings)
                        .navigationTitle(client.openFlow?.flow.name ?? "")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button { client.showTabs() } label: { Label("Orchestrator, Run and History", systemImage: "rectangle.bottomhalf.inset.filled") }
                                    .accessibilityLabel("Orchestrator, run and history")
                                    .accessibilityHint("Shows the panel with the orchestrator, the run on show and the runs so far.")
                            }
                        }
                }
        }
        // A sheet of its own, and not the system's inspector, which in a screen this narrow never came up.
        // At half height the canvas above it still takes taps, so another card can be picked with the details up.
        .sheet(item: sheet) { sheet in
            Group {
                switch sheet {
                case .details: DetailsScreen()
                case .tabs: InspectorPanel(isSheet: true)
                }
            }
            // What a button here or on the canvas asks first comes up over this sheet, not under it.
            .asksBeforeActing(overSheet: true)
            .asksBeforeEditing(overSheet: true)
            .asksAboutFlows(overSheet: true)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { sheetTop = $0 }
            .onAppear { presented = sheet }
            .onDisappear {
                if presented == sheet { presented = nil }
                client.panel.isSheetSettled = false
            }
            // A moment for it to finish sliding up, which nothing says when it has.
            .task(id: sheet) {
                client.panel.isSheetSettled = false
                try? await Task.sleep(for: .milliseconds(500))
                client.panel.isSheetSettled = !Task.isCancelled
            }
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationContentInteraction(.scrolls)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { foot = $0 }
        // With a sheet up, the canvas fits the flow into what shows above it. It is told through the panel's
        // model: a screen that has been pushed isn't drawn again when this one's own state changes.
        .onChange(of: cover, initial: true) { client.panel.cover = cover }
        .onAppear { client.panel.usesSheets = true }
        // Each sheet comes up at half height, however far the last one was pulled.
        .onChange(of: presented) {
            client.panel.isSheetPresented = presented != nil
            if presented == nil { detent = .medium }
        }
        .onDisappear {
            client.panel.cover = 0
            client.panel.usesSheets = false
            client.panel.isSheetPresented = false
        }
        // Selecting something brings up its details, in place of the tabs.
        .onChange(of: client.canvas.selection) { _, selection in
            if selection != .none { client.panel.showsTabs = false }
        }
        // The sheets belong to the open flow, and go when it does.
        .onChange(of: client.mirror.openFlowID) { _, open in
            if open == nil { client.panel.showsTabs = false }
        }
        #if DEBUG
        // A test that names a tab's page wants to see it, and here the tabs are a sheet nothing has brought up.
        .task {
            guard DebugLaunch.show.flatMap(PanelPage.init(rawValue:)) != nil else { return }
            while client.mirror.snapshot == nil { try? await Task.sleep(for: .milliseconds(200)) }
            if !client.wantsDetails { client.showTabs() }
        }
        // A test can't pull a sheet up. With `-qbDetent large` each sheet comes up at full height.
        .onChange(of: presented) { if DebugLaunch.detent == "large", presented != nil { detent = .large } }
        #endif
    }
}
