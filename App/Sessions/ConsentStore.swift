import CryptoKit
import Foundation

extension Data {
    /// The SHA-256 digest as lowercase hex.
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

/// What the person has agreed to on this Mac, by card: a Script card's command, or a Start
/// card's schedule. Each is remembered as a hash of what was agreed, so a change to the thing
/// itself, whoever made it, takes the agreement away. Kept in the app's own settings, never in
/// the flow file, so a file can't agree on the person's behalf, and keyed by a hash of the
/// project, flow and card, so no id in a file can be written to look like another's.
struct ConsentStore {
    /// Where remembered agreements of this kind live in the app's settings.
    let key: String

    static let scripts = ConsentStore(key: "allowedScripts")
    static let schedules = ConsentStore(key: "armedSchedules")
    /// Not something agreed to, but the opposite: the Script cards whose command, as it is now, was last
    /// written or brought back from a paired device. Such a command is allowed at this Mac and nowhere else.
    /// Kept the same way, so it outlives the app being quit and no flow file can say otherwise.
    static let scriptsFromDevices = ConsentStore(key: "scriptsFromDevices")

    private func entry(_ scope: String, _ cardID: String) -> String {
        Data((scope + "\u{0}" + cardID).utf8).sha256Hex
    }

    func isGranted(_ what: String, scope: String, cardID: String) -> Bool {
        let granted = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return granted[entry(scope, cardID)] == Data(what.utf8).sha256Hex
    }

    /// Remembers `what` for the card, or forgets the card with nil.
    func grant(_ what: String?, scope: String, cardID: String) {
        var granted = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        granted[entry(scope, cardID)] = what.map { Data($0.utf8).sha256Hex }
        UserDefaults.standard.set(granted, forKey: key)
    }
}
