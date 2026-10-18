import Foundation
import Network
import Security

public struct LinkError: Error, Equatable, CustomStringConvertible {
    public let description: String
    /// True when the other end was there and the two didn't hold the same key. Nothing listening, a timeout
    /// and a dropped connection are all false: the key was never put to the test.
    public let keyRefused: Bool
    public init(_ description: String, keyRefused: Bool = false) { self.description = description; self.keyRefused = keyRefused }
}

/// What looking for a paired device's key in the Keychain found.
public enum StoredKey: Equatable, Sendable {
    case found(Data)
    /// There is no such key: it was deleted, so the device can never connect with it again.
    case missing
    /// The Keychain didn't say, with this status: it was locked, its prompt was turned down, or it couldn't
    /// ask. The key may well be there, and may be read later.
    case unreadable(OSStatus)

    /// What `SecItemCopyMatching` answered, as this.
    public init(status: OSStatus, data: Data?) {
        switch status {
        case errSecSuccess: self = data.map(StoredKey.found) ?? .unreadable(status)
        case errSecItemNotFound: self = .missing
        default: self = .unreadable(status)
        }
    }

    public var key: Data? { if case .found(let key) = self { key } else { nil } }

    /// Whether the device stays paired. Only a key known to have gone takes it off the list: one that couldn't be
    /// read this time is still there, and a device dropped for that would be written out of the list for good.
    public var keepsDevice: Bool { self != .missing }
}

public enum LinkSecurity {
    /// 32 random bytes: a device's key, or a pairing code's secret.
    public static func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // Carrying on would hand out a key of zeros, which anyone could guess.
        precondition(status == errSecSuccess, "Queen Bee couldn't make a random key (SecRandomCopyBytes gave \(status)).")
        return Data(bytes)
    }

    /// TLS over TCP where both ends must hold `key`. Nothing is exchanged with an end that doesn't.
    public static func parameters(key: Data) -> NWParameters {
        precondition(key.count == 32, "A link key is 32 bytes, and this one is \(key.count).")
        let tls = NWProtocolTLS.Options()
        // Only TLS 1.2 has the key-only suite below. Any other version would bring its own suites, which need no key.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("queenbee".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_256_GCM_SHA384))!)
        // Each connection must prove it holds the key. A resumed session skips that proof, so a key that was
        // swapped or withdrawn would still get in.
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        // A device that walks out of range is noticed in seconds, not minutes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// What the Mac shows as a QR code while pairing, and a device scans or has pasted in.
public struct PairingCode: Equatable, Sendable {
    public let secret: Data

    public init(secret: Data = LinkSecurity.randomKey()) { self.secret = secret }

    public var text: String {
        "queenbee-pair:1:" + secret.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init?(text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "queenbee-pair", parts[1] == "1" else { return nil }
        var base64 = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let secret = Data(base64Encoded: base64), secret.count == 32 else { return nil }
        self.secret = secret
    }
}
