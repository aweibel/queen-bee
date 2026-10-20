import Foundation
import Network
import QueenBeeCore

extension Remote {
    /// The port a Mac listens on for devices connecting by its address rather than finding it on the Wi-Fi. Fixed,
    /// so it can be typed into a device once and for all.
    public static let addressPort: UInt16 = 51_720
}

/// Where to reach the Mac without looking for it on the Wi-Fi: its name or address, and the port it listens on
/// for devices connecting by address. Typed into a device's settings, for a Mac on another network, such as one
/// reached over Tailscale.
public struct MacAddress: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = Remote.addressPort) { self.host = host; self.port = port }

    /// "mac.tail1234.ts.net", "100.64.0.7:51720" or "[fd7a::1]:51720", as the person types it. Without a port, the
    /// usual one. Nil when it can't be an address.
    public init?(text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        var port = Remote.addressPort
        if text.hasPrefix("[") {
            // An IPv6 address in brackets, perhaps with a port after them.
            guard let end = text.firstIndex(of: "]") else { return nil }
            let rest = text[text.index(after: end)...]
            if rest.hasPrefix(":") {
                guard let given = UInt16(rest.dropFirst()), given != 0 else { return nil }
                port = given
            } else if !rest.isEmpty {
                return nil
            }
            text = String(text[text.index(after: text.startIndex)..<end])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            // A name or an IPv4 address with a port. An IPv6 address without brackets has more than one colon.
            guard let given = UInt16(text[text.index(after: colon)...]), given != 0 else { return nil }
            port = given
            text = String(text[..<colon])
        }
        guard !text.isEmpty else { return nil }
        self.host = text
        self.port = port
    }

    /// As the person would type it, with the port left out when it is the usual one.
    public var text: String {
        let shown = host.contains(":") ? "[\(host)]" : host
        return port == Remote.addressPort ? shown : "\(shown):\(port)"
    }

    public var endpoint: NWEndpoint? {
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: port), port != 0 else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}
