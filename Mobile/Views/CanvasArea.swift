import QueenBeeCore
import SwiftUI

/// The middle of the app: the drafting paper, and the open flow on it.
struct CanvasArea: View {
    @Environment(RemoteClient.self) private var client
    /// Brings the list of flows back when it is hidden, if it can be. Nil when the list is on show or one tap back.
    var showFlows: (() -> Void)?
    let showSettings: () -> Void

    /// How much of the canvas's top the banners cover, and how much of its foot the run bar and the
    /// connection strip do, gap and all. The canvas keeps the flow clear of both when it fits it.
    @State private var top: CGFloat = 0
    @State private var foot: CGFloat = Theme.Touch.target + Theme.Space.m * 2

    var body: some View {
        Group {
            if let open = client.openFlow {
                // The canvas draws its own paper, so the dots scroll and zoom with the cards as on the Mac.
                CanvasRepresentable(client: client, top: top, foot: max(foot, client.panel.cover))
                    .ignoresSafeArea()
                    .overlay {
                        // Asked for and not sent yet.
                        if client.mirror.snapshot == nil { Plate(title: open.flow.name, text: "Opening…") }
                    }
            } else if client.mirror.openFlowID != nil {
                // The Mac has closed or deleted the flow that was open.
                Plate(symbol: "point.3.connected.trianglepath.dotted", title: "This flow has gone",
                      text: "It isn't in Queen Bee on your Mac any more. Pick another from the list.") { flowsButton }
                    .background { Paper() }
            } else {
                Plate(symbol: "point.3.connected.trianglepath.dotted", title: "No flow open",
                      text: "Pick a flow from the list to watch it here.") { flowsButton }
                    .background { Paper() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            // Measured, so that fitting the flow to the screen leaves it clear of them.
            CanvasBanners()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { top = $0 > 0 ? $0 + Theme.Space.m * 2 : 0 }
                .padding(Theme.Space.m)
        }
        .dimmedWhileAway(client.state == .connected)
        // Over the dimming, not under it: the connection strip is what says why the rest is dim.
        .overlay(alignment: .bottom) {
            CanvasFoot(showSettings: showSettings)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foot = $0 + Theme.Space.m * 2 }
                .padding(Theme.Space.m)
        }
        // In the corner over the run bar, where the banners at the top never reach.
        .overlay(alignment: .bottomTrailing) {
            Minimap()
                .padding(.trailing, Theme.Space.m)
                .padding(.bottom, foot)
        }
        .animation(Theme.Motion.standard, value: client.canvas.showsMap)
        // Over everything on the canvas, the bars included: a menu is the one thing being done while it is up.
        .overlay { EditMenuLayer(foot: foot) }
    }

    @ViewBuilder private var flowsButton: some View {
        if let showFlows {
            Button("Show flows", action: showFlows).buttonStyle(.panel())
        }
    }
}
