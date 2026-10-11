#if DEBUG
import Foundation
import Network
import Observation
import QueenBeeCore
import QueenBeeLink

/// What a test tells the app as it launches it, and what the app tells the test back. None of this is in
/// a release build. `scripts/e2e.py` is the test.
///
///   -qbPairCode <code>                  start from nothing and pair with this code, with the first Mac found
///   -qbHost <address> -qbPairPort <n> -qbDevicePort <n>
///                                       with the code: pair and connect at these, without looking on the network
///   -qbShow macs|code                   open the pairing screens at the list of Macs, or at entering the code
///   -qbShow settings                    once connected, open the settings
///   -qbShow flows                       once connected, bring out the list of flows on an iPad held upright
///   -qbShow update|pairAgain|localNetwork
///                                       show that full-screen message and nothing else
///   -qbOpen <flow name>                 once connected, open the flow with this name
///
/// Arguments written this way are read as settings, which is how they get here.
enum DebugLaunch {
    /// Where the Mac listens for this device, when a test said so. Kept so that the app finds the Mac again
    /// when it is launched without arguments. Only a pairing made with arguments sets it.
    struct Direct: Equatable {
        var host: String
        var port: UInt16
        var endpoint: NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any) }
    }

    private static var defaults: UserDefaults { .standard }
    private static func port(_ key: String) -> UInt16? {
        UInt16(exactly: defaults.integer(forKey: key)).flatMap { $0 == 0 ? nil : $0 }
    }

    static var pairCode: PairingCode? { defaults.string(forKey: "qbPairCode").flatMap(PairingCode.init(text:)) }

    static var pairing: NWEndpoint? {
        guard let host = defaults.string(forKey: "qbHost"), let port = port("qbPairPort") else { return nil }
        return Direct(host: host, port: port).endpoint
    }

    static var direct: Direct? {
        guard let host = defaults.string(forKey: "qbHost"), let port = port("qbDevicePort") else { return nil }
        return Direct(host: host, port: port)
    }

    static var show: String? { defaults.string(forKey: "qbShow") }

    /// A full-screen message a test wants to look at, with the words the Mac would send.
    static var stoppedScreen: StoppedScreen.Reason? {
        switch show {
        case "update": .update("Update Queen Bee on this device, so both are on the same version.")
        case "pairAgain": .pairAgain(Remote.unpairedRefusal)
        case "localNetwork": .localNetwork("Example Mac")
        default: nil
        }
    }

    private static var hasOpenedNamedFlow = false

    /// Opens the flow a test named, once, as soon as the Mac has listed it.
    static func openNamedFlow(_ client: RemoteClient) {
        guard !hasOpenedNamedFlow, let name = defaults.string(forKey: "qbOpen") else { return }
        let flow = withObservationTracking {
            client.state == .connected ? client.mirror.library?.projects.flatMap(\.flows).first { $0.name == name } : nil
        } onChange: {
            Task { @MainActor in openNamedFlow(client) }
        }
        if let flow {
            hasOpenedNamedFlow = true
            client.open(flow.id)
        }
    }

    static var savedDirect: Direct? {
        get {
            guard let host = defaults.string(forKey: "debugDirectHost"), let port = port("debugDirectPort") else { return nil }
            return Direct(host: host, port: port)
        }
        set {
            defaults.set(newValue?.host, forKey: "debugDirectHost")
            defaults.set(newValue.map { Int($0.port) }, forKey: "debugDirectPort")
        }
    }

    /// Where the app says what state it is in, for a script that can't see the screen:
    /// Library/Caches/qb-state.json in the app's own folder.
    private static var stateFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("qb-state.json")
    }

    /// Writes the state now and again every time any of it changes.
    static func report(_ client: RemoteClient) {
        var fields: [String: Any] = [:]
        withObservationTracking {
            let (name, text): (String, String?) = switch client.state {
            case .unpaired: ("unpaired", nil)
            case .pairing: ("pairing", nil)
            case .lookingForMac: ("lookingForMac", nil)
            case .connecting: ("connecting", nil)
            case .connected: ("connected", nil)
            case .needsUpdate(let text): ("needsUpdate", text)
            case .mustPairAgain(let text): ("mustPairAgain", text)
            }
            fields = [
                "state": name,
                "text": text ?? NSNull(),
                "mac": client.mac?.macName ?? NSNull(),
                "macID": client.mac?.macID ?? NSNull(),
                "device": DeviceIdentity.deviceID,
                "macNotFound": client.macNotFound,
                "localNetworkBlocked": client.localNetworkBlocked,
                "openFlow": client.openFlow?.flow.name ?? NSNull(),
                // The number of cards in the open flow once the Mac has sent it, which is how a test knows it arrived.
                "openFlowCards": client.mirror.snapshot.map { $0.flow.cards.count } ?? NSNull(),
                "pairingProblem": client.pairingProblem ?? NSNull(),
                "flows": client.mirror.library?.projects.flatMap(\.flows).map(\.name) ?? [],
                "hasKey": DeviceIdentity.key != nil,
            ]
        } onChange: {
            Task { @MainActor in report(client) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}
#endif
