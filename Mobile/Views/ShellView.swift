import SwiftUI

/// The app once it has a Mac: the flows, the open flow's canvas, and the details panel. Three columns where
/// there is room, as on an iPad; one screen after another where there isn't, as on an iPhone.
struct ShellView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsSettings = false

    var body: some View {
        Group {
            if sizeClass == .compact {
                StackShell { showsSettings = true }
            } else {
                SplitShell { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsSheet() }
        #if DEBUG
        .task { if DebugLaunch.show == "settings" { showsSettings = true } }
        #endif
    }
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
                Text(ConnectionStatus.macNotFoundHelp)
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
                CanvasArea(showFlows: columns == .detailOnly ? { columns = .all } : nil)
                    .overlay(alignment: .bottomLeading) {
                        ConnectionBar(showSettings: showSettings).padding(Theme.Space.m)
                    }
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
            InspectorPanel().edgeRule(.leading).inspectorColumnWidth(min: 260, ideal: 320, max: 440)
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
                    CanvasArea()
                        .overlay(alignment: .bottomLeading) {
                            ConnectionBar(showSettings: showSettings).padding(Theme.Space.m)
                        }
                        .navigationTitle(client.openFlow?.flow.name ?? "")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button { showsDetails = true } label: { Label("Details", systemImage: "info.circle") }
                            }
                        }
                        .inspector(isPresented: $showsDetails) {
                            InspectorPanel().presentationDetents([.medium, .large])
                        }
                }
        }
    }
}
