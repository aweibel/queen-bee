import SwiftUI

/// What the pill says: whether the Mac is there.
enum ConnectionStatus: Equatable {
    case connected(String)
    case reconnecting
    case macNotFound
    /// The Mac was there and turned this device's key down, several times running. The app goes on trying.
    case cantConnect
    /// This device's key can't be read until it is unlocked.
    case locked

    @MainActor init(_ client: RemoteClient) {
        if client.state == .connected {
            self = .connected(client.mac?.macName ?? "your Mac")
        } else if client.keyUnreadable {
            self = .locked
        } else if client.keyInDoubt {
            self = .cantConnect
        } else {
            // Not being connected is only "reconnecting" until the Mac has been looked for and not found.
            self = client.macNotFound ? .macNotFound : .reconnecting
        }
    }

    var text: String {
        switch self {
        case .connected(let mac): "Connected to \(mac)"
        case .reconnecting: "Reconnecting"
        case .macNotFound: "Mac not found"
        case .cantConnect: "Can't connect to your Mac — retrying"
        case .locked: "Unlock this device to connect"
        }
    }

    /// Whether there is more to say under the pill than fits in it.
    var hasHelp: Bool { self == .macNotFound || self == .cantConnect }

    /// What to say under "Can't connect".
    static let cantConnectHelp = "Your Mac didn't accept this device's key. It may have been removed on your Mac, or the connection was cut off. Queen Bee keeps trying. If you removed this device on your Mac, pair it again."

    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }

    /// What to check when the Mac can't be found, for anywhere there is room to say it.
    static let macNotFoundHelp = "Check that Queen Bee is open on your Mac and that both are on the same Wi-Fi."
    /// Added once the Mac has been missing for a while. A Mac that removed this device while it was away can't
    /// tell it so, and from here that looks the same as a Mac that isn't there.
    static let removedHelp = "If you removed this device on your Mac, open Settings here, choose “Forget this Mac” and pair again."

    /// What to say under "Mac not found", or "Can't connect".
    @MainActor static func help(_ client: RemoteClient) -> String {
        if ConnectionStatus(client) == .cantConnect { return cantConnectHelp }
        return client.macLongNotFound ? "\(macNotFoundHelp) \(removedHelp)" : macNotFoundHelp
    }
}

/// The connection, in a few words with a dot: green when connected, orange while trying, red when the Mac
/// can't be found. It carries no background of its own, so it can sit in a bar or in a panel.
struct ConnectionPill: View {
    @Environment(RemoteClient.self) private var client
    /// Leaves the Mac's name out, for where it is already written beside the pill.
    var isBrief = false

    var body: some View {
        let status = ConnectionStatus(client)
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(dot(for: status).ui)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(isBrief && status.isConnected ? "Connected" : status.text)
                .dsMono(Theme.Touch.caption, .medium)
                .foregroundStyle(Theme.ink.ui)
                .lineLimit(1)
        }
        .animation(Theme.Motion.standard, value: status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.hasHelp ? "\(status.text). \(ConnectionStatus.help(client))" : status.text)
    }

    private func dot(for status: ConnectionStatus) -> UIColor {
        switch status {
        case .connected: Theme.passInk
        case .reconnecting, .locked: Theme.live
        case .macNotFound, .cantConnect: Theme.failInk
        }
    }
}

extension View {
    /// What the Mac last said stays on screen while it is away, faded and out of reach, so it reads as old.
    func dimmedWhileAway(_ isConnected: Bool) -> some View {
        opacity(isConnected ? 1 : 0.4)
            .allowsHitTesting(isConnected)
            .animation(Theme.Motion.standard, value: isConnected)
    }
}
