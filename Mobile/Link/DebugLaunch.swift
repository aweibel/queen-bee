#if DEBUG
import Foundation
import Network
import Observation
import QueenBeeLink

/// What a test tells the app as it launches it, and what the app tells the test back. None of this is in
/// a release build. `scripts/e2e.py` is the test.
///
///   -qbPairCode <code>                  start from nothing and pair with this code, with the first Mac found
///   -qbHost <address> -qbPairPort <n> -qbDevicePort <n>
///                                       with the code: pair and connect at these, without looking on the network
///   -qbShow macs|code                   open the pairing screens at the list of Macs, or at entering the code
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
