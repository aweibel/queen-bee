import Foundation

/// One key, as Chrome's remote control wants it described.
public struct BrowserKey: Equatable, Sendable {
    /// The key's name as web pages see it, such as "Enter" or "a".
    public var key: String
    /// The physical key, such as "Enter" or "KeyA". Empty when it isn't known.
    public var code: String
    /// The Windows key number that web pages still read as `keyCode`.
    public var keyCode: Int
    /// What the key types, if anything.
    public var text: String?

    public init(key: String, code: String, keyCode: Int, text: String? = nil) {
        self.key = key; self.code = code; self.keyCode = keyCode; self.text = text
    }

    private static let named: [(names: [String], key: BrowserKey)] = [
        (["Enter", "Return"], BrowserKey(key: "Enter", code: "Enter", keyCode: 13, text: "\r")),
        (["Tab"], BrowserKey(key: "Tab", code: "Tab", keyCode: 9)),
        (["Escape", "Esc"], BrowserKey(key: "Escape", code: "Escape", keyCode: 27)),
        (["Backspace"], BrowserKey(key: "Backspace", code: "Backspace", keyCode: 8)),
        (["Delete"], BrowserKey(key: "Delete", code: "Delete", keyCode: 46)),
        (["Space"], BrowserKey(key: " ", code: "Space", keyCode: 32, text: " ")),
        (["ArrowUp", "Up"], BrowserKey(key: "ArrowUp", code: "ArrowUp", keyCode: 38)),
        (["ArrowDown", "Down"], BrowserKey(key: "ArrowDown", code: "ArrowDown", keyCode: 40)),
        (["ArrowLeft", "Left"], BrowserKey(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37)),
        (["ArrowRight", "Right"], BrowserKey(key: "ArrowRight", code: "ArrowRight", keyCode: 39)),
        (["Home"], BrowserKey(key: "Home", code: "Home", keyCode: 36)),
        (["End"], BrowserKey(key: "End", code: "End", keyCode: 35)),
        (["PageUp"], BrowserKey(key: "PageUp", code: "PageUp", keyCode: 33)),
        (["PageDown"], BrowserKey(key: "PageDown", code: "PageDown", keyCode: 34)),
    ]

    /// The names `named` takes, for telling an agent what it may ask for.
    public static let names: [String] = named.map { $0.names[0] }

    /// The key called `name`, ignoring case, or the key that types `name` when it is one character.
    public static func named(_ name: String) -> BrowserKey? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = named.first(where: { $0.names.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }) { return found.key }
        // A lone space is a key too, and trimming would lose it.
        if name == " " { return named.first { $0.names[0] == "Space" }?.key }
        guard wanted.count == 1, let character = wanted.first else { return nil }
        return typing(character)
    }

    /// The key that types one character.
    public static func typing(_ character: Character) -> BrowserKey {
        let text = String(character)
        guard let ascii = character.asciiValue else { return BrowserKey(key: text, code: "", keyCode: 0, text: text) }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            let upper = text.uppercased()
            return BrowserKey(key: text, code: "Key\(upper)", keyCode: Int(upper.unicodeScalars.first!.value), text: text)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return BrowserKey(key: text, code: "Digit\(text)", keyCode: Int(ascii), text: text)
        case UInt8(ascii: " "):
            return BrowserKey(key: " ", code: "Space", keyCode: 32, text: " ")
        default:
            return BrowserKey(key: text, code: "", keyCode: 0, text: text)
        }
    }
}
