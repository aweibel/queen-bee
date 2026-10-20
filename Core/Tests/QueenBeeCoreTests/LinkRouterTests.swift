import CoreGraphics
import Testing
@testable import QueenBeeCore

@Suite struct LinkRouterTests {
    let source = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func aLevelForwardLinkIsOneStraightRun() {
        let target = CGRect(x: 400, y: 100, width: 200, height: 100)
        let points = LinkRouter.route(from: CGPoint(x: 300, y: 115), to: CGPoint(x: 400, y: 115), source: source, target: target)
        #expect(points == [CGPoint(x: 300, y: 115), CGPoint(x: 400, y: 115)])
    }

    @Test func aForwardLinkAtAnotherHeightTurnsTwiceBetweenTheCards() {
        let target = CGRect(x: 400, y: 300, width: 200, height: 100)
        let points = LinkRouter.route(from: CGPoint(x: 300, y: 115), to: CGPoint(x: 400, y: 315), source: source, target: target)
        #expect(points.count == 4)
        #expect(points[1].x == points[2].x)
        #expect(points[1].x > 300 && points[1].x < 400)
        #expect(points[1].y == 115 && points[2].y == 315)
    }

    @Test func everyRunIsHorizontalOrVertical() {
        let target = CGRect(x: 0, y: 260, width: 200, height: 100)
        let points = LinkRouter.route(from: CGPoint(x: 300, y: 115), to: CGPoint(x: 0, y: 275), source: source, target: target)
        for (a, b) in zip(points, points.dropFirst()) {
            #expect(a.x == b.x || a.y == b.y)
        }
    }

    @Test func aLinkBackToAnEarlierCardPassesClearOfBothCards() {
        let target = CGRect(x: 0, y: 90, width: 80, height: 100)
        let points = LinkRouter.route(from: CGPoint(x: 300, y: 115), to: CGPoint(x: 0, y: 105), source: source, target: target)
        #expect(points.count == 6)
        let lane = points[2].y
        #expect(lane >= max(source.maxY, target.maxY) + LinkRouter.clearance || lane <= min(source.minY, target.minY) - LinkRouter.clearance)
        #expect(points[1].x > 300)
        #expect(points[4].x < 0)
    }

    @Test func aLoopNearTheTopOfTheCanvasGoesBelow() {
        let high = CGRect(x: 100, y: 10, width: 200, height: 100)
        let target = CGRect(x: 0, y: 10, width: 80, height: 60)
        let points = LinkRouter.route(from: CGPoint(x: 300, y: 25), to: CGPoint(x: 0, y: 25), source: high, target: target)
        #expect(points[2].y > high.maxY)
    }

    @Test func lanesSpreadRoutesApart() {
        let target = CGRect(x: 0, y: 90, width: 80, height: 100)
        let first = LinkRouter.route(from: CGPoint(x: 300, y: 115), to: CGPoint(x: 0, y: 105), source: source, target: target, lane: 0)
        let second = LinkRouter.route(from: CGPoint(x: 300, y: 115), to: CGPoint(x: 0, y: 105), source: source, target: target, lane: 1)
        #expect(first[2].y != second[2].y)
        #expect(first[1].x != second[1].x)
    }

    @Test func theLabelSitsOnTheLongestRun() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 200), CGPoint(x: 30, y: 200)]
        #expect(LinkRouter.labelPoint(of: points) == CGPoint(x: 10, y: 100))
    }

    @Test func aPathIsBuiltForAnyNumberOfPoints() {
        #expect(LinkRouter.path(through: []).isEmpty)
        #expect(!LinkRouter.path(through: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]).isEmpty)
        let bent = LinkRouter.path(through: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)])
        #expect(bent.boundingBox.width > 9 && bent.boundingBox.height > 9)
    }
}

@Suite struct LinkGeometryTests {
    @Test func onlyWhatMovesALinkChangesTheGeometry() throws {
        var flow = Flow(name: "F")
        let a = try flow.addCard(kind: .agent, x: 0, y: 0)
        let b = try flow.addCard(kind: .agent, x: 400, y: 0)
        let before = LinkGeometry(flow)
        var renamed = flow
        renamed.cards[0].name = "Someone else"
        renamed.cards[0].instructions = "Do it differently"
        #expect(LinkGeometry(renamed) == before)
        var moved = flow
        moved.cards[1].x += 20
        #expect(LinkGeometry(moved) != before)
        var linked = flow
        _ = try linked.addLink(from: a.id, to: b.id)
        #expect(LinkGeometry(linked) != before)
    }
}
