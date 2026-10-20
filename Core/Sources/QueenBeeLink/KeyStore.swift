import Foundation
import Security

/// One place keys can be kept, by account name: a keychain, or memory in a test.
public protocol KeyStore {
    func lookUp(_ account: String) -> StoredKey
    /// `errSecSuccess`, or why the key couldn't be kept. A key already kept under that name is replaced.
    func write(_ data: Data, _ account: String) -> OSStatus
    func delete(_ account: String)
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
        guard status == errSecSuccess else { return legacy.write(data, account) }
        // An older copy of the key would otherwise be found again if `modern` ever couldn't be read.
        legacy.delete(account)
        return status
    }

    public func delete(_ account: String) {
        modern.delete(account)
        legacy.delete(account)
    }

    public func accounts() -> [String] { Array(Set(modern.accounts() + legacy.accounts())).sorted() }
}

/// Keys in memory, for tests and for a test copy of the app.
public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    /// What `lookUp` answers instead of looking, and what `write` fails with, when set.
    public var lookUpFails: OSStatus?
    public var writeFails: OSStatus?

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

    public func delete(_ account: String) { lock.withLock { keys[account] = nil } }

    public func accounts() -> [String] { lock.withLock { Array(keys.keys) }.sorted() }

    public var stored: [String: Data] { lock.withLock { keys } }
}
