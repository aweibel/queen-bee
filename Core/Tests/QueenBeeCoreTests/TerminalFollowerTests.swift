import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct TerminalFollowerTests {
    private func chunk(_ text: String, reset: Bool = false, cols: Int = 80, rows: Int = 24) -> TerminalChunk {
        TerminalChunk(reset: reset, cols: cols, rows: rows, data: Data(text.utf8))
    }

    @Test func aFreshStartClearsAndSizesBeforeItFeeds() {
        var follower = TerminalFollower()
        #expect(!follower.isSized)
        #expect(follower.steps(for: chunk("hello", reset: true)) == [.start(cols: 80, rows: 24), .feed(Data("hello".utf8))])
        #expect(follower.isSized)
        #expect((follower.cols, follower.rows) == (80, 24))
    }

    @Test func whatFollowsOnIsOnlyFed() {
        var follower = TerminalFollower()
        _ = follower.steps(for: chunk("one", reset: true))
        #expect(follower.steps(for: chunk("two")) == [.feed(Data("two".utf8))])
        #expect(follower.steps(for: chunk("three")) == [.feed(Data("three".utf8))])
        #expect((follower.chunks, follower.resets, follower.bytes) == (3, 1, 11))
    }

    @Test func aSecondFreshStartStartsAgainAtItsOwnSize() {
        var follower = TerminalFollower()
        _ = follower.steps(for: chunk("one", reset: true))
        #expect(follower.steps(for: chunk("again", reset: true, cols: 100, rows: 30)) == [.start(cols: 100, rows: 30), .feed(Data("again".utf8))])
        #expect((follower.cols, follower.rows, follower.resets) == (100, 30, 2))
    }

    @Test func aFirstChunkThatDoesNotSayResetStillSizesTheTerminal() {
        var follower = TerminalFollower()
        #expect(follower.steps(for: chunk("late")) == [.start(cols: 80, rows: 24), .feed(Data("late".utf8))])
        #expect(follower.resets == 0)
    }

    @Test func anEmptyFreshStartOnlyClears() {
        var follower = TerminalFollower()
        #expect(follower.steps(for: chunk("", reset: true)) == [.start(cols: 80, rows: 24)])
    }

    @Test func aNewSizeWithoutAFreshStartKeepsTheScreen() {
        var follower = TerminalFollower()
        _ = follower.steps(for: chunk("one", reset: true))
        #expect(follower.steps(for: chunk("two", cols: 90, rows: 24)) == [.resize(cols: 90, rows: 24), .feed(Data("two".utf8))])
        #expect(follower.cols == 90)
    }

    @Test func aSizeThatCannotBeIsNotTaken() {
        var follower = TerminalFollower()
        // Nothing to lay the bytes out on yet.
        #expect(follower.steps(for: chunk("lost", reset: true, cols: 0, rows: 24)) == [])
        #expect(follower.chunks == 0)
        _ = follower.steps(for: chunk("one", reset: true))
        #expect(follower.steps(for: chunk("two", cols: 80, rows: 5000)) == [.feed(Data("two".utf8))])
        #expect(follower.steps(for: chunk("three", reset: true, cols: -1, rows: 24)) == [.start(cols: 80, rows: 24), .feed(Data("three".utf8))])
        #expect((follower.cols, follower.rows) == (80, 24))
    }
}
