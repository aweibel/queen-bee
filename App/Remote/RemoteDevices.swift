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

    static func read(_ account: String) -> Data? { lookUp(account).key }

    /// The key, or whether it is known to be gone or only couldn't be read this time: see `StoredKey`.
    static func lookUp(_ account: String) -> StoredKey {
        if TestHarness.isEnabled { return memory[account].map(StoredKey.found) ?? .missing }
        var found: CFTypeRef?
        let wanted = query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        let status = SecItemCopyMatching(wanted as CFDictionary, &found)
        return StoredKey(status: status, data: found as? Data)
    }

    /// Fails every write, so a test can see what pairing does when a key can't be kept. Only a test copy sets it.
    static var failsWrites = false

    /// False if the key couldn't be kept. A key already kept under that name is left as it was then.
    static func write(_ data: Data, _ account: String) -> Bool {
        if TestHarness.isEnabled {
            if failsWrites { return false }
            memory[account] = data
            return true
        }
        let item = query(account).merging([kSecValueData as String: data,
                                           kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecDuplicateItem else { return added == errSecSuccess }
        return SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
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
            // A device whose key has gone from the Keychain can't connect, so it isn't listed. One whose key couldn't be
            // read, as when the Keychain is locked or its prompt was turned down, is kept: dropped here, the next save
            // would write it out of the file for good. Its listener waits until the key can be read.
            devices = saved.devices.filter { KeyVault.lookUp(Self.account($0.id)).keepsDevice }
        }
    }

    private static func account(_ id: String) -> String { "device-" + id }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(macID: macID, devices: devices)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func key(for id: String) -> Data? { KeyVault.read(Self.account(id)) }
    func storedKey(for id: String) -> StoredKey { KeyVault.lookUp(Self.account(id)) }

    /// Pairs a device, or pairs it again with a new key, and returns that key. Nil if the key couldn't be
    /// kept: nothing has changed then, because a device listed without its key could never connect.
    func add(id: String, name: String) -> Data? {
        let key = LinkSecurity.randomKey()
        guard KeyVault.write(key, Self.account(id)) else { return nil }
        devices.removeAll { $0.id == id }
        devices.append(PairedDevice(id: id, name: name, added: Date(), canControl: false))
        save()
        return key
    }

    /// Puts a device back as it was before it was paired again. False if its old key couldn't be kept.
    func restore(_ device: PairedDevice, key: Data) -> Bool {
        guard KeyVault.write(key, Self.account(device.id)) else { return false }
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        save()
        return true
    }

    /// Whether a device may do more than watch, read from the list as it is now.
    func canControl(_ id: String) -> Bool { devices.first { $0.id == id }?.canControl ?? false }

    func setCanControl(_ on: Bool, for id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].canControl != on else { return }
        devices[index].canControl = on
        save()
    }

    func remove(_ id: String) {
        KeyVault.delete(Self.account(id))
        devices.removeAll { $0.id == id }
        save()
    }
}
