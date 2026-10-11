import QueenBeeCore
import SwiftUI

/// The panel beside the canvas, for what the open flow and its cards have to say. On an iPhone it comes up as a sheet.
struct InspectorPanel: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details")
                    .dsMono(Theme.Touch.body, .medium)
                    .foregroundStyle(Theme.ink.ui)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // A sheet needs its own way out. Beside the canvas, the bar's button hides the panel.
                if sizeClass == .compact {
                    Button("Done") { dismiss() }.buttonStyle(.panel(.quiet))
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: Theme.Touch.target)
            .background(Theme.bar.ui)
            Hairline()
            ScrollView {
                content
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .dimmedWhileAway(client.state == .connected)
        }
        .background(Theme.surface.ui)
    }

    @ViewBuilder private var content: some View {
        if let open = client.openFlow {
            PanelSection(title: "Flow") {
                PanelRow(label: "Name", value: open.flow.name)
                Hairline()
                PanelRow(label: "Project", value: open.project.name)
                if let flow = client.mirror.snapshot?.flow {
                    Hairline()
                    PanelRow(label: "Cards", value: "\(flow.cards.count)")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("No flow open").dsMono(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
                Text("Open a flow to see its details here.").dsSans().foregroundStyle(Theme.inkSecondary.ui)
            }
        }
    }
}
