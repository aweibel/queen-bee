import SwiftUI

/// Which Mac this device is paired with, the way to forget it, and the app's version.
struct SettingsSheet: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var asksToForget = false

    private var macName: String { client.mac?.macName ?? "your Mac" }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    PanelSection(title: "Paired Mac") {
                        PanelRow(label: "Name", value: macName)
                        Hairline()
                        HStack {
                            Text("Connection").dsSans().foregroundStyle(Theme.ink.ui)
                            Spacer(minLength: Theme.Space.s)
                            ConnectionPill(isBrief: true)
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .frame(minHeight: Theme.Touch.target)
                        .accessibilityElement(children: .combine)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Button("Forget this Mac") { asksToForget = true }
                            .buttonStyle(.panel(.danger, wide: true))
                            .confirmationDialog("Forget \(macName)?", isPresented: $asksToForget, titleVisibility: .visible) {
                                Button("Forget this Mac", role: .destructive) {
                                    dismiss()
                                    client.forget()
                                }
                            } message: {
                                Text("This device will have to be paired again before it can connect.")
                            }
                        Text("This device stops connecting to \(macName). To use it again, pair it again from Settings on the Mac.")
                            .dsSans(Theme.Touch.caption + 1)
                            .foregroundStyle(Theme.inkSecondary.ui)
                    }
                    PanelSection(title: "About") {
                        PanelRow(label: "Queen Bee", value: "Version \(version)")
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            // The surface, not the paper: the lighter ink of the headings and the note is too faint on paper.
            .background(Theme.surface.ui)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.ink.ui)
    }
}
