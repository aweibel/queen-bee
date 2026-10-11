import SwiftUI

@main
struct QueenBeeMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var client = RemoteClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                .task {
                    client.start()
                    #if DEBUG
                    DebugLaunch.report(client)
                    #endif
                }
                // In the background nothing can be shown, so nothing is fetched. Only the background counts:
                // the app is "inactive" for a moment every time Control Centre is pulled down.
                .onChange(of: scenePhase) { client.setActive(scenePhase != .background) }
        }
    }
}

/// Pairing until there is a Mac, then what the Mac says.
struct RootView: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        switch client.state {
        case .unpaired, .pairing:
            PairingView()
        case .mustPairAgain(let text):
            StoppedView(title: "Pair this device again", text: text, action: "Pair again") { client.forget() }
        case .needsUpdate(let text):
            StoppedView(title: "Update needed", text: text, action: "Try again") { client.tryAgain() }
        case .lookingForMac, .connecting, .connected:
            ConnectionView()
        }
    }
}

/// A full-screen message for when carrying on needs the person to do something.
private struct StoppedView: View {
    let title: String
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(text)
        } actions: {
            Button(action, action: perform).buttonStyle(.borderedProminent)
        }
    }
}

/// Stands in until the flows have somewhere to be shown: says whether the Mac is connected and how many flows it has.
private struct ConnectionView: View {
    @Environment(RemoteClient.self) private var client
    @State private var asksToForget = false

    private var macName: String { client.mac?.macName ?? "your Mac" }

    private var status: (title: String, detail: String, symbol: String) {
        if client.state == .connected {
            let count = client.mirror.library?.projects.reduce(0) { $0 + $1.flows.count } ?? 0
            return ("Connected to \(macName)", count == 1 ? "1 flow" : "\(count) flows", "checkmark.circle")
        }
        if client.localNetworkBlocked {
            return ("Queen Bee can't look for \(macName)", "Turn on Local Network for Queen Bee in Settings.", "wifi.slash")
        }
        if client.macNotFound {
            return ("\(macName) not found", "Check that Queen Bee is open on your Mac and that both are on the same Wi-Fi.", "wifi.exclamationmark")
        }
        return ("Connecting to \(macName)…", "", "arrow.triangle.2.circlepath")
    }

    var body: some View {
        ContentUnavailableView {
            Label(status.title, systemImage: status.symbol)
        } description: {
            Text(status.detail)
        } actions: {
            if client.localNetworkBlocked {
                Button("Open Settings") { openSettings() }.buttonStyle(.borderedProminent)
            }
            Button("Forget this Mac", role: .destructive) { asksToForget = true }
        }
        .confirmationDialog("Forget \(macName)?", isPresented: $asksToForget, titleVisibility: .visible) {
            Button("Forget this Mac", role: .destructive) { client.forget() }
        } message: {
            Text("This device will have to be paired again before it can connect.")
        }
    }
}

/// Opens this app's page in Settings, where the camera and the local network are turned on.
func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}
