import Foundation
import Observation
import os
import QueenBeeLink
import Security

/// One iPad or iPhone that has been paired with this Mac.
struct PairedDevice: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var added: Date
    /// False means it may watch and nothing else.
    var canControl: Bool

    init(id: String, name: String, added: Date, canControl: Bool) {
        self.id = id; self.name = name; self.added = added; self.canControl = canControl
    }

    /// Only the id is needed. A device whose other details can't be read keeps its pairing, as a device that may
    /// only watch until "Can control" is turned on again.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? RemoteDevices.unnamed
        added = (try? container.decodeIfPresent(Date.self, forKey: .added)) ?? Date()
        canControl = (try? container.decodeIfPresent(Bool.self, forKey: .canControl)) ?? false
    }
}

/// A keychain, as one place keys can be kept: the data protection keychain, or the login keychain an earlier
/// version kept them in.
private struct KeychainStore: KeyStore {
    let service: String
    let dataProtection: Bool

    private func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    func lookUp(_ account: String) -> StoredKey {
        var found: CFTypeRef?
        let wanted = query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        let status = SecItemCopyMatching(wanted as CFDictionary, &found)
        return StoredKey(status: status, data: found as? Data)
    }

    func write(_ data: Data, _ account: String) -> OSStatus {
        let item = query(account).merging([kSecValueData as String: data,
                                           kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecDuplicateItem else { return added }
        return SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    @discardableResult func delete(_ account: String) -> OSStatus { SecItemDelete(query(account) as CFDictionary) }

    func accounts() -> [String] {
        var found: CFTypeRef?
        let wanted = query().merging([kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]) { $1 }
        guard SecItemCopyMatching(wanted as CFDictionary, &found) == errSecSuccess, let items = found as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Where keys are kept: the data protection keychain, which asks nobody and is tied to this app, with keys an
/// earlier version kept in the login keychain moved there the first time each is read. A copy of the app
/// built without the entitlement the data protection keychain needs goes on using the login keychain. A test
/// copy keeps keys in memory, so a test never touches the real Keychain.
enum KeyVault {
    private static let memory = MemoryKeyStore()
    private static var service: String { (Bundle.main.bundleIdentifier ?? "dev.queenbee.app") + ".remote" }
    private static var store: any KeyStore {
        if TestHarness.isEnabled { return memory }
        return MigratingKeyStore(modern: KeychainStore(service: service, dataProtection: true),
                                 legacy: KeychainStore(service: service, dataProtection: false))
    }

    static func read(_ account: String) -> Data? { lookUp(account).key }

    /// The key, or whether it is known to be gone or only couldn't be read this time: see `StoredKey`.
    static func lookUp(_ account: String) -> StoredKey { store.lookUp(account) }

    /// Fails every write, so a test can see what pairing does when a key can't be kept. Only a test copy sets it.
    static var failsWrites: Bool {
        get { memory.writeFails != nil }
        set { memory.writeFails = newValue ? errSecInteractionNotAllowed : nil }
    }

    /// False if the key couldn't be kept. A key already kept under that name is left as it was then.
    static func write(_ data: Data, _ account: String) -> Bool { store.write(data, account) == errSecSuccess }

    /// Why a key is still kept under that name, if one is: see `MigratingKeyStore.gone(_:)`.
    @discardableResult static func delete(_ account: String) -> OSStatus { store.delete(account) }

    /// The names of every key kept, wherever it is.
    static func accounts() -> [String] { store.accounts() }
}

/// The devices paired with this Mac. Their names are in a file; their keys are only ever in the Keychain.
@Observable
final class RemoteDevices {
    private struct Saved: Codable {
        var macID: String
        var devices: [PairedDevice]
    }

    /// What a device whose name couldn't be read is listed as.
    static let unnamed = "Paired device"
    /// A copy of the Mac's id beside the file, so that a file that can't be read doesn't cost the Mac its id, and
    /// every device the means of finding it.
    static let macIDKey = "remoteMacID"

    private(set) var devices: [PairedDevice] = []
    /// A random name for this Mac, so a device finds it again whatever the Mac is called. Nil only when the list
    /// of devices couldn't be read and the id wasn't kept anywhere else: see `startAfresh()`.
    private(set) var macID: String?
    /// What went wrong reading or writing the list, for Settings to say.
    private(set) var problem: String?
    private var url: URL { AppServices.shared.supportDirectory.appendingPathComponent("remote-devices.json") }

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else {
            // Nothing saved yet: a new Mac id, unless an earlier one was kept beside the file that has since gone.
            macID = keptMacID ?? UUID().uuidString.lowercased()
            if FileManager.default.fileExists(atPath: url.path) { unreadable(data: nil) }
            return
        }
        // Each device is read on its own, so one that can't be read costs only itself.
        struct Loose: Decodable {
            var macID: String?
            var devices: [Lossy]?
        }
        struct Lossy: Decodable {
            var device: PairedDevice?
            init(from decoder: Decoder) throws { device = try? PairedDevice(from: decoder) }
        }
        guard let saved = try? JSONDecoder().decode(Loose.self, from: data), let id = saved.macID ?? keptMacID else {
            return unreadable(data: data)
        }
        macID = id
        keep(macID: id)
        let read = (saved.devices ?? []).compactMap(\.device)
        if read.count != saved.devices?.count {
            backUp()
            problem = "Queen Bee couldn't read every paired device from its list. The ones it could read are kept, and a copy of the list is in \(backupURL.lastPathComponent) beside it."
        }
        // A device whose key has gone from the Keychain can't connect, so it isn't listed. One whose key couldn't be
        // read, as when the Keychain is locked or its prompt was turned down, is kept: dropped here, the next save
        // would write it out of the file for good. Its listener waits until the key can be read.
        devices = read.filter { storedKey(for: $0.id).keepsDevice }
    }

    /// The list is there and can't be read. It is copied aside, the devices are found again from their keys,
    /// and the Mac keeps its id if it was kept anywhere, so devices still find it.
    private func unreadable(data: Data?) {
        backUp()
        // The id may still be legible in a file that is otherwise broken.
        let legible = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { text -> String? in
            guard let match = text.firstMatch(of: /"macID"\s*:\s*"([0-9A-Fa-f-]{36})"/) else { return nil }
            return String(match.1).lowercased()
        }
        macID = legible ?? keptMacID
        // Not a device that was removed and whose key couldn't be deleted: it would come back paired.
        devices = DeviceKeys.pairedIDs(in: KeyVault.accounts(), leavingOut: removedIDs).map {
            PairedDevice(id: $0, name: Self.unnamed, added: Date(), canControl: false)
        }
        if macID == nil {
            problem = "Queen Bee couldn't read its list of paired devices, and with it the name your devices find this Mac by. A copy is in \(backupURL.lastPathComponent). Choose Start Afresh to carry on: every device will have to be paired again."
        } else {
            problem = "Queen Bee couldn't read its list of paired devices, so it listed them again from their keys. Their names and “Can control” have been reset. A copy of the old list is in \(backupURL.lastPathComponent)."
            save()
        }
    }

    /// Gives the Mac a new id, so devices can be paired again, after its list and id were lost.
    func startAfresh() {
        macID = UUID().uuidString.lowercased()
        problem = nil
        save()
    }

    private var backupURL: URL { url.deletingLastPathComponent().appendingPathComponent("remote-devices.unreadable.json") }

    /// Keeps a copy of the file as it is, before anything is written over it. An earlier copy is kept as it was.
    private func backUp() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path), !manager.fileExists(atPath: backupURL.path) else { return }
        try? manager.copyItem(at: url, to: backupURL)
    }

    private var keptMacID: String? {
        TestHarness.isEnabled ? nil : UserDefaults.standard.string(forKey: Self.macIDKey)
    }

    private func keep(macID: String) {
        guard !TestHarness.isEnabled, UserDefaults.standard.string(forKey: Self.macIDKey) != macID else { return }
        UserDefaults.standard.set(macID, forKey: Self.macIDKey)
    }

    private static func account(_ id: String) -> String { DeviceKeys.account(id) }

    /// Devices that were removed, kept beside the file so they stay removed if it is lost and the list is made
    /// again from the keys, where a key that couldn't be deleted would otherwise bring one back. A test copy keeps
    /// them in memory.
    static let removedKey = "remoteRemovedDevices"
    private static var removedInMemory: Set<String> = []
    private var removedIDs: Set<String> {
        get { TestHarness.isEnabled ? Self.removedInMemory : Set(UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? []) }
        set {
            if TestHarness.isEnabled { Self.removedInMemory = newValue } else { UserDefaults.standard.set(newValue.sorted(), forKey: Self.removedKey) }
        }
    }
    private static let log = Logger(subsystem: "dev.queenbee.app", category: "remote")

    private func save() {
        // With no id there is nothing a device could find, and what is on the disk is still worth more.
        guard let macID, let data = try? JSONEncoder().encode(Saved(macID: macID, devices: devices)) else { return }
        keep(macID: macID)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            problem = "Queen Bee couldn't save its list of paired devices: \(error.localizedDescription)"
        }
    }

    func key(for id: String) -> Data? { storedKey(for: id).key }
    /// A key of the wrong length is as good as gone: nothing could connect with it.
    func storedKey(for id: String) -> StoredKey { KeyVault.lookUp(Self.account(id)).checked }

    /// Pairs a device, or pairs it again with a new key, and returns that key. Nil if the key couldn't be
    /// kept: nothing has changed then, because a device listed without its key could never connect.
    func add(id: String, name: String) -> Data? {
        let key = LinkSecurity.randomKey()
        guard macID != nil, KeyVault.write(key, Self.account(id)) else { return nil }
        removedIDs.remove(id)
        devices.removeAll { $0.id == id }
        devices.append(PairedDevice(id: id, name: name, added: Date(), canControl: false))
        save()
        return key
    }

    /// Puts a device back as it was before it was paired again. False if its old key couldn't be kept.
    func restore(_ device: PairedDevice, key: Data) -> Bool {
        guard KeyVault.write(key, Self.account(device.id)) else { return false }
        removedIDs.remove(device.id)
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
        removedIDs.insert(id)
        let status = KeyVault.delete(Self.account(id))
        if !MigratingKeyStore.gone(status) {
            // The device is unpaired all the same: it is off the list, nothing listens for it, and it stays off.
            Self.log.error("Couldn't delete the key of removed device \(id, privacy: .public): \(status)")
            problem = "Queen Bee removed the device but couldn't delete its key from your Keychain (\(status)). The device can't connect with it."
        }
        devices.removeAll { $0.id == id }
        save()
    }
}
