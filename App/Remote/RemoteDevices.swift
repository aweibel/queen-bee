import Foundation
import Observation
import QueenBeeLink
import Security

/// One iPad or iPhone that has been paired with this Mac.
struct PairedDevice: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var added: Date
    /// False means it may watch and nothing else.
    var canControl: Bool
}

/// Where keys are kept: the Keychain, or memory only in a test copy, so a test never touches the real Keychain.
enum KeyVault {
    private static var memory: [String: Data] = [:]
    private static var service: String { (Bundle.main.bundleIdentifier ?? "dev.queenbee.app") + ".remote" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        if TestHarness.isEnabled { return memory[account] }
        var found: CFTypeRef?
        let wanted = query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        return SecItemCopyMatching(wanted as CFDictionary, &found) == errSecSuccess ? found as? Data : nil
    }

    static func write(_ data: Data, _ account: String) {
        if TestHarness.isEnabled { memory[account] = data; return }
        SecItemDelete(query(account) as CFDictionary)
        let item = query(account).merging([kSecValueData as String: data,
                                           kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        if TestHarness.isEnabled { memory[account] = nil; return }
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// The devices paired with this Mac. Their names are in a file; their keys are only ever in the Keychain.
@Observable
final class RemoteDevices {
    private struct Saved: Codable {
        var macID: String
        var devices: [PairedDevice]
    }

    private(set) var devices: [PairedDevice] = []
    /// A random name for this Mac, so a device finds it again whatever the Mac is called.
    private(set) var macID = UUID().uuidString.lowercased()
    private var url: URL { AppServices.shared.supportDirectory.appendingPathComponent("remote-devices.json") }

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            macID = saved.macID
            // A device whose key has gone from the Keychain can't connect, so it isn't listed.
            devices = saved.devices.filter { KeyVault.read(Self.account($0.id)) != nil }
        }
    }

    private static func account(_ id: String) -> String { "device-" + id }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(macID: macID, devices: devices)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func key(for id: String) -> Data? { KeyVault.read(Self.account(id)) }

    /// Pairs a device, or pairs it again with a new key, and returns that key.
    func add(id: String, name: String) -> Data {
        let key = LinkSecurity.randomKey()
        KeyVault.write(key, Self.account(id))
        devices.removeAll { $0.id == id }
        devices.append(PairedDevice(id: id, name: name, added: Date(), canControl: false))
        save()
        return key
    }

    func remove(_ id: String) {
        KeyVault.delete(Self.account(id))
        devices.removeAll { $0.id == id }
        save()
    }
}
