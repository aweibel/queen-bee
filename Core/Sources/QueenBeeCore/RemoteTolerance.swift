import Foundation

// A device reads what a newer Mac sends as far as it can, rather than not at all. A Mac and a device on the same
// `Remote.version` can still differ in small ways, such as a kind of card one of them has and the other hasn't,
// and one value the device doesn't know must not cost it the whole message, and with it the connection.

extension CodingUserInfoKey {
    /// Set on the decoder for what a device reads from the Mac once reading it strictly has failed.
    static let remoteTolerant = CodingUserInfoKey(rawValue: "dev.queenbee.remoteTolerant")!
}

/// A kind of value that is sent as one of a few words, and that a device given a word it doesn't know reads as
/// `unknownFallback`. Read strictly, as from a flow's file, a word it doesn't know is still an error.
protocol TolerantWireEnum: RawRepresentable, Decodable where RawValue == String {
    static var unknownFallback: Self { get }
}

extension TolerantWireEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = Self(rawValue: raw) {
            self = known
        } else if decoder.userInfo[.remoteTolerant] as? Bool == true {
            self = Self.unknownFallback
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown value \"\(raw)\""))
        }
    }
}

// A card of a kind the device doesn't know is shown as a note: see `Remote.read(fromMac:)`.
extension CardKind: TolerantWireEnum { static var unknownFallback: CardKind { .note } }
extension SessionState: TolerantWireEnum { static var unknownFallback: SessionState { .idle } }
extension FlowActivity: TolerantWireEnum { static var unknownFallback: FlowActivity { .quiet } }
extension RunRecord.Outcome: TolerantWireEnum { static var unknownFallback: RunRecord.Outcome { .stopped } }
extension RemoteBrowserState.Status: TolerantWireEnum { static var unknownFallback: RemoteBrowserState.Status { .idle } }
extension CheckKind: TolerantWireEnum { static var unknownFallback: CheckKind { .judge } }
extension Trigger.Kind: TolerantWireEnum { static var unknownFallback: Trigger.Kind { .interval } }

/// What a device made of one message from the Mac.
public enum MacReading: Equatable, Sendable {
    case message(HostMessage)
    /// A kind of message this app doesn't know, from a newer Mac. It is passed over.
    case unknown
}

extension Remote {
    /// What a card of a kind this app doesn't know says on a device.
    public static let unknownCardText = "Update Queen Bee on this device to see this card."

    /// What a device shows when the Mac sent something it can't read at all.
    public static let unreadableText = "Your Mac sent something this version of Queen Bee can't read. Update Queen Bee on this device and on your Mac, so both are on the newest version."

    /// Reads one message from the Mac. Read strictly first, which nearly always works. If that fails, it is read
    /// again forgivingly: a card of a kind this app doesn't know becomes a note saying to update the app, with
    /// `Card.unknownKind` set, and any other word it doesn't know, such as a session state, becomes the plainest
    /// one. A message of a kind it doesn't know at all is `.unknown`. Throws only for a message of a kind it knows
    /// that it still can't read, which means the two apps don't agree on what that message is.
    public static func read(fromMac data: Data) throws -> MacReading {
        do {
            return .message(try decode(HostMessage.self, from: data))
        } catch {
            guard let json = try? JSONSerialization.jsonObject(with: data) else { throw error }
            if let object = json as? [String: Any], object.count == 1, let name = object.keys.first, !HostMessage.caseNames.contains(name) {
                return .unknown
            }
            let decoder = JSONDecoder()
            decoder.userInfo[.remoteTolerant] = true
            guard let rewritten = try? JSONSerialization.data(withJSONObject: placeholdingCards(json)),
                  let message = try? decoder.decode(HostMessage.self, from: rewritten) else { throw error }
            return .message(message)
        }
    }

    /// The JSON with each card of a kind this app doesn't know made into a note that says so.
    static func placeholdingCards(_ json: Any) -> Any {
        if let array = json as? [Any] { return array.map(placeholdingCards) }
        guard var object = json as? [String: Any] else { return json }
        for (key, value) in object { object[key] = placeholdingCards(value) }
        let cardKeys = ["id", "name", "x", "y", "width", "height"]
        if let kind = object["kind"] as? String, CardKind(rawValue: kind) == nil, cardKeys.allSatisfy({ object[$0] != nil }) {
            object["kind"] = CardKind.note.rawValue
            object["text"] = unknownCardText
            object["unknownKind"] = kind
        }
        return object
    }
}

extension HostMessage {
    /// The name each kind of message goes by in its JSON. A test checks it against every kind.
    public static let caseNames: Set<String> = [
        "welcome", "refused", "library", "opened", "flow", "run", "edit", "log", "messages", "history", "historyChanged",
        "terminal", "answer", "control", "browserPage", "browserFrame", "browserCopied",
    ]
}
