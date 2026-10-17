import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct MutationsTests {
    @Test func defaultNamesCountUp() throws {
        var flow = Flow(name: "F")
        #expect(try flow.addCard(kind: .agent).name == "Agent")
        #expect(try flow.addCard(kind: .agent).name == "Agent 2")
        #expect(try flow.addCard(kind: .agent).name == "Agent 3")
        #expect(try flow.addCard(kind: .ifElse).name == "If / Else")
        #expect(flow.uniqueName("agent") == "agent 4")
        #expect(flow.uniqueName("Writer") == "Writer")
    }

    @Test func cardsResolveByIDThenByNameIgnoringCase() throws {
        var flow = Flow(name: "F")
        let writer = try flow.addCard(kind: .agent, name: "Writer")
        #expect(flow.resolveCard(writer.id) == writer)
        #expect(flow.resolveCard("writer") == writer)
        #expect(flow.resolveCard(" WRITER ") == writer)
        #expect(flow.resolveCard("Nobody") == nil)
    }

    @Test func namesMustBeUniqueAndNotEmpty() throws {
        var flow = Flow(name: "F")
        try flow.addCard(kind: .agent, name: "Writer")
        #expect(throws: FlowError.self) { try flow.addCard(kind: .agent, name: "writer") }
        #expect(throws: FlowError.self) { try flow.addCard(kind: .agent, name: "   ") }
        let other = try flow.addCard(kind: .agent, name: "Reviewer")
        var rename = CardPatch()
        rename.name = "WRITER"
        #expect(throws: FlowError.self) { try flow.updateCard(other.id, patch: rename) }
        // A card may keep its own name, in any case.
        rename.name = "REVIEWER"
        #expect(try flow.updateCard(other.id, patch: rename).name == "REVIEWER")
        #expect(flow.cards.count == 2)
    }

    @Test func aNewCardGoesRightOfTheRightMostCard() throws {
        var flow = Flow(name: "F")
        let first = try flow.addCard(kind: .start)
        #expect(first.x == 80 && first.y == 80)
        let agent = try flow.addCard(kind: .agent, x: 500, y: 300)
        #expect(agent.x == 500 && agent.y == 300)
        let next = try flow.addCard(kind: .end)
        #expect(next.x == agent.x + agent.width + 60)
        #expect(next.y == 300)
    }

    @Test func addCardAppliesThePatch() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.command = "Write a haiku"
        #expect(try flow.addCard(kind: .start, patch: patch).command == "Write a haiku")
        patch = CardPatch()
        patch.branches = ["bug", "feature", "question"]
        let sw = try flow.addCard(kind: .switchCard, patch: patch)
        #expect(ports(of: sw) == ["bug", "feature", "question", "other"])
        #expect(sw.height >= Card.minimumHeight(for: sw))
    }

    @Test func turningTheBrowserOnDoublesAnAgentsWidthAndOffHalvesIt() throws {
        var flow = Flow(name: "F")
        let agent = try flow.addCard(kind: .agent, name: "Writer")
        #expect(agent.browser == nil && agent.width == 560)
        var patch = CardPatch()
        patch.browser = true
        let on = try flow.updateCard("Writer", patch: patch)
        #expect(on.browser == true && on.width == 1120)
        // Saying it again changes nothing.
        #expect(try flow.updateCard("Writer", patch: patch).width == 1120)
        patch.browser = false
        let off = try flow.updateCard("Writer", patch: patch)
        #expect(off.browser == nil && off.width == 560)
        #expect(try flow.updateCard("Writer", patch: patch).width == 560)
    }

    @Test func aBrowserCardIsNeverTooNarrowForBothHalves() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.browser = true
        patch.width = 200
        let made = try flow.addCard(kind: .agent, name: "Writer", patch: patch)
        #expect(made.browser == true && made.width == 640)
        // A width given with the switch is the width the card gets.
        patch.width = 900
        #expect(try flow.updateCard("Writer", patch: patch).width == 900)
        patch = CardPatch()
        patch.browser = false
        patch.width = 900
        #expect(try flow.updateCard("Writer", patch: patch).width == 900)
    }

    @Test func onlyAnAgentCanHaveABrowser() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.browser = true
        let note = try flow.addCard(kind: .note, name: "N", patch: patch)
        #expect(note.browser == nil && note.width == 240)
    }

    @Test func theBrowserSettingSurvivesSavingAndAnOldFileHasItOff() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.browser = true
        _ = try flow.addCard(kind: .agent, name: "Writer", patch: patch)
        let data = try JSONEncoder().encode(flow)
        #expect(try JSONDecoder().decode(Flow.self, from: data).cards[0].browser == true)
        let old = try JSONDecoder().decode(Card.self, from: Data(#"{"id":"a","kind":"agent","name":"A","x":0,"y":0,"width":560,"height":380}"#.utf8))
        #expect(old.browser == nil)
    }

    @Test func emptyAgentSettingsClearToNil() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.model = "opus"; patch.effort = "high"; patch.permissionMode = "plan"; patch.cwd = "/tmp/x"
        patch.instructions = "Be brief"
        let agent = try flow.addCard(kind: .agent, name: "Writer", patch: patch)
        #expect(agent.model == "opus" && agent.effort == "high" && agent.permissionMode == "plan" && agent.cwd == "/tmp/x")
        patch = CardPatch()
        patch.model = ""; patch.effort = ""; patch.permissionMode = ""; patch.cwd = ""
        let cleared = try flow.updateCard("Writer", patch: patch)
        #expect(cleared.model == nil && cleared.effort == nil && cleared.permissionMode == nil && cleared.cwd == nil)
        #expect(cleared.instructions == "Be brief")
    }

    @Test func sizesClampToTheMinimum() throws {
        var flow = Flow(name: "F")
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .ifElse, name: "Check")
        var tiny = CardPatch()
        tiny.width = 10; tiny.height = 10
        let agent = try flow.updateCard("Writer", patch: tiny)
        #expect(agent.width == 320 && agent.height == 200)
        let check = try flow.updateCard("Check", patch: tiny)
        #expect(check.width == 180)
        #expect(check.height == Card.minimumHeight(for: check))
    }

    @Test func growingASwitchGrowsItsHeight() throws {
        var flow = Flow(name: "F")
        let sw = try flow.addCard(kind: .switchCard, name: "Triage")
        var patch = CardPatch()
        patch.branches = ["a", "b", "c", "d", "e", "f"]
        let grown = try flow.updateCard(sw.id, patch: patch)
        #expect(grown.height == Card.minimumHeight(for: grown))
        #expect(grown.height > sw.height)
    }

    @Test func removingACardRemovesItsLinks() throws {
        var flow = try sample()
        try flow.removeCard("Writer")
        #expect(flow.resolveCard("Writer") == nil)
        #expect(flow.links.isEmpty)
        #expect(throws: FlowError.notFound("No card called \"Writer\"")) { try flow.removeCard("Writer") }
    }

    @Test func linksDefaultToTheFirstPortAndThreePasses() throws {
        var flow = Flow(name: "F")
        let check = try flow.addCard(kind: .ifElse, name: "Check")
        let writer = try flow.addCard(kind: .agent, name: "Writer")
        let link = try flow.addLink(from: "check", to: "writer")
        #expect(link.from == check.id && link.to == writer.id)
        #expect(link.port == "yes")
        #expect(link.maxPasses == 3)
        #expect(try flow.addLink(from: check.id, port: "No", to: writer.id, maxPasses: 500).port == "no")
        #expect(flow.links.last?.maxPasses == 50)
        try flow.updateLink(link.id, maxPasses: 0)
        #expect(flow.links.first?.maxPasses == 1)
        try flow.updateLink(link.id, maxPasses: 7)
        #expect(flow.links.first?.maxPasses == 7)
    }

    @Test func badLinksAreRefusedWithAReason() throws {
        var flow = try sample()
        let start = try #require(flow.resolveCard("Start"))
        let writer = try #require(flow.resolveCard("Writer"))
        let reviewer = try #require(flow.resolveCard("Reviewer"))
        let note = try flow.addCard(kind: .note, name: "Memo")
        let end = try flow.addCard(kind: .end, name: "Done")

        #expect(flow.linkProblem(from: writer.id, port: "out", to: end.id) == nil)
        #expect(flow.linkProblem(from: writer.id, port: "out", to: writer.id) != nil)
        #expect(flow.linkProblem(from: writer.id, port: "yes", to: end.id) != nil)
        #expect(flow.linkProblem(from: writer.id, port: "out", to: start.id) != nil)
        #expect(flow.linkProblem(from: writer.id, port: "out", to: note.id) != nil)
        #expect(flow.linkProblem(from: end.id, port: "out", to: writer.id) != nil)
        #expect(flow.linkProblem(from: writer.id, port: "out", to: reviewer.id) != nil)   // already linked
        #expect(flow.linkProblem(from: "nope", port: "out", to: reviewer.id) != nil)

        let before = flow.links
        #expect(throws: FlowError.self) { try flow.addLink(from: "Writer", to: "Writer") }
        #expect(throws: FlowError.self) { try flow.addLink(from: "Writer", to: "Reviewer") }
        #expect(throws: FlowError.self) { try flow.addLink(from: "Writer", port: "maybe", to: "Done") }
        #expect(throws: FlowError.notFound("No card called \"Ghost\"")) { try flow.addLink(from: "Ghost", to: "Done") }
        #expect(flow.links == before)
    }

    @Test func changingBranchesDropsLinksFromBranchesThatAreGone() throws {
        var flow = Flow(name: "F")
        var patch = CardPatch()
        patch.branches = ["bug", "feature"]
        try flow.addCard(kind: .switchCard, name: "Triage", patch: patch)
        try flow.addCard(kind: .agent, name: "Fixer")
        try flow.addCard(kind: .agent, name: "Builder")
        try flow.addCard(kind: .agent, name: "Helper")
        try flow.addLink(from: "Triage", port: "bug", to: "Fixer")
        try flow.addLink(from: "Triage", port: "feature", to: "Builder")
        try flow.addLink(from: "Triage", port: "other", to: "Helper")
        try flow.addLink(from: "Fixer", to: "Helper")

        patch.branches = ["bug", "question"]
        try flow.updateCard("Triage", patch: patch)
        #expect(flow.links.map(\.port) == ["bug", "other", "out"])
    }

    @Test func removingAndUpdatingAMissingLinkFails() throws {
        var flow = try sample()
        let id = try #require(flow.links.first?.id)
        try flow.removeLink(id)
        #expect(flow.links.count == 1)
        #expect(throws: FlowError.self) { try flow.removeLink(id) }
        #expect(throws: FlowError.self) { try flow.updateLink(id, maxPasses: 2) }
    }

    @Test func errorsDescribeThemselvesWithTheirMessage() {
        #expect(FlowError.notFound("No card called \"X\"").description == "No card called \"X\"")
        #expect("\(FlowError.invalid("A card needs a name"))" == "A card needs a name")
    }

    /// Start → Writer → Reviewer.
    private func sample() throws -> Flow {
        var flow = Flow(name: "Review")
        try flow.addCard(kind: .start, name: "Start")
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addCard(kind: .agent, name: "Reviewer")
        try flow.addLink(from: "Start", to: "Writer")
        try flow.addLink(from: "Writer", to: "Reviewer")
        return flow
    }

    @Test func aCardAskedToStayClearIsMovedPastWhatItWouldCover() throws {
        var flow = Flow(name: "Clear")
        let writer = try flow.addCard(kind: .agent, name: "Writer", x: 560, y: 120)
        // 320 points along is still inside the 560-wide agent card.
        let reviewer = try flow.addCard(kind: .agent, name: "Reviewer", x: 880, y: 120, clearOfOthers: true)
        #expect(reviewer.x == writer.x + writer.width + 60)
        let check = try flow.addCard(kind: .ifElse, name: "Check", x: 1200, y: 120, clearOfOthers: true)
        #expect(check.x == reviewer.x + reviewer.width + 60)
    }

    @Test func aCardWithRoomStaysWhereItWasPut() throws {
        var flow = Flow(name: "Room")
        try flow.addCard(kind: .agent, name: "Writer", x: 560, y: 120)
        let below = try flow.addCard(kind: .note, name: "Note", x: 560, y: 700, clearOfOthers: true)
        #expect(below.x == 560 && below.y == 700)
    }

    @Test func withoutBeingAskedACardMayOverlap() throws {
        var flow = Flow(name: "Overlap")
        try flow.addCard(kind: .agent, name: "Writer", x: 560, y: 120)
        let dropped = try flow.addCard(kind: .note, name: "Note", x: 600, y: 150)
        #expect(dropped.x == 600)
    }

    @Test func aModeThatSkipsPermissionChecksIsRefused() throws {
        var flow = Flow(name: "Demo")
        let agent = try flow.addCard(kind: .agent, name: "Writer")
        for mode in ["bypassPermissions", "dontAsk", "--dangerously-skip-permissions"] {
            var patch = CardPatch()
            patch.permissionMode = mode
            #expect(throws: FlowError.self) { try flow.updateCard(agent.id, patch: patch) }
        }
        #expect(flow.card(agent.id)?.permissionMode == nil)
    }

    @Test func anEndCardCannotSaveIntoAProtectedFolder() throws {
        var flow = Flow(name: "Demo")
        let end = try flow.addCard(kind: .end, name: "Done")
        var patch = CardPatch()
        patch.saveTo = ".git/config"
        #expect(throws: FlowError.self) { try flow.updateCard(end.id, patch: patch) }
        #expect(throws: FlowError.self) { try flow.addCard(kind: .end, name: "Other", patch: patch) }
        patch.saveTo = "output/answer.md"
        try flow.updateCard(end.id, patch: patch)
        #expect(flow.card(end.id)?.saveTo == "output/answer.md")
    }
}
