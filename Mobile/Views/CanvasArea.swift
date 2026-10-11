import QueenBeeCore
import SwiftUI

/// The middle of the app: the drafting paper, and the open flow on it.
struct CanvasArea: View {
    @Environment(RemoteClient.self) private var client
    /// Brings the list of flows back when it is hidden, if it can be. Nil when the list is on show or one tap back.
    var showFlows: (() -> Void)?

    var body: some View {
        ZStack {
            Paper()
            Group {
                if let open = client.openFlow {
                    // The canvas goes here. Until it is drawn, the flow's name stands in for it.
                    Plate(title: open.flow.name, text: summary(of: open))
                } else if client.mirror.openFlowID != nil {
                    // The Mac has closed or deleted the flow that was open.
                    Plate(symbol: "point.3.connected.trianglepath.dotted", title: "This flow has gone",
                          text: "It isn't in Queen Bee on your Mac any more. Pick another from the list.") { flowsButton }
                } else {
                    Plate(symbol: "point.3.connected.trianglepath.dotted", title: "No flow open",
                          text: "Pick a flow from the list to watch it here.") { flowsButton }
                }
            }
            .dimmedWhileAway(client.state == .connected)
        }
    }

    @ViewBuilder private var flowsButton: some View {
        if let showFlows {
            Button("Show flows", action: showFlows).buttonStyle(.panel())
        }
    }

    private func summary(of open: RemoteClient.OpenFlow) -> String {
        guard let flow = client.mirror.snapshot?.flow else { return "Opening…" }
        let cards = flow.cards.count == 1 ? "1 card" : "\(flow.cards.count) cards"
        return "\(open.project.name) · \(cards)"
    }
}
