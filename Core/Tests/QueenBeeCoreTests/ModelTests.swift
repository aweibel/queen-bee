import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct ModelTests {
    @Test func portsFollowTheCardKind() {
        #expect(ports(of: .make(kind: .agent, name: "A", x: 0, y: 0)) == ["out"])
        #expect(ports(of: .make(kind: .ifElse, name: "If", x: 0, y: 0)) == ["yes", "no"])
        #expect(ports(of: .make(kind: .loop, name: "Loop", x: 0, y: 0)) == ["done", "again", "gave-up"])
        #expect(ports(of: .make(kind: .forEach, name: "Each", x: 0, y: 0)) == ["each", "done"])
        #expect(ports(of: .make(kind: .end, name: "End", x: 0, y: 0)).isEmpty)
        var sw = Card.make(kind: .switchCard, name: "Switch", x: 0, y: 0)
        sw.branches = ["bug", "feature"]
        #expect(ports(of: sw) == ["bug", "feature", "other"])
    }

    @Test func aFlowSurvivesEncodingAndDecoding() throws {
        var flow = Flow(name: "Review")
        flow.cards = [.make(kind: .start, name: "Start", x: 10, y: 20), .make(kind: .agent, name: "Writer", x: 300, y: 20)]
        flow.links = [Link(from: flow.cards[0].id, to: flow.cards[1].id)]
        let data = try JSONEncoder().encode(flow)
        #expect(try JSONDecoder().decode(Flow.self, from: data) == flow)
    }

    @Test func startAndNoteTakeNoInput() {
        #expect(!acceptsInput(.make(kind: .start, name: "Start", x: 0, y: 0)))
        #expect(!acceptsInput(.make(kind: .note, name: "Note", x: 0, y: 0)))
        #expect(acceptsInput(.make(kind: .agent, name: "A", x: 0, y: 0)))
    }
}
