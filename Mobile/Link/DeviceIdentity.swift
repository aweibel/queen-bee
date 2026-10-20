import Foundation
import QueenBeeCore
import QueenBeeLink
import Security
import UIKit

/// The Mac this device is paired with.
nonisolated struct PairedMac: Codable, Equatable, Sendable {
    var macID: String
    var macName: String
}

/// Who this device is to the Mac, and what it needs to connect again: its id and the Mac's are in the app's
/// settings, and the key is only ever in the Keychain.
enum DeviceIdentity {
    private static let idKey = "deviceID"
    private static let macKey = "pairedMac"
    private static let addressKey = "macAddress"
    private static let goodServiceKey = "goodService"
    private static let keyAccount = "device-key"
    private static var keychainService: String { (Bundle.main.bundleIdentifier ?? "dev.queenbee.mobile") + ".remote" }

    /// This device's id. Made up the first time it is asked for, and from then on whatever the Mac kept it as.
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    /// Made up afresh each time the app starts: the command ids the app gives out only go up while it runs, so
    /// the two together name a command for good. See `RemoteHello.epoch`.
    static let epoch = UUID().uuidString.lowercased()

    /// What the Mac lists this device as.
    static var deviceName: String { UIDevice.current.name }

    static var pairedMac: PairedMac? {
        UserDefaults.standard.data(forKey: macKey).flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
    }

    /// The Mac may have been renamed since pairing. Its id is what finds it; the name is only shown.
    static func rename(_ mac: PairedMac) {
        guard let data = try? JSONEncoder().encode(mac) else { return }
        UserDefaults.standard.set(data, forKey: macKey)
    }

    /// Where to reach the Mac by address, if the person has said.
    static var macAddress: MacAddress? {
        get { UserDefaults.standard.data(forKey: addressKey).flatMap { try? JSONDecoder().decode(MacAddress.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: addressKey)
            } else {
                UserDefaults.standard.removeObject(forKey: addressKey)
            }
        }
    }

    /// The name of the service on the network that the Mac last let this device in by, or "address" when it was
    /// by the Mac's address. Tried first next time: something else on the network may copy the Mac's record.
    static var goodService: String? {
        get { UserDefaults.standard.string(forKey: goodServiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: goodServiceKey) }
    }

    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keyAccount]
    }

    /// The key, or whether it is gone or only couldn't be read just now: the device may be locked, or still
    /// starting up. Only a key that is gone means pairing again.
    static var storedKey: StoredKey {
        var found: CFTypeRef?
        let wanted = keyQuery.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        let status = SecItemCopyMatching(wanted as CFDictionary, &found)
        // A key of the wrong length can never be used, which is as good as gone.
        if status == errSecSuccess, let key = found as? Data, key.count != 32 { return .missing }
        return StoredKey(status: status, data: found as? Data)
    }

    static var key: Data? { storedKey.key }

    /// Keeps what the Mac handed over when it agreed to pair. False if the key couldn't be kept, and then no
    /// Mac is remembered: one remembered without its key could never be connected to.
    static func save(_ grant: PairGrant) -> Bool {
        guard grant.key.count == 32, let mac = try? JSONEncoder().encode(PairedMac(macID: grant.macID, macName: grant.macName)) else { return false }
        // Replaced, not updated, so the new key is kept under the rule below whatever the old one was kept under.
        // The old key is no loss: the Mac stopped taking it the moment it handed out this one.
        SecItemDelete(keyQuery as CFDictionary)
        // Readable once the device has been unlocked after a restart, and never copied to another device or a backup.
        let item = keyQuery.merging([kSecValueData as String: grant.key,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        UserDefaults.standard.set(grant.deviceID, forKey: idKey)
        UserDefaults.standard.set(mac, forKey: macKey)
        goodService = nil
        return true
    }

    /// "Forget this Mac": the key, the Mac and where it was reached all go. The device keeps its id, so pairing it
    /// again replaces its old entry on the Mac instead of adding a second one.
    static func forget() {
        SecItemDelete(keyQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: macKey)
        UserDefaults.standard.removeObject(forKey: goodServiceKey)
        macAddress = nil
    }
}
