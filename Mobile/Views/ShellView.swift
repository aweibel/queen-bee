import SwiftUI

/// The app once it has a Mac: the flows, the open flow's canvas, and the details panel. Three columns where
/// there is room, as on an iPad; one screen after another where there isn't, as on an iPhone.
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

    var body: some View {
        Group {
            if sizeClass == .compact {
                StackShell { showsSettings = true }
            } else {
                SplitShell { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsSheet() }
        .fullScreenCover(item: expanded) { TerminalViewer(key: $0.id) }
        .asksBeforeActing()
        #if DEBUG
        .task { if DebugLaunch.show == "settings" { showsSettings = true } }
        #endif
    }
}

/// A session's key, as something a cover can be shown for.
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

/// iPad: the flows on the left, the canvas in the middle, the details on the right.
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
                            Button { showsDetails.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                        }
                    }
            }
        }
        // Outside the columns, so the panel keeps its place and its full height when the list of flows slides
        // over the canvas on an iPad held upright.
        .inspector(isPresented: $showsDetails) {
            InspectorPanel().edgeRule(.leading).inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        #if DEBUG
        // Upright, an iPad starts with the list of flows tucked away, and a test can't tap to bring it out.
        .task { if DebugLaunch.show == "flows" { columns = .all } }
        #endif
    }
}

/// iPhone: the list of flows, then the open flow's canvas, with the details in a sheet.
private struct StackShell: View {
    @Environment(RemoteClient.self) private var client
    let showSettings: () -> Void
    @State private var showsDetails = false
    /// Where on the screen the top of the details' sheet is, and where the foot of this view is.
    @State private var sheetTop: CGFloat = 0
    @State private var foot: CGFloat = 0

    /// How much of the canvas's foot the details cover. No more than two thirds: pulled up to full height
    /// they cover the canvas whole, and there is nothing left to fit the flow into.
    private var cover: CGFloat { showsDetails && sheetTop > 0 ? min(max(0, foot - sheetTop), foot * 2 / 3) : 0 }

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
                                Button { showsDetails = true } label: { Label("Details", systemImage: "info.circle") }
                            }
                        }
                }
        }
        // A sheet of its own, and not the system's inspector, which in a screen this narrow never came up.
        // At half height the canvas above it still takes taps, so a card can be picked with its details open.
        .sheet(isPresented: $showsDetails) {
            InspectorPanel()
                // What a button here or on the canvas asks first comes up over this sheet, not under it.
                .asksBeforeActing(overSheet: true)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { sheetTop = $0 }
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { foot = $0 }
        // With the details up, the canvas fits the flow into what shows above them. It is told through the
        // panel's model: a screen that has been pushed isn't drawn again when this one's own state changes.
        .onChange(of: cover, initial: true) { client.panel.cover = cover }
        .onChange(of: showsDetails, initial: true) { client.panel.isSheetUp = showsDetails }
        .onDisappear {
            client.panel.cover = 0
            client.panel.isSheetUp = false
        }
        // The details belong to the open flow, and go when it does.
        .onChange(of: client.mirror.openFlowID) { _, open in
            if open == nil { showsDetails = false }
        }
        // A terminal opens over everything. The sheet steps aside first: two things can't be put up at once.
        .onChange(of: client.terminals.expandedKey) { _, key in
            if key != nil { showsDetails = false }
        }
        #if DEBUG
        // A test that names a page of the panel wants to see it, and here the panel is a sheet nothing has brought up.
        .task {
            guard DebugLaunch.show.flatMap(PanelPage.init(rawValue:)) != nil else { return }
            while client.mirror.snapshot == nil { try? await Task.sleep(for: .milliseconds(200)) }
            showsDetails = true
        }
        #endif
    }
}
