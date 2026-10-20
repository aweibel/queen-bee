import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct TranscriptsTests {
    @Test func aFolderIsNamedAsClaudeCodeNamesIt() {
        #expect(Transcripts.folderName(for: "/Users/ana/my project.v2") == "-Users-ana-my-project-v2")
        // Each UTF-16 unit is one character, so an emoji is two.
        #expect(Transcripts.folderName(for: "/a/é😀") == "-a----")
    }

    @Test func aLongPathMatchesOnItsFirstPartOnly() {
        let long = "/" + String(repeating: "a", count: 250)
        let name = String(Transcripts.folderName(for: long).prefix(200)) + "-k3x9"
        #expect(Transcripts.isFolder(name, for: long))
        #expect(!Transcripts.isFolder(String(Transcripts.folderName(for: long).prefix(200)), for: long))
        #expect(Transcripts.isFolder("-tmp-x", for: "/tmp/x"))
        #expect(!Transcripts.isFolder("-tmp-x-y", for: "/tmp/x"))
    }

    @Test func aTranscriptLeftInAnotherFolderStartsANewConversation() {
        #expect(Transcripts.start(inFolder: true, elsewhere: true) == .resume)
        #expect(Transcripts.start(inFolder: true, elsewhere: false) == .resume)
        #expect(Transcripts.start(inFolder: false, elsewhere: true) == .freshWithNewID)
        #expect(Transcripts.start(inFolder: false, elsewhere: false) == .fresh)
    }

    @Test func summarisingMidTurnLeavesTheSessionAtWork() {
        #expect(SessionState.working.afterSessionStart(source: "compact") == .working)
        #expect(SessionState.needsYou.afterSessionStart(source: "compact") == .needsYou)
        #expect(SessionState.starting.afterSessionStart(source: "compact") == .idle)
        // Asked for with /compact, the session is back at its prompt afterwards.
        #expect(SessionState.working.afterSessionStart(source: "compact", compactedByPerson: true) == .idle)
        for source in ["startup", "resume", "clear", nil] {
            #expect(SessionState.starting.afterSessionStart(source: source) == .idle)
            #expect(SessionState.working.afterSessionStart(source: source) == .idle)
        }
    }
}
