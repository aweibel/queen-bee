import QueenBeeCore
import SwiftUI

/// The app's icon in the menu bar. A raised hand and a count when cards are waiting on you, a filled hexagon
/// while a run is going.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    private var services: AppServices { AppServices.shared }

    var body: some View {
        let waiting = services.needingYou.count
        let running = services.allFlows.contains(where: \.isRunning)
        HStack(spacing: 3) {
            Image(systemName: waiting > 0 ? "hand.raised.fill" : running ? "hexagon.fill" : "hexagon")
            if waiting > 0 { Text("\(waiting)") }
        }
        .accessibilityLabel(waiting > 0 ? "Queen Bee, \(waiting) waiting on you" : running ? "Queen Bee, running" : "Queen Bee")
        // The menu bar item is there even while the window is closed, so it is what can open the window again.
        .onAppear { services.openWorkspace = { openWindow(id: AppServices.workspaceID) } }
    }
}

/// The menu under the menu bar icon: what is waiting on you, the flows that are open and whether each is running,
/// and Stop for a run that is.
struct MenuBarMenu: View {
    private var services: AppServices { AppServices.shared }

    var body: some View {
        let waiting = services.needingYou
        let open = services.allFlows.filter { $0.isOpen || $0.isRunning }
        Button("Show Queen Bee") { services.showWorkspace() }
        Divider()
        if waiting.isEmpty {
            Text("Nothing is waiting on you")
        } else {
            Section("Waiting on you") {
                ForEach(Array(waiting.enumerated()), id: \.offset) { _, item in
                    Button("\(item.card.name) · \(item.controller.flow.name)") {
                        services.reveal(flowID: item.controller.flow.id, cardID: item.card.id)
                    }
                }
            }
        }
        Divider()
        if open.isEmpty {
            Text("No flow is open")
        } else {
            Section("Flows") {
                ForEach(Array(open.enumerated()), id: \.offset) { _, controller in
                    if controller.isRunning {
                        Menu("\(controller.flow.name) · running") {
                            Button("Show") { services.reveal(flowID: controller.flow.id, cardID: nil) }
                            Button("Stop the Run") { Task { await controller.stop() } }
                        }
                    } else {
                        Button("\(controller.flow.name) · not running") { services.reveal(flowID: controller.flow.id, cardID: nil) }
                    }
                }
            }
        }
        Divider()
        Button("Quit Queen Bee") { NSApp.terminate(nil) }
    }
}
