import Foundation

/// A key that isn't a letter: one a device has its own button for, beside the keyboard.
public enum TerminalKey: String, CaseIterable, Sendable {
    case enter, backspace, tab, backTab, escape, up, down, left, right
}

/// The bytes a key press sends to the program in a terminal. A device builds them here, from what its own
/// keyboard and buttons say was pressed. It never takes them from a terminal emulator, whose output also
/// carries that emulator's answers to the program's questions.
public enum TerminalKeys {
    private static let escape: UInt8 = 0x1B

    /// The bytes of a named key.
    ///
    /// The arrows are the ordinary sequences. A program can ask its terminal for the other set
    /// ("application cursor keys"), and whether it has is not followed here: Claude Code takes these.
    public static func bytes(for key: TerminalKey) -> [UInt8] {
        switch key {
        case .enter: [0x0D]
        case .backspace: [0x7F]
        case .tab: [0x09]
        case .backTab: [escape, 0x5B, 0x5A]
        case .escape: [escape]
        case .up: [escape, 0x5B, 0x41]
        case .down: [escape, 0x5B, 0x42]
        case .right: [escape, 0x5B, 0x43]
        case .left: [escape, 0x5B, 0x44]
        }
    }

    /// Typed text, as UTF-8. The Return key arrives as a new line, and a terminal sends a carriage return for it.
    public static func bytes(for text: String) -> [UInt8] {
        Array(text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r").utf8)
    }

    /// What Ctrl with a character sends: Ctrl-C is 3, Ctrl-U is 21. Nil for a character Ctrl does nothing to.
    public static func control(_ character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61 ... 0x7A: return ascii - 0x60  // a to z
        case 0x40 ... 0x5F: return ascii - 0x40  // @, A to Z, [ \ ] ^ _
        case 0x20: return 0x00
        case 0x3F: return 0x7F
        default: return nil
        }
    }

    /// Cuts key presses into messages no longer than `limit` bytes, in order. A character of more than one
    /// byte is kept whole, so each message is text by itself.
    public static func chunks(_ bytes: [UInt8], limit: Int = Remote.keysLimit) -> [Data] {
        var all: [Data] = []
        var rest = bytes[...]
        while !rest.isEmpty {
            let cut = whole(rest, limit: limit)
            all.append(Data(rest.prefix(cut)))
            rest = rest.dropFirst(cut)
        }
        return all
    }

    /// How many of the first bytes to take: as many as fit, less any that begin a character whose end doesn't fit.
    private static func whole(_ bytes: ArraySlice<UInt8>, limit: Int) -> Int {
        guard bytes.count > limit else { return bytes.count }
        var cut = max(limit, 1)
        // The bytes after a character's first all look like 10xxxxxx. A character is four bytes at most.
        var back = 0
        while back < 3, cut - back > 1, bytes[bytes.startIndex + cut - back] & 0xC0 == 0x80 { back += 1 }
        if bytes[bytes.startIndex + cut - back] & 0xC0 != 0x80 { cut -= back }
        return cut
    }
}

/// Turns what a person presses into bytes, with a Ctrl that is pressed first and applies to the next key,
/// as it has to on a keyboard with no key to hold down.
public struct KeyTyper: Equatable, Sendable {
    /// Ctrl has been pressed and is waiting for its letter.
    public private(set) var isControlHeld = false

    public init() {}

    /// The Ctrl button: on, or off again if it was pressed by mistake.
    public mutating func toggleControl() { isControlHeld.toggle() }

    /// Lets Ctrl go without a key: the terminal it was pressed for has been closed, or another opened.
    public mutating func releaseControl() { isControlHeld = false }

    /// Typed text. With Ctrl waiting, its first character is sent as Ctrl with that character, and Ctrl is let go.
    /// A character Ctrl does nothing to is sent as itself.
    public mutating func type(_ text: String) -> [UInt8] {
        guard isControlHeld, let first = text.first else { return TerminalKeys.bytes(for: text) }
        isControlHeld = false
        let rest = TerminalKeys.bytes(for: String(text.dropFirst()))
        if let code = TerminalKeys.control(first) { return [code] + rest }
        return TerminalKeys.bytes(for: String(first)) + rest
    }

    /// A named key. Ctrl changes none of these, so it is let go and the key is sent as it is.
    public mutating func press(_ key: TerminalKey) -> [UInt8] {
        isControlHeld = false
        return TerminalKeys.bytes(for: key)
    }

    /// Ctrl held down with a character on a real keyboard, which doesn't touch the Ctrl button's state.
    /// Nil for a character Ctrl does nothing to.
    public func control(_ character: Character) -> [UInt8]? {
        TerminalKeys.control(character).map { [$0] }
    }
}
