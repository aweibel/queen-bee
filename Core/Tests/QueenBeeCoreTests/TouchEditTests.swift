import CoreGraphics
import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct TouchEditTests {
    /// A card's targets laid out as the canvas lays them out: a 28-point title, a 16-point grip in the
    /// corner, and one output dot on the right edge beside the title.
    private func targets(_ id: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 240, _ height: CGFloat = 96, ports: [String] = ["out"]) -> TouchEdit.CardTargets {
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let outputs = ports.enumerated().map { index, port in
            TouchEdit.CardTargets.Output(port: port, point: ports.count == 1
                ? CGPoint(x: frame.maxX, y: frame.minY + 14)
                : CGPoint(x: frame.maxX, y: frame.maxY - CGFloat(ports.count - index) * 22 + 11))
        }
        return TouchEdit.CardTargets(id: id, frame: frame, titleHeight: 28, grip: CGRect(x: frame.maxX - 16, y: frame.maxY - 16, width: 16, height: 16), outputs: outputs)
    }

    private func down(_ x: CGFloat, _ y: CGFloat, zoom: CGFloat = 1, _ cards: [TouchEdit.CardTargets], groups: [TouchEdit.GroupTarget] = []) -> TouchEdit.Down {
        TouchEdit.down(at: CGPoint(x: x, y: y), zoom: zoom, cards: cards, groups: groups)
    }

    // MARK: What a finger landed on

    @Test func aTitleBarMovesAndTheInsideOfACardPans() {
        let cards = [targets("a", 100, 100, 480, 300)]
        #expect(down(200, 110, cards) == .move("a"))
        #expect(down(200, 250, cards) == .body("a"))
        #expect(down(50, 50, cards) == .empty)
        // A terminal's own area never moves its card, right up under the title's target.
        #expect(down(200, 100 + 14 + 23, cards) == .body("a"))
    }

    @Test func theGripAndADotWinOverTheTitleBarWhereTheyOverlap() {
        let cards = [targets("a", 100, 100)]
        // On the dot, which sits on the title bar's right end.
        #expect(down(340, 114, cards) == .link(card: "a", port: "out"))
        // Just inside the card, still within the dot's finger's width.
        #expect(down(322, 114, cards) == .link(card: "a", port: "out"))
        // Further along the title bar it is the title bar's.
        #expect(down(300, 114, cards) == .move("a"))
        #expect(down(335, 190, cards) == .resize("a"))
        // Outside the card's corner, within reach of the grip.
        #expect(down(345, 205, cards) == .resize("a"))
    }

    @Test func ofADotAndAGripTheNearerOneIsTaken() {
        // Zoomed out to where handles are first offered, the dot's target and the grip's overlap.
        let cards = [targets("a", 0, 0, 180, 72)]
        #expect(down(182, 16, zoom: 0.5, cards) == .link(card: "a", port: "out"))
        #expect(down(176, 66, zoom: 0.5, cards) == .resize("a"))
        // Between them, nearer the grip's middle than the dot's.
        #expect(down(180, 44, zoom: 0.5, cards) == .resize("a"))
        #expect(down(180, 36, zoom: 0.5, cards) == .link(card: "a", port: "out"))
    }

    @Test func everyTargetIsAFingersWidthOnScreenAtAnyZoom() {
        let cards = [targets("a", 0, 0, 240, 96)]
        for zoom in [0.5, 1, 2, 3] as [CGFloat] {
            let reach = 22 / zoom - 0.5
            // The dot, from each side of its middle.
            #expect(down(240 + reach, 14, zoom: zoom, cards) == .link(card: "a", port: "out"), "zoom \(zoom)")
            #expect(down(240, 14 - reach, zoom: zoom, cards) == .link(card: "a", port: "out"), "zoom \(zoom)")
            // The grip, from its middle.
            #expect(down(232 + reach, 88 + reach, zoom: zoom, cards) == .resize("a"), "zoom \(zoom)")
            // The title bar, above the card and below its own foot.
            #expect(down(100, 14 - reach, zoom: zoom, cards) == .move("a"), "zoom \(zoom)")
            #expect(down(100, 14 + reach, zoom: zoom, cards) == .move("a"), "zoom \(zoom)")
        }
    }

    @Test func belowTheZoomWhereHandlesCanBeHitAnyPartOfACardMovesIt() {
        let cards = [targets("a", 0, 0, 240, 96), targets("b", 400, 0, 240, 96)]
        let zoom: CGFloat = 0.3
        #expect(zoom < TouchEdit.handlesFromZoom)
        #expect(down(120, 14, zoom: zoom, cards) == .move("a"))
        #expect(down(120, 80, zoom: zoom, cards) == .move("a"))
        // Where the grip and the dot are drawn: still the card.
        #expect(down(236, 92, zoom: zoom, cards) == .move("a"))
        #expect(down(238, 14, zoom: zoom, cards) == .move("a"))
        // A card as big as a finger on screen has no reach beyond its own edge.
        #expect(down(300, 40, zoom: zoom, cards) == .empty)
        // One drawn smaller than a finger is still a finger's width.
        #expect(down(120, 96 + 20, zoom: 0.2, cards) == .move("a"))
        #expect(down(120, 96 + 400, zoom: 0.2, cards) == .empty)
        // Between two such cards, the nearer.
        #expect(down(310, 40, zoom: 0.1, cards) == .move("a"))
        #expect(down(350, 40, zoom: 0.1, cards) == .move("b"))
    }

    @Test func theCardOnTopIsTheOneTaken() {
        // b lies over a's right end, covering its dot and its grip.
        let cards = [targets("a", 0, 0, 240, 96), targets("b", 200, -20, 240, 160)]
        #expect(down(240, 30, cards) == .body("b"))
        #expect(down(232, 88, cards) == .body("b"))
        #expect(down(300, -10, cards) == .move("b"))
        // b's own handles are still b's.
        #expect(down(440, 132, cards) == .resize("b"))
        // Clear of b, a's title bar is a's.
        #expect(down(60, 14, cards) == .move("a"))
    }

    @Test func namedOutputsEachStartTheirOwnLink() {
        let cards = [targets("a", 0, 0, 240, 140, ports: ["yes", "no"])]
        #expect(down(240, 140 - 33, zoom: 2, cards) == .link(card: "a", port: "yes"))
        #expect(down(240, 140 - 11, zoom: 2, cards) == .link(card: "a", port: "no"))
        // At 1 their targets overlap, and the nearer dot is taken.
        #expect(down(240, 140 - 24, cards) == .link(card: "a", port: "yes"))
        #expect(down(240, 140 - 20, cards) == .link(card: "a", port: "no"))
    }

    @Test func aGroupIsTakenByItsNameAndACardWinsOverIt() {
        let cards = [targets("a", 100, 100)]
        let groups = [TouchEdit.GroupTarget(id: "g", handle: CGRect(x: 82, y: 58, width: 276, height: 24))]
        #expect(down(150, 70, cards, groups: groups) == .moveGroup("g"))
        // The strip is 24 tall, and a finger's width is 44: ten points either side of it.
        #expect(down(150, 50, cards, groups: groups) == .moveGroup("g"))
        #expect(down(150, 20, cards, groups: groups) == .empty)
        // Where the strip's target and a title bar's meet, the title bar is the card's.
        #expect(down(150, 92, cards, groups: groups) == .move("a"))
    }

    // MARK: Where a drag settles

    @Test func aDraggedCardSettlesOnTheGridAndTakesTheOthersWithIt() {
        let origins = ["a": CGPoint(x: 100, y: 100), "b": CGPoint(x: 500, y: 300)]
        let lead = CGRect(x: 100, y: 100, width: 240, height: 96)
        let moved = TouchEdit.moved(origins, lead: lead, by: CGPoint(x: 31, y: -7), others: [], grid: 24, zoom: 1)
        // 131 settles on 120 and 93 on 96: the lead card moves by 20 and by -4, and so does the other.
        #expect(moved.places == ["a": CGPoint(x: 120, y: 96), "b": CGPoint(x: 520, y: 296)])
        #expect(moved.guides.isEmpty)
    }

    @Test func itLinesUpWithAnotherCardWithinSixPointsOnScreen() {
        let lead = CGRect(x: 0, y: 0, width: 240, height: 96)
        let other = CGRect(x: 403, y: 300, width: 240, height: 96)
        // Its left edge is 5 from the other's.
        var moved = TouchEdit.moved(["a": .zero], lead: lead, by: CGPoint(x: 398, y: 10), others: [other], grid: 24, zoom: 1)
        #expect(moved.places["a"]?.x == 403)
        #expect(moved.guides == [Snapping.Guide(isVertical: true, position: 403, start: 10, end: 396)])
        // Seven away is out of reach at this zoom, and the grid takes it.
        moved = TouchEdit.moved(["a": .zero], lead: lead, by: CGPoint(x: 396, y: 10), others: [other], grid: 24, zoom: 1)
        #expect(moved.places["a"]?.x == 408)
        #expect(moved.guides.isEmpty)
        // Zoomed out to a half, six points on screen are twelve on the canvas.
        moved = TouchEdit.moved(["a": .zero], lead: lead, by: CGPoint(x: 392, y: 10), others: [other], grid: 24, zoom: 0.5)
        #expect(moved.places["a"]?.x == 403)
        // The same as the Mac's own drag works out.
        let mac = Snapping.snap(lead.offsetBy(dx: 392, dy: 10), to: [other], grid: 24, tolerance: 6 / 0.5)
        #expect(moved.places["a"] == mac.origin)
        #expect(moved.guides == mac.guides)
    }

    @Test func aCardIsNeverResizedBelowWhatItsKindAllows() {
        var agent = Card.make(kind: .agent, name: "A", x: 48, y: 48)
        let start = CGSize(width: agent.width, height: agent.height)
        #expect(TouchEdit.resized(agent, from: start, by: CGPoint(x: -1000, y: -1000), grid: 24) == CGSize(width: 320, height: 200))
        // The corner settles on the grid: 48 + 560 + 30 is 638, which settles on 648.
        #expect(TouchEdit.resized(agent, from: start, by: CGPoint(x: 30, y: 5), grid: 24) == CGSize(width: 600, height: 384))
        // A card that isn't on the grid has its corner put there, not its size.
        agent.x = 50
        #expect(TouchEdit.resized(agent, from: start, by: CGPoint(x: 30, y: 0), grid: 24).width == 598)

        let branches = Card.make(kind: .ifElse, name: "If", x: 0, y: 0)
        let least = TouchEdit.resized(branches, from: CGSize(width: 240, height: 120), by: CGPoint(x: -500, y: -500), grid: 24)
        #expect(least == CGSize(width: Card.minimumWidth(for: branches), height: Card.minimumHeight(for: branches)))
        #expect(least == CGSize(width: 180, height: 120))
    }

    @Test func aNewCardGoesToTheMiddleOfTheScreenClearOfTheOthers() {
        // A Script card is 240 by 120. Its title bar's middle is what the Mac is told.
        let alone = TouchEdit.placeForNewCard(.script, centre: CGPoint(x: 600, y: 400), taken: [], titleHeight: 28)
        #expect(alone == CGPoint(x: 600, y: 340 + 14))
        // With a card already there it steps down and right until it is clear.
        let taken = [CGRect(x: 480, y: 340, width: 240, height: 120)]
        let stepped = TouchEdit.placeForNewCard(.script, centre: CGPoint(x: 600, y: 400), taken: taken, titleHeight: 28)
        #expect(stepped == CGPoint(x: 600 + 48 * 3, y: 354 + 48 * 3))
        // Never off the canvas's top or left.
        #expect(TouchEdit.placeForNewCard(.script, centre: .zero, taken: [], titleHeight: 28) == CGPoint(x: 140, y: 34))
    }

    // MARK: The overlay

    private func flow() -> Flow {
        Flow(id: "f", name: "F", cards: [
            Card(id: "a", kind: .start, name: "A", x: 0, y: 0, width: 240, height: 96),
            Card(id: "b", kind: .prompt, name: "B", x: 300, y: 0, width: 240, height: 96),
            Card(id: "c", kind: .end, name: "C", x: 600, y: 0, width: 240, height: 96),
        ], links: [Link(id: "l", from: "a", to: "b")])
    }

    @Test func theOverlayKeepsDraggedCardsUnderTheFingerAndLetsEveryOtherChangeThrough() {
        let overlay = TouchEdit.Overlay(frames: ["b": CGRect(x: 320, y: 48, width: 240, height: 96)])
        var merged = overlay.applied(to: flow())
        #expect(merged.card("b")?.x == 320)
        #expect(merged.card("b")?.y == 48)
        #expect(merged.card("a") == flow().card("a"))

        // The Mac sends a flow in which another card has moved, one has been renamed, a link has been added,
        // and the dragged card is where the last step the Mac heard of put it.
        var fromMac = flow()
        fromMac.cards[0].x = -48
        fromMac.cards[2].name = "Renamed"
        fromMac.cards[1].x = 310
        fromMac.cards[1].name = "B too"
        fromMac.links.append(Link(id: "m", from: "b", to: "c"))
        merged = overlay.applied(to: fromMac)
        #expect(merged.card("a")?.x == -48)
        #expect(merged.card("c")?.name == "Renamed")
        #expect(merged.links.map(\.id) == ["l", "m"])
        // Where it is stays the finger's. Everything else about it is the Mac's.
        #expect(merged.card("b")?.x == 320)
        #expect(merged.card("b")?.name == "B too")
    }

    @Test func theOverlayResizesAndNeverBringsBackACardTheMacDeleted() {
        let overlay = TouchEdit.Overlay(frames: ["b": CGRect(x: 300, y: 0, width: 360, height: 200)])
        #expect(overlay.applied(to: flow()).card("b")?.width == 360)
        #expect(overlay.applied(to: flow()).card("b")?.height == 200)
        var without = flow()
        try? without.removeCard("b")
        #expect(overlay.applied(to: without) == without)
        #expect(overlay.agrees(with: without))
    }

    @Test func theOverlayKnowsWhenTheMacHasCaughtUp() {
        let overlay = TouchEdit.Overlay(frames: ["b": CGRect(x: 320, y: 48, width: 240, height: 96)])
        #expect(!overlay.agrees(with: flow()))
        var caughtUp = flow()
        caughtUp.cards[1].x = 320
        caughtUp.cards[1].y = 48
        #expect(overlay.agrees(with: caughtUp))
    }

    // MARK: Steps

    @Test func stepsLeaveAtMostTwentyTimesASecond() {
        var throttle = TouchEdit.Throttle()
        #expect(throttle.wait(at: 10) == nil)
        // Ten milliseconds on, forty are still to wait.
        let wait = throttle.wait(at: 10.01)
        #expect(wait != nil && abs((wait ?? 0) - 0.04) < 0.0001)
        #expect(throttle.wait(at: 10.049) != nil)
        #expect(throttle.wait(at: 10.05) == nil)
        #expect(throttle.wait(at: 10.06) != nil)

        // A finger that moves 120 times a second for a second sends 20 steps.
        var busy = TouchEdit.Throttle(), sent = 0
        for tick in 0..<120 where busy.wait(at: 100 + Double(tick) / 120) == nil { sent += 1 }
        #expect(sent == 20)
    }

    // MARK: Panning from the edges

    @Test func aDragHeldAtAnEdgePansThatWayFasterTheFurtherItIsPushed() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Begun in the middle, so no edge has an allowance.
        var pan = TouchEdit.EdgePan(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 400, y: 300), in: bounds))
        #expect(pan.step(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 400, y: 300), in: bounds), elapsed: 0.1, zoom: 1) == .zero)
        // Just inside the right edge's zone: the slow speed, 120 points a second.
        let slow = pan.step(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 760.5, y: 300), in: bounds), elapsed: 0.1, zoom: 1)
        #expect(slow.x > 12 && slow.x < 12.1 && slow.y == 0)
        // At the edge, and past it: the fast one.
        #expect(pan.step(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 800, y: 300), in: bounds), elapsed: 0.1, zoom: 1).x == 140)
        #expect(pan.step(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 900, y: 300), in: bounds), elapsed: 0.1, zoom: 1).x == 140)
        // The same speed on screen at any zoom, so twice as far on the canvas at a half.
        #expect(pan.step(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 800, y: 300), in: bounds), elapsed: 0.1, zoom: 0.5).x == 280)
        // Left and up are negative.
        let corner = pan.step(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 0, y: 0), in: bounds), elapsed: 0.1, zoom: 1)
        #expect(corner == CGPoint(x: -140, y: -140))
    }

    @Test func aDragThatStartsBesideAnEdgePansOnlyWhenPushedFurther() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Begun 10 points from the top, as a title bar near the top of the screen is.
        let start = CGPoint(x: 400, y: 10)
        var pan = TouchEdit.EdgePan(depths: TouchEdit.EdgePan.depths(of: start, in: bounds))
        #expect(pan.step(depths: TouchEdit.EdgePan.depths(of: start, in: bounds), elapsed: 0.1, zoom: 1) == .zero)
        // Pushed nearer the edge, it pans.
        #expect(pan.step(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 400, y: 4), in: bounds), elapsed: 0.1, zoom: 1).y < 0)
        // Pulled back out of the zone, the allowance is given up: coming back to where it began now pans.
        _ = pan.step(depths: TouchEdit.EdgePan.depths(of: CGPoint(x: 400, y: 100), in: bounds), elapsed: 0.1, zoom: 1)
        #expect(pan.step(depths: TouchEdit.EdgePan.depths(of: start, in: bounds), elapsed: 0.1, zoom: 1).y < 0)
    }
}
