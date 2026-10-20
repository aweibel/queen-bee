import Foundation

/// How many connections that haven't yet said who they are a listener holds at once: in all, and from any one
/// address. Anybody on the network can open a connection, and each one held costs the Mac a handshake and a
/// wait of up to ten seconds, so one that would go over either is closed the moment it arrives.
public struct LinkGate: Equatable, Sendable {
    public let most: Int
    public let mostFromOne: Int
    private var open: [String: Int] = [:]
    private var total = 0

    /// Far more than a few devices ever open at once, even each reconnecting, and few enough to cost nothing.
    public init(most: Int = 24, mostFromOne: Int = 6) {
        self.most = most
        self.mostFromOne = mostFromOne
    }

    /// Takes one more connection from `address`, or nil when it isn't known. False, and nothing counted, if
    /// that would be one too many.
    public mutating func admit(_ address: String?) -> Bool {
        let key = address ?? ""
        guard total < most, open[key, default: 0] < mostFromOne else { return false }
        total += 1
        open[key, default: 0] += 1
        return true
    }

    /// One connection that was let in has said who it is, or ended.
    public mutating func release(_ address: String?) {
        let key = address ?? ""
        guard let count = open[key] else { return }
        total -= 1
        open[key] = count > 1 ? count - 1 : nil
    }

    public var count: Int { total }
}
