import Foundation
import QueenBeeCore

/// What a device does next when the Mac turns it away or the connection is lost.
public enum LinkVerdict: Equatable, Sendable {
    /// The Mac wasn't there or the connection dropped. Look for it and try again.
    case tryAgain
    /// The Mac no longer knows this device. Trying again can't help: the person has to pair it again.
    case mustPairAgain(String)
    /// The two apps are on different versions. The text says which one to update.
    case needsUpdate(String)

    /// Shown when the Mac was there and wouldn't take this device's key.
    public static let keyRefusedText = "This device is no longer paired with your Mac. Pair it again to carry on."

    /// The Mac answered and said no, in `text`. It refuses for two reasons only, and the other one is a version
    /// that doesn't match, so anything that isn't the unpaired message is taken to be that.
    public static func refused(_ text: String) -> LinkVerdict {
        text == Remote.unpairedRefusal ? .mustPairAgain(text) : .needsUpdate(text)
    }

    /// The connection couldn't be made, or ended. Only a key the Mac turned down means pairing again. Nothing
    /// listening, a timeout and a drop all mean the Mac is out of reach for now.
    public static func failed(_ error: Error) -> LinkVerdict {
        (error as? LinkError)?.keyRefused == true ? .mustPairAgain(keyRefusedText) : .tryAgain
    }

    /// How long to leave it before try number `attempt` (the first retry is 0): 1, 2, 4, then 8 seconds each time.
    public static func wait(beforeAttempt attempt: Int) -> TimeInterval {
        TimeInterval(1 << min(max(attempt, 0), 3))
    }
}
