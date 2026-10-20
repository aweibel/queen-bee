import QueenBeeCore
import QueenBeeLink
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
                    AddressSection()
                    NotificationsSection()
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

/// Where to reach the Mac when it isn't on the same Wi-Fi: its name or address, typed in, as over Tailscale.
private struct AddressSection: View {
    @Environment(RemoteClient.self) private var client
    @State private var text = ""
    @State private var problem: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            PanelSection(title: "Connect by address") {
                TextField("Your Mac's name or address", text: $text)
                    .dsMono(Theme.Touch.body - 1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .focused($isTyping)
                    .onSubmit(save)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(minHeight: Theme.Touch.target)
                    .accessibilityLabel("Your Mac's name or address")
                if client.macAddress != nil || !text.isEmpty {
                    Hairline()
                    HStack(spacing: Theme.Space.s) {
                        Button("Save", action: save)
                            .buttonStyle(.panel(.filled))
                            .disabled(MacAddress(text: text) == nil || MacAddress(text: text) == client.macAddress)
                        if client.macAddress != nil {
                            Button("Remove") {
                                text = ""
                                problem = nil
                                client.setMacAddress(nil)
                            }
                            .buttonStyle(.panel(.quiet))
                        }
                    }
                    .padding(Theme.Space.s)
                }
            }
            Text(problem ?? "For a Mac that isn't on the same Wi-Fi, such as one you reach over Tailscale. On the Mac, turn on “Let devices connect by address too” in Settings, under Remote, and type one of the addresses it shows. Add “:port” if the Mac shows a port other than \(String(Remote.addressPort)).")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle((problem == nil ? Theme.inkSecondary : Theme.failInk).ui)
        }
        .onAppear { text = client.macAddress?.text ?? "" }
    }

    private func save() {
        guard let address = MacAddress(text: text) else {
            problem = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "That isn't an address Queen Bee can use. Type a name such as mac.example.ts.net, or an address such as 100.64.0.7, with “:port” after it if needed."
            return
        }
        problem = nil
        isTyping = false
        text = address.text
        client.setMacAddress(address)
    }
}

/// Whether this device shows notifications about runs while the app is in the background.
private struct NotificationsSection: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let notifier = client.notifier
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            PanelSection(title: "Notifications") {
                Toggle(isOn: Binding(get: { notifier.isOn }, set: { on in
                    notifier.isOn = on
                    if on { Task { await notifier.ask() } }
                })) {
                    Text("Tell me when a run needs me or ends").dsSans().foregroundStyle(Theme.ink.ui)
                }
                .tint(Theme.ink.ui)
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: Theme.Touch.target)
                if notifier.isOn, notifier.isAllowed == false {
                    Hairline()
                    Button("Open Settings") { openSettings() }
                        .buttonStyle(.panel(.quiet))
                        .padding(Theme.Space.s)
                }
            }
            Text(notifier.isOn && notifier.isAllowed == false
                 ? "Notifications are off for Queen Bee in this device's Settings. Turn them on there to be told."
                 : "Only for a little while after you leave the app: once iOS stops it in the background, nothing more arrives until you open it again. A device that can control your Mac can approve, reject and allow from the notification.")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
        }
        .task { await notifier.refreshPermission() }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await notifier.refreshPermission() } } }
    }
}
