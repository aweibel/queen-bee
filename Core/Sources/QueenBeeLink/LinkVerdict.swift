import Foundation
import QueenBeeCore

/// What a device does next when the Mac turns it away or the connection is lost.
public enum LinkVerdict: Equatable, Sendable {
    /// The Mac wasn't there, the connection dropped, or securing it failed. Look for it and try again.
    case tryAgain
    /// The Mac said in words that it no longer knows this device. Trying again can't help: the person has to
    /// pair it again.
    case mustPairAgain(String)
    /// The two apps are on different versions. The text says which one to update.
    case needsUpdate(String)

    /// Shown when this device's own key has gone from its Keychain, as after restoring it from a backup.
    public static let keyRefusedText = "This device is no longer paired with your Mac. Pair it again to carry on."

    /// The Mac answered and said no, in `text`. It refuses for two reasons only, and the other one is a version
    /// that doesn't match, so anything that isn't the unpaired message is taken to be that.
    public static func refused(_ text: String) -> LinkVerdict {
        text == Remote.unpairedRefusal ? .mustPairAgain(text) : .needsUpdate(text)
    }

    /// The connection couldn't be made, or ended. That is never the end: a handshake that failed may have been
    /// cut off by the Mac sleeping or quitting, by Remote being turned off or by the Wi-Fi, or made with
    /// something on the network pretending to be the Mac. See `KeyDoubt` for a key turned down again and again.
    public static func failed(_ error: Error) -> LinkVerdict { .tryAgain }

    /// Whether to say the Mac can't be found, after its listener was found `misses` times running and didn't
    /// answer. Once can be a blip. Twice is a Mac that is asleep, with its name still remembered by the network.
    public static func isOutOfReach(afterMisses misses: Int) -> Bool { misses >= 2 }

    /// How long the Mac stays not found before the device adds that it may have been removed on the Mac. A Mac
    /// that removed a device while it was away has no listener for it and no way to tell it.
    public static let removedHintDelay: TimeInterval = 30

    /// How long to leave it before try number `attempt` (the first retry is 0): 1, 2, 4, then 8 seconds each time.
    /// Once the key is in doubt, half a minute each time: the device keeps trying, slowly.
    public static func wait(beforeAttempt attempt: Int, doubtingKey: Bool = false) -> TimeInterval {
        doubtingKey ? 30 : TimeInterval(1 << min(max(attempt, 0), 3))
    }

    /// How long a connection has to have lasted after the Mac let the device in for the waits to start again from
    /// the shortest. One that ends within seconds every time, as when the two can't read each other's messages,
    /// would otherwise be made again every second for ever, downloading everything each time.
    public static let steadyAfter: TimeInterval = 10

    /// Whether a connection that the Mac let in and that then ended starts the waits again from the shortest.
    public static func resetsWaits(afterConnectedFor seconds: TimeInterval) -> Bool { seconds >= steadyAfter }
}

/// Counts the times running that the Mac's listener was there and turned this device's key down. Once is not
/// enough to say so: a handshake cut off part-way, or something on the network copying the Mac's name, fails in
/// the same way. Only after `refusalsBeforeDoubt` in a row does the device say it can't connect, and it carries
/// on trying, slowly, with pairing again offered beside it rather than in its place.
public struct KeyDoubt: Equatable, Sendable {
    public static let refusalsBeforeDoubt = 3
    public private(set) var refusals = 0

    public init() {}

    /// How one try ended: let in, or the error it failed with. Anything but a refusal of the key starts the count
    /// again: the Mac was not there to judge it, or it judged it good.
    public mutating func note(_ error: Error?) {
        switch error {
        case let error as LinkError where error.keyRefused: refusals += 1
        // Given up on from here, which says nothing either way.
        case is CancellationError: break
        default: refusals = 0
        }
    }

    /// The Mac seems not to take this device's key any more.
    public var doubtsKey: Bool { refusals >= Self.refusalsBeforeDoubt }
}
