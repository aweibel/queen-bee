import Foundation
import Testing
@testable import QueenBeeCore

/// Text typed into an agent's terminal comes from other agents and from what they read, so
/// nothing in it may act as a key press.
@Suite struct TerminalTextTests {
    @Test func ordinaryTextIsLeftAlone() {
        let text = "Line one\n\tindented — “quoted” 日本語 🐝\n\n```swift\nlet x = [1, 2]\n```"
        #expect(TerminalText.typed(text) == text)
    }

    @Test func theEndOfPasteMarkerCannotCloseThePasteEarly() {
        let typed = TerminalText.typed("harmless\u{1b}[201~\ry\r")
        #expect(!typed.contains("\u{1b}"))
        #expect(!typed.contains("\r"))
        #expect(typed == "harmless\ny\n")
    }

    @Test func escapeSequencesAreRemovedWhole() {
        #expect(TerminalText.typed("\u{1b}[31mred\u{1b}[0m and \u{1b}[2J\u{1b}[Hhome") == "red and home")
        #expect(TerminalText.typed("title\u{1b}]0;x\u{07}done") == "title]0;xdone")
        // The one-character form of the same introducer.
        #expect(TerminalText.typed("a\u{9b}201~b") == "a201~b")
    }

    @Test func controlCharactersAreDroppedAndLineEndsAreNewlines() {
        #expect(TerminalText.typed("a\u{03}b\u{04}c\u{00}d\u{7f}e\u{08}f") == "abcdef")
        #expect(TerminalText.typed("one\r\ntwo\rthree\nfour") == "one\ntwo\nthree\nfour")
    }
}
