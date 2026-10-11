import Foundation
import QueenBeeCore
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
    private static let keyAccount = "device-key"
    private static var keychainService: String { (Bundle.main.bundleIdentifier ?? "dev.queenbee.mobile") + ".remote" }

    /// This device's id. Made up the first time it is asked for, and from then on whatever the Mac kept it as.
    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

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

    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keyAccount]
    }

    static var key: Data? {
        var found: CFTypeRef?
        let wanted = keyQuery.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(wanted as CFDictionary, &found) == errSecSuccess, let key = found as? Data, key.count == 32 else { return nil }
        return key
    }

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
        return true
    }

    /// "Forget this Mac": the key and the Mac both go. The device keeps its id, so pairing it again replaces
    /// its old entry on the Mac instead of adding a second one.
    static func forget() {
        SecItemDelete(keyQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: macKey)
    }
}
