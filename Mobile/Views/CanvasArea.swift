import QueenBeeCore
import SwiftUI

/// The middle of the app: the drafting paper, and the open flow on it.
struct CanvasArea: View {
    @Environment(RemoteClient.self) private var client
    /// Brings the list of flows back when it is hidden, if it can be. Nil when the list is on show or one tap back.
    var showFlows: (() -> Void)?

    /// The connection strip floats over the canvas's foot: its own height and the gap on either side of it.
    private static let foot = Theme.Touch.target + Theme.Space.m * 2
    /// How much of the canvas's top the banners cover, gap and all. Nothing when there are none.
    @State private var top: CGFloat = 0

    var body: some View {
        Group {
            if let open = client.openFlow {
                // The canvas draws its own paper, so the dots scroll and zoom with the cards as on the Mac.
                CanvasRepresentable(client: client, top: top, foot: max(Self.foot, client.panel.cover))
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
    }

    @ViewBuilder private var flowsButton: some View {
        if let showFlows {
            Button("Show flows", action: showFlows).buttonStyle(.panel())
        }
    }
}
