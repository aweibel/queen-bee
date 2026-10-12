import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct FieldEditTests {
    private func field(_ mac: String = "Writer") -> FieldEdit<String> { FieldEdit(mac: mac) }

    // MARK: Following the Mac

    @Test func aFieldNobodyIsWritingInFollowsTheMac() {
        var f = field()
        #expect(f.shown == "Writer" && f.state == .untouched && f.isIdle)
        f.macHas("Author")
        #expect(f.shown == "Author" && f.state == .untouched && f.isIdle && !f.isBeingEdited)
    }

    @Test func aFieldWithTheKeyboardInItIsNotOverwrittenEvenBeforeAnythingIsWritten() {
        var f = field()
        f.setFocus(true)
        f.macHas("Author")
        #expect(f.shown == "Writer" && f.isBeingEdited && f.mac == "Author")
        // Left without a word written: it follows the Mac again, and there is nothing to send.
        f.setFocus(false)
        #expect(f.shown == "Author" && f.send() == nil && f.isIdle)
    }

    @Test func whatIsWrittenIsNotOverwrittenByTheMacWhileItIsUnsent() {
        var f = field()
        f.setFocus(true)
        f.write("Writer of notes")
        #expect(f.state == .edited && f.shown == "Writer of notes" && f.needsSending)
        f.macHas("Author")
        #expect(f.shown == "Writer of notes" && f.state == .edited)
        // Still so once the keyboard has left, until it has been sent.
        f.setFocus(false)
        f.macHas("Scribe")
        #expect(f.shown == "Writer of notes" && f.isBeingEdited && !f.isIdle)
    }

    @Test func writingBackWhatTheMacHasLeavesNothingToSend() {
        var f = field()
        f.write("Writer!")
        f.write("Writer")
        #expect(f.state == .untouched && f.draft == nil && f.send() == nil && f.isIdle)
    }

    @Test func theMacComingToWhatWasWrittenLeavesNothingToSend() {
        var f = field()
        f.write("Author")
        f.macHas("Author")
        #expect(f.state == .untouched && f.draft == nil && f.send() == nil && f.shown == "Author")
    }

    // MARK: Sending

    @Test func sendingSendsWhatWasWrittenWhateverTheMacHasByThen() {
        var f = field()
        f.write("Mine")
        f.macHas("Theirs")
        #expect(f.send() == "Mine" && f.state == .sending)
        // Nothing is sent twice while one is on its way.
        #expect(f.send() == nil)
    }

    @Test func whatTheMacTookStaysOnShowUntilItsOwnCopyArrives() {
        var f = field()
        f.write("Author")
        _ = f.send()
        f.answered(nil)
        // The answer comes before the flow: the field must not flick back to the old name between them.
        #expect(f.state == .untouched && f.shown == "Author" && f.draft == nil && !f.isIdle)
        // The Mac tidied what it was sent. Its copy is the truth.
        f.macHas("Author.")
        #expect(f.shown == "Author." && f.isIdle)
    }

    @Test func whenTheMacsCopyArrivesBeforeItsAnswerNothingIsLeftOver() {
        var f = field()
        f.write("Author")
        _ = f.send()
        f.macHas("Author")
        #expect(f.state == .sending && f.shown == "Author")
        f.answered(nil)
        #expect(f.state == .untouched && f.shown == "Author" && f.isIdle)
    }

    @Test func aFieldStillBeingWrittenInKeepsItsTextWhenTheMacTakesAnEarlierSend() {
        var f = field("")
        f.setFocus(true)
        f.write("Keep it warm.")
        #expect(f.send() == "Keep it warm.")
        f.write("Keep it warm. And short.")
        f.answered(nil)
        #expect(f.state == .edited && f.shown == "Keep it warm. And short." && f.needsSending)
        f.macHas("Keep it warm.")
        #expect(f.shown == "Keep it warm. And short.")
        #expect(f.send() == "Keep it warm. And short.")
        f.answered(nil)
        // Taken, with the keyboard still in it: it goes on showing what was written.
        #expect(f.state == .untouched && f.shown == "Keep it warm. And short." && f.hasFocus)
    }

    // MARK: Refusals

    @Test func aRefusalKeepsWhatWasWrittenWithTheMacsWordsBesideIt() {
        var f = field()
        f.write("Style guide")
        _ = f.send()
        f.answered("Another card is already called \"Style guide\"")
        #expect(f.state == .refused("Another card is already called \"Style guide\"") && f.shown == "Style guide" && f.draft == "Style guide")
        // A change from the Mac doesn't take it away either.
        f.macHas("Author")
        #expect(f.shown == "Style guide" && f.state == .refused("Another card is already called \"Style guide\""))
        // Writing again puts the words away, and it can be sent again.
        f.write("Style guide 2")
        #expect(f.state == .edited && f.send() == "Style guide 2")
    }

    @Test func aRefusedFieldCanBeSentAgainAsItIs() {
        var f = field()
        f.write("Style guide")
        _ = f.send()
        f.answered("Not now.")
        #expect(f.send() == "Style guide" && f.state == .sending)
    }

    @Test func whatCouldNotGoBecauseTheMacIsAwayIsKeptAsNotSaved() {
        var f = field()
        f.setFocus(true)
        f.write("Draft kept")
        _ = f.send()
        f.answered("Not connected to your Mac right now.", unreachable: true)
        f.setFocus(false)
        #expect(f.state == .unsaved && f.shown == "Draft kept" && !f.isIdle)
        // Shown again later, the Mac has moved on, and it is still what was written.
        f.macHas("Author")
        #expect(f.shown == "Draft kept" && f.state == .unsaved)
        #expect(f.send() == "Draft kept")
        f.answered(nil)
        #expect(f.state == .untouched && f.shown == "Draft kept")
    }

    @Test func anAnswerToSomethingSinceRewrittenIsNotShownAgainstTheNewText() {
        var f = field()
        f.write("Bad name")
        _ = f.send()
        f.write("Better name")
        f.answered("That name is taken.")
        #expect(f.state == .edited && f.shown == "Better name")
    }

    @Test func anAnswerNobodyIsWaitingForChangesNothing() {
        var f = field()
        f.write("Author")
        f.answered("Late.")
        #expect(f.state == .edited && f.shown == "Author")
    }

    @Test func discardingGoesBackToTheMac() {
        var f = field()
        f.write("Author")
        _ = f.send()
        f.answered("No.")
        f.discard()
        #expect(f.state == .untouched && f.shown == "Writer" && f.isIdle)
    }

    // MARK: Other kinds of value

    @Test func aChoiceOrANumberIsSentAtOnceAndKeptWhenRefused() {
        var f = FieldEdit(mac: 3)
        f.write(51)
        #expect(f.send() == 51)
        f.answered("A link's limit is from 1 to 50.")
        #expect(f.shown == 51 && f.state == .refused("A link's limit is from 1 to 50."))
        f.write(3)
        #expect(f.state == .untouched && f.isIdle)
    }
}
