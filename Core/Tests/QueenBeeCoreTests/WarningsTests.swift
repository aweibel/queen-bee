import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct WarningsTests {
    @Test func aWellWiredFlowHasNoWarnings() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.command = "Write it"
        try flow.addCard(kind: .start, name: "Start", patch: patch)
        try flow.addCard(kind: .agent, name: "Writer")
        patch = CardPatch()
        patch.check = .contains; patch.value = "APPROVED"
        try flow.addCard(kind: .ifElse, name: "Approved?", patch: patch)
        try flow.addCard(kind: .end, name: "Done")
        try flow.addCard(kind: .note, name: "Memo")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "Approved?")
        try flow.addLink(from: "Approved?", port: "yes", to: "Done")
        try flow.addLink(from: "Approved?", port: "no", to: "Writer")
        #expect(warnings(for: flow).isEmpty)
    }

    @Test func aStartNeedsALinkAndACommand() throws {
        var flow = Flow(name: "F")
        let start = try flow.addCard(kind: .start, name: "Start")
        try flow.addCard(kind: .agent, name: "Writer")
        #expect(warnings(for: flow) == [start.id: "Link it to an agent"])
        try flow.addLink(from: "Start", to: "Writer")
        #expect(warnings(for: flow) == [start.id: "Write the command"])
    }

    @Test func anIfNeedsBothSidesAndACondition() throws {
        var flow = Flow(name: "F")
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .agent, name: "Reviewer")
        let check = try flow.addCard(kind: .ifElse, name: "Check")
        try flow.addLink(from: "Writer", to: "Check")
        #expect(warnings(for: flow)[check.id] == "Nothing on Yes")
        try flow.addLink(from: "Check", port: "yes", to: "Reviewer")
        #expect(warnings(for: flow)[check.id] == "Nothing on No")
        try flow.addLink(from: "Check", port: "no", to: "Writer")
        #expect(warnings(for: flow)[check.id] == "Set its condition")
        var patch = CardPatch()
        patch.value = "The draft is approved"
        try flow.updateCard("Check", patch: patch)
        #expect(warnings(for: flow)[check.id] == nil)
    }

    @Test func aLoopNeedsAgainAndACondition() throws {
        var flow = Flow(name: "F")
        try flow.addCard(kind: .agent, name: "Writer")
        let loop = try flow.addCard(kind: .loop, name: "Polish")
        try flow.addLink(from: "Writer", to: "Polish")
        #expect(warnings(for: flow)[loop.id] == "Nothing on Again")
        try flow.addLink(from: "Polish", port: "again", to: "Writer")
        #expect(warnings(for: flow)[loop.id] == "Set its condition")
    }

    @Test func aLoopNeedsSomethingOnDone() throws {
        var flow = Flow(name: "F")
        try flow.addCard(kind: .agent, name: "Writer")
        var patch = CardPatch()
        patch.value = "It is finished"
        let loop = try flow.addCard(kind: .loop, name: "Polish", patch: patch)
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Writer", to: "Polish")
        try flow.addLink(from: "Polish", port: "again", to: "Writer")
        #expect(warnings(for: flow)[loop.id] == "Nothing on Done")
        try flow.addLink(from: "Polish", port: "done", to: "End")
        #expect(warnings(for: flow)[loop.id] == nil)
    }

    /// Start → Writer → Check; Yes → A → Both; No → B → Both; Both → End.
    private func andAcrossAnIf() throws -> Flow {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.command = "Go"
        try flow.addCard(kind: .start, name: "Start", patch: patch)
        patch = CardPatch()
        patch.check = .contains; patch.value = "yes"
        try flow.addCard(kind: .ifElse, name: "Check", patch: patch)
        for name in ["Writer", "A", "B"] { try flow.addCard(kind: .agent, name: name) }
        try flow.addCard(kind: .and, name: "Both")
        try flow.addCard(kind: .end, name: "End")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "Check")
        try flow.addLink(from: "Check", port: "yes", to: "A")
        try flow.addLink(from: "Check", port: "no", to: "B")
        try flow.addLink(from: "A", to: "Both")
        try flow.addLink(from: "B", to: "Both")
        try flow.addLink(from: "Both", to: "End")
        return flow
    }

    @Test func anAndFedFromDifferentOutputsOfOneIfCanNeverFire() throws {
        let flow = try andAcrossAnIf()
        let both = try #require(flow.resolveCard("Both"))
        #expect(warnings(for: flow) == [both.id: "Its inputs are on different sides of Check"])
    }

    @Test func anAndAcrossAnIfIsFineWhenOneInputCanComeAnotherWay() throws {
        var flow = try andAcrossAnIf()
        try flow.addLink(from: "Start", to: "B")
        #expect(warnings(for: flow).isEmpty)
    }

    @Test func anAndAcrossAnIfInALoopIsFine() throws {
        // Round the loop, the If can go one way and then the other, so the And can hear from both.
        var flow = try andAcrossAnIf()
        try flow.addLink(from: "B", to: "Writer")
        #expect(warnings(for: flow).isEmpty)
    }

    @Test func aSwitchNeedsBranches() throws {
        var flow = Flow(name: "F")
        try flow.addCard(kind: .agent, name: "Writer")
        var patch = CardPatch()
        patch.branches = []
        let sw = try flow.addCard(kind: .switchCard, name: "Triage", patch: patch)
        try flow.addLink(from: "Writer", to: "Triage")
        #expect(warnings(for: flow)[sw.id] == "Add a branch")
    }

    @Test func anAndNeedsTwoDifferentSources() throws {
        var flow = Flow(name: "F")
        try flow.addCard(kind: .agent, name: "A")
        try flow.addCard(kind: .agent, name: "B")
        try flow.addCard(kind: .ifElse, name: "Check")
        let join = try flow.addCard(kind: .and, name: "Join")
        #expect(warnings(for: flow)[join.id] == "Link in 2 or more cards")
        // Two links from the same card are still one source.
        try flow.addLink(from: "Check", port: "yes", to: "Join")
        try flow.addLink(from: "Check", port: "no", to: "Join")
        #expect(warnings(for: flow)[join.id] == "Link in 2 or more cards")
        try flow.addLink(from: "A", to: "Join")
        #expect(warnings(for: flow)[join.id] == nil)
    }

    @Test func logicCardsNeedSomethingLinkedIn() throws {
        var flow = Flow(name: "F")
        let end = try flow.addCard(kind: .end, name: "Done")
        let or = try flow.addCard(kind: .or, name: "First")
        let agent = try flow.addCard(kind: .agent, name: "Writer")
        let note = try flow.addCard(kind: .note, name: "Memo")
        let found = warnings(for: flow)
        #expect(found[end.id] == "Nothing is linked to it")
        #expect(found[or.id] == "Nothing is linked to it")
        #expect(found[agent.id] == nil)
        #expect(found[note.id] == nil)
    }

    @Test func logicCardsInACircleWithNoAgentWarn() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.template = "Again: {{message}}"
        let agent = try flow.addCard(kind: .agent, name: "Writer")
        let rewrite = try flow.addCard(kind: .prompt, name: "Rewrite", patch: patch)
        let first = try flow.addCard(kind: .or, name: "First")
        let end = try flow.addCard(kind: .end, name: "Done")
        try flow.addLink(from: "Writer", to: "Rewrite")
        try flow.addLink(from: "Rewrite", to: "First")
        try flow.addLink(from: "First", to: "Rewrite")
        try flow.addLink(from: "First", to: "Done")
        let found = warnings(for: flow)
        #expect(found[rewrite.id] == "Goes round with no agent")
        #expect(found[first.id] == "Goes round with no agent")
        #expect(found[end.id] == nil)
        #expect(found[agent.id] == nil)
    }

    @Test func aCircleThroughAnAgentIsFine() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.template = "Fix this: {{message}}"
        try flow.addCard(kind: .agent, name: "Writer")
        let rewrite = try flow.addCard(kind: .prompt, name: "Rewrite", patch: patch)
        try flow.addLink(from: "Writer", to: "Rewrite")
        try flow.addLink(from: "Rewrite", to: "Writer")
        #expect(warnings(for: flow)[rewrite.id] == nil)
    }

    @Test func anEndCardThatWouldSaveIntoAProtectedFolderWarns() throws {
        var flow = Flow(name: "F")
        try flow.addCard(kind: .agent, name: "Writer")
        let end = try flow.addCard(kind: .end, name: "Done")
        try flow.addLink(from: "Writer", to: "Done")
        // A flow file can arrive with a path the app would have refused.
        let index = try #require(flow.cards.firstIndex { $0.id == end.id })
        flow.cards[index].saveTo = ".claude/settings.json"
        #expect(warnings(for: flow)[end.id] == "Can't save there")
    }
}
