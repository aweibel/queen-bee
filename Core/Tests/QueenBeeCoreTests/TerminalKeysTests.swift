import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct TerminalKeysTests {
    @Test func namedKeysSendWhatATerminalSends() {
        #expect(TerminalKeys.bytes(for: .enter) == [0x0D])
        #expect(TerminalKeys.bytes(for: .backspace) == [0x7F])
        #expect(TerminalKeys.bytes(for: .tab) == [0x09])
        #expect(TerminalKeys.bytes(for: .backTab) == Array("\u{1b}[Z".utf8))
        #expect(TerminalKeys.bytes(for: .escape) == [0x1B])
        #expect(TerminalKeys.bytes(for: .up) == Array("\u{1b}[A".utf8))
        #expect(TerminalKeys.bytes(for: .down) == Array("\u{1b}[B".utf8))
        #expect(TerminalKeys.bytes(for: .right) == Array("\u{1b}[C".utf8))
        #expect(TerminalKeys.bytes(for: .left) == Array("\u{1b}[D".utf8))
        // Every key has bytes, and no two share them.
        #expect(Set(TerminalKey.allCases.map(TerminalKeys.bytes(for:))).count == TerminalKey.allCases.count)
    }

    @Test func textIsSentAsUTF8() {
        #expect(TerminalKeys.bytes(for: "y") == [0x79])
        #expect(TerminalKeys.bytes(for: "qb keys") == Array("qb keys".utf8))
        #expect(TerminalKeys.bytes(for: "é") == [0xC3, 0xA9])
        #expect(TerminalKeys.bytes(for: "日本") == [0xE6, 0x97, 0xA5, 0xE6, 0x9C, 0xAC])
        #expect(TerminalKeys.bytes(for: "🐝") == [0xF0, 0x9F, 0x90, 0x9D])
        #expect(TerminalKeys.bytes(for: "") == [])
    }

    @Test func theReturnKeyIsACarriageReturn() {
        #expect(TerminalKeys.bytes(for: "\n") == [0x0D])
        #expect(TerminalKeys.bytes(for: "a\nb") == [0x61, 0x0D, 0x62])
        #expect(TerminalKeys.bytes(for: "a\r\nb") == [0x61, 0x0D, 0x62])
    }

    @Test func controlWithACharacterIsItsControlCode() {
        #expect(TerminalKeys.control("c") == 0x03)
        #expect(TerminalKeys.control("C") == 0x03)
        #expect(TerminalKeys.control("d") == 0x04)
        #expect(TerminalKeys.control("l") == 0x0C)
        #expect(TerminalKeys.control("r") == 0x12)
        #expect(TerminalKeys.control("u") == 0x15)
        #expect(TerminalKeys.control("a") == 0x01)
        #expect(TerminalKeys.control("z") == 0x1A)
        #expect(TerminalKeys.control("[") == 0x1B)
        #expect(TerminalKeys.control("\\") == 0x1C)
        #expect(TerminalKeys.control("]") == 0x1D)
        #expect(TerminalKeys.control("_") == 0x1F)
        #expect(TerminalKeys.control("@") == 0x00)
        #expect(TerminalKeys.control(" ") == 0x00)
        #expect(TerminalKeys.control("?") == 0x7F)
        #expect(TerminalKeys.control("1") == nil)
        #expect(TerminalKeys.control("é") == nil)
        #expect(TerminalKeys.control("🐝") == nil)
    }

    @Test func controlPressedFirstAppliesToTheNextCharacterOnly() {
        var typer = KeyTyper()
        #expect(!typer.isControlHeld)
        #expect(typer.type("c") == [0x63])
        typer.toggleControl()
        #expect(typer.isControlHeld)
        #expect(typer.type("c") == [0x03])
        #expect(!typer.isControlHeld)
        #expect(typer.type("c") == [0x63])

        // Only the first of several characters that arrive together.
        typer.toggleControl()
        #expect(typer.type("uab") == [0x15, 0x61, 0x62])
        #expect(!typer.isControlHeld)
    }

    @Test func controlIsLetGoByAKeyItDoesNothingTo() {
        var typer = KeyTyper()
        typer.toggleControl()
        #expect(typer.type("5") == [0x35])
        #expect(!typer.isControlHeld)

        typer.toggleControl()
        #expect(typer.type("é") == [0xC3, 0xA9])
        #expect(!typer.isControlHeld)

        typer.toggleControl()
        #expect(typer.press(.up) == Array("\u{1b}[A".utf8))
        #expect(!typer.isControlHeld)
    }

    @Test func controlPressedTwiceIsOffAgain() {
        var typer = KeyTyper()
        typer.toggleControl()
        typer.toggleControl()
        #expect(!typer.isControlHeld)
        #expect(typer.type("c") == [0x63])
        // Nothing typed leaves it waiting.
        typer.toggleControl()
        #expect(typer.type("") == [])
        #expect(typer.isControlHeld)
    }

    @Test func controlHeldOnARealKeyboardLeavesTheButtonAlone() {
        var typer = KeyTyper()
        #expect(typer.control("c") == [0x03])
        #expect(typer.control("1") == nil)
        typer.toggleControl()
        #expect(typer.control("d") == [0x04])
        #expect(typer.isControlHeld)
    }

    @Test func keysAreCutIntoMessagesNoLongerThanTheLimit() {
        #expect(TerminalKeys.chunks([]) == [])
        #expect(TerminalKeys.chunks([0x61]) == [Data([0x61])])

        let exactly = [UInt8](repeating: 0x61, count: Remote.keysLimit)
        #expect(TerminalKeys.chunks(exactly) == [Data(exactly)])

        let over = [UInt8](repeating: 0x61, count: Remote.keysLimit * 2 + 5)
        let cut = TerminalKeys.chunks(over)
        #expect(cut.map(\.count) == [Remote.keysLimit, Remote.keysLimit, 5])
        #expect(cut.flatMap { [UInt8]($0) } == over)
        for data in cut { #expect(RemoteCommand.keys(flowID: "f", key: "k", data: data).problem == nil) }
    }

    @Test func aCharacterOfSeveralBytesIsNeverCutInTwo() {
        // Two bytes each, cut at an odd number: every message ends on a whole character.
        let accents = TerminalKeys.bytes(for: String(repeating: "é", count: 10))
        let cut = TerminalKeys.chunks(accents, limit: 5)
        #expect(cut.map(\.count) == [4, 4, 4, 4, 4])
        #expect(cut.flatMap { [UInt8]($0) } == accents)
        for data in cut { #expect(String(data: data, encoding: .utf8) != nil) }

        // Four bytes each, with every cut that could land inside one.
        let bees = TerminalKeys.bytes(for: "a🐝b🐝🐝c")
        for limit in 4 ... 9 {
            let pieces = TerminalKeys.chunks(bees, limit: limit)
            #expect(pieces.flatMap { [UInt8]($0) } == bees)
            #expect(pieces.allSatisfy { $0.count <= limit && String(data: $0, encoding: .utf8) != nil })
        }

        // Text at the real limit.
        let long = TerminalKeys.bytes(for: String(repeating: "日", count: 3000))
        let real = TerminalKeys.chunks(long)
        #expect(real.flatMap { [UInt8]($0) } == long)
        #expect(real.allSatisfy { $0.count <= Remote.keysLimit && String(data: $0, encoding: .utf8) != nil })
    }

    @Test func bytesThatAreNotTextAreStillCutToTheLimit() {
        // Nothing but the later bytes of characters: there is no whole character to keep, so the limit alone decides.
        let odd = [UInt8](repeating: 0x80, count: 10)
        let cut = TerminalKeys.chunks(odd, limit: 4)
        #expect(cut.flatMap { [UInt8]($0) } == odd)
        #expect(cut.allSatisfy { !$0.isEmpty && $0.count <= 4 })
    }
}
