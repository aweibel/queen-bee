import Foundation

/// Text on its way into a terminal as typing.
public enum TerminalText {
    /// `text` with nothing left in it that a terminal would take as a key press or a command to
    /// itself. A message typed into an agent's session was written by another agent, out of
    /// whatever that agent read, and it goes in as a bracketed paste. Left as it came, the bytes
    /// that end a paste could sit inside it, and what followed them would be typed as keys:
    /// Return, or an answer to a permission prompt.
    ///
    /// Escape sequences go whole, so a coloured line reads as its words. Other control
    /// characters are dropped, apart from newline and tab. Every line end becomes a newline.
    public static func typed(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var held: Unicode.Scalar?
        while let scalar = held ?? scalars.next() {
            held = nil
            switch scalar.value {
            case 0x1B:
                // ESC [ starts a sequence that runs to its final byte, a letter or one of @ to ~.
                guard let next = scalars.next() else { break }
                guard next == "[" else { held = next; break }
                while let part = scalars.next() {
                    if (0x40...0x7E).contains(part.value) { break }
                    // Anything that can't be part of a sequence ends it, and is looked at afresh.
                    if !(0x20...0x3F).contains(part.value) { held = part; break }
                }
            case 0x0D:
                out.append("\n")
                if let next = scalars.next(), next != "\n" { held = next }
            case 0x0A, 0x09:
                out.append(scalar)
            case 0x00...0x1F, 0x7F...0x9F:
                break
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }
}
