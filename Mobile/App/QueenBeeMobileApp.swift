import SwiftUI

@main
struct QueenBeeMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var client = RemoteClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                // Ink, not the system's blue, for the back arrows and bar buttons the system draws.
                .tint(Theme.ink.ui)
                .task {
                    client.start()
                    #if DEBUG
                    DebugLaunch.report(client)
                    DebugLaunch.openNamedFlow(client)
                    DebugLaunch.expandNamedTerminal(client)
                    DebugBrowser.expandNamed(client)
                    DebugLaunch.showNamedPage(client)
                    DebugLaunch.viewNamedRun(client)
                    DebugLaunch.goToNamedWaiting(client)
                    DebugLaunch.doNamedSteps(client)
                    DebugLaunch.pressNamed(client)
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
        #if DEBUG
        // A test asks for a message it has no honest way to bring about.
        if let stopped = DebugLaunch.stoppedScreen {
            // The one that covers the settings is shown as the app shows it, with the way to forget the Mac on it.
            StoppedScreen(stopped, forget: DebugLaunch.show == "localNetwork" ? {} : nil) {}
        } else {
            content
        }
        #else
        content
        #endif
    }

    @ViewBuilder private var content: some View {
        switch client.state {
        case .unpaired, .pairing:
            PairingView()
        case .mustPairAgain(let text):
            StoppedScreen(.pairAgain(text)) { client.forget() }
        case .needsUpdate(let text):
            StoppedScreen(.update(text)) { client.tryAgain() }
        case .lookingForMac, .connecting, .connected:
            // Without the local network there is no Mac to find and nothing was ever shown, so say only that.
            // It covers the app's own settings, so the way to forget the Mac is put on it.
            if client.localNetworkBlocked {
                StoppedScreen(.localNetwork(client.mac?.macName ?? "your Mac"), forget: { client.forget() }) { openSettings() }
            } else {
                ShellView()
            }
        }
    }
}

/// Opens this app's page in Settings, where the camera and the local network are turned on.
func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}
