import Foundation
import Security

/// One place keys can be kept, by account name: a keychain, or memory in a test.
public protocol KeyStore {
    func lookUp(_ account: String) -> StoredKey
    /// `errSecSuccess`, or why the key couldn't be kept. A key already kept under that name is replaced.
    func write(_ data: Data, _ account: String) -> OSStatus
    /// `errSecSuccess` or `errSecItemNotFound` when no key is kept under that name any more, or why it couldn't be deleted.
    @discardableResult func delete(_ account: String) -> OSStatus
    /// The names of every key kept here. Empty when they can't be listed.
    func accounts() -> [String]
}

/// Keys kept in `modern`, with any an earlier version kept in `legacy` moved over the first time each is read:
/// written to `modern`, read back from it, and only then deleted from `legacy`. When `modern` can't be used at
/// all, as in a copy of the app built without the entitlement it needs, keys stay in `legacy`.
///
/// No step here can lose a key: a key is never deleted from one place until it has been read back from the
/// other, and a key `modern` couldn't say anything about is looked for in `legacy` too.
public struct MigratingKeyStore: KeyStore {
    public let modern: any KeyStore
    public let legacy: any KeyStore

    public init(modern: any KeyStore, legacy: any KeyStore) {
        self.modern = modern
        self.legacy = legacy
    }

    public func lookUp(_ account: String) -> StoredKey {
        switch modern.lookUp(account) {
        case .found(let key):
            return .found(key)
        case .missing:
            let old = legacy.lookUp(account)
            if case .found(let key) = old, modern.write(key, account) == errSecSuccess, modern.lookUp(account) == .found(key) {
                legacy.delete(account)
            }
            return old
        case .unreadable(let status):
            // Locked, or not usable at all. The key may be in either place, and isn't known to be gone from either.
            let old = legacy.lookUp(account)
            if case .found = old { return old }
            return status == errSecMissingEntitlement ? old : .unreadable(status)
        }
    }

    public func write(_ data: Data, _ account: String) -> OSStatus {
        let status = modern.write(data, account)
        guard status == errSecSuccess else {
            // `modern` is read first, so an older key left there would be found in place of the new one kept in
            // `legacy`. The new key is kept in `legacy` before the older one goes, so a failure on the way never
            // leaves no key at all; if the older one can't be seen to have gone, the write fails and it still works.
            let held = modern.lookUp(account)
            if case .unreadable(let why) = held, why != errSecMissingEntitlement { return status }
            let kept = legacy.write(data, account)
            guard kept == errSecSuccess else { return kept }
            guard case .found = held else { return kept }
            modern.delete(account)
            if case .found = modern.lookUp(account) {
                legacy.delete(account)
                return status
            }
            return kept
        }
        // An older copy of the key would otherwise be found again if `modern` ever couldn't be read.
        legacy.delete(account)
        return status
    }

    /// Deleted from both places. The first that couldn't be deleted says why; a place that can't be used at all
    /// holds nothing to delete.
    @discardableResult public func delete(_ account: String) -> OSStatus {
        let statuses = [modern.delete(account), legacy.delete(account)]
        return statuses.first { !Self.gone($0) } ?? errSecSuccess
    }

    /// Whether a delete that answered `status` leaves no key behind.
    public static func gone(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement
    }

    public func accounts() -> [String] { Array(Set(modern.accounts() + legacy.accounts())).sorted() }
}

/// Keys in memory, for tests and for a test copy of the app.
public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    /// What `lookUp` answers instead of looking, and what `write` and `delete` fail with, when set.
    public var lookUpFails: OSStatus?
    public var writeFails: OSStatus?
    public var deleteFails: OSStatus?

    public init(_ keys: [String: Data] = [:]) { self.keys = keys }

    public func lookUp(_ account: String) -> StoredKey {
        if let lookUpFails { return .unreadable(lookUpFails) }
        return lock.withLock { keys[account] }.map(StoredKey.found) ?? .missing
    }

    public func write(_ data: Data, _ account: String) -> OSStatus {
        if let writeFails { return writeFails }
        lock.withLock { keys[account] = data }
        return errSecSuccess
    }

    @discardableResult public func delete(_ account: String) -> OSStatus {
        if let deleteFails { return deleteFails }
        return lock.withLock { keys.removeValue(forKey: account) } == nil ? errSecItemNotFound : errSecSuccess
    }

    public func accounts() -> [String] { lock.withLock { Array(keys.keys) }.sorted() }

    public var stored: [String: Data] { lock.withLock { keys } }
}

/// How the Mac names each paired device's key: `device-` and the device's id.
public enum DeviceKeys {
    public static let prefix = "device-"

    public static func account(_ id: String) -> String { prefix + id }

    /// The ids of the devices whose keys are among `accounts`, less those in `removed`: devices that were unpaired
    /// and whose key couldn't be deleted, which would otherwise come back when the list is made again from the keys.
    public static func pairedIDs(in accounts: [String], leavingOut removed: Set<String>) -> [String] {
        accounts.compactMap { account in
            guard account.hasPrefix(prefix) else { return nil }
            let id = String(account.dropFirst(prefix.count))
            return removed.contains(id) ? nil : id
        }
    }
}
