import CoreGraphics
import Foundation

/// The parts of editing a flow by touch that need no screen: what a finger landed on, where a dragged card
/// settles, how often the Mac is told, and how what is under the finger is laid over what the Mac last sent.
/// The iPad and iPhone app's canvas calls these, and the tests call them without one.
public enum TouchEdit {
    /// The least width and height of anything a finger is meant to hit, in points on screen.
    public static let target: CGFloat = 44
    /// From this zoom up, a card offers its corner grip and its output dots, and is moved by its title bar.
    /// Below it a card is too small on screen for those to be told apart under a finger, so a drag anywhere
    /// on it moves it. At this zoom the smallest card, 180 by 72, is 90 by 36 on screen.
    public static let handlesFromZoom: CGFloat = 0.5
    /// How many steps of a drag are sent to the Mac in a second, at most.
    public static let stepsPerSecond = 20.0
    /// How near a card being dragged has to come to another card's edge or middle to line up with it, in
    /// points on screen. The Mac's own reach.
    public static let snapReach: CGFloat = 6

    // MARK: What a finger landed on

    /// Where one card can be taken hold of, in the canvas's own points.
    public struct CardTargets: Equatable, Sendable {
        public var id: String
        public var frame: CGRect
        public var titleHeight: CGFloat
        /// The corner it is resized by.
        public var grip: CGRect
        /// The dots a link is dragged out of: each output's name and the dot's middle.
        public var outputs: [Output]

        public struct Output: Equatable, Sendable {
            public var port: String
            public var point: CGPoint
            public init(port: String, point: CGPoint) { self.port = port; self.point = point }
        }

        public init(id: String, frame: CGRect, titleHeight: CGFloat, grip: CGRect, outputs: [Output]) {
            self.id = id; self.frame = frame; self.titleHeight = titleHeight; self.grip = grip; self.outputs = outputs
        }
    }

    /// Where a group can be taken hold of: its name strip, or the whole of its one card when folded.
    public struct GroupTarget: Equatable, Sendable {
        public var id: String
        public var handle: CGRect
        public init(id: String, handle: CGRect) { self.id = id; self.handle = handle }
    }

    /// What a drag that starts at a point is for.
    public enum Down: Equatable, Sendable {
        /// Bare canvas: the canvas pans, or a box is drawn when cards are being selected.
        case empty
        /// The inside of a card, under its title. Nothing is moved from there: the canvas pans.
        case body(String)
        case move(String)
        case moveGroup(String)
        case resize(String)
        case link(card: String, port: String)
    }

    /// How big a dot's own target is before it is made a finger's width: the dot and the ring round it.
    public static let dotSize: CGFloat = 16

    /// What a finger that comes down at `point` has taken hold of. `cards` are the cards on show, the one
    /// drawn last at the end. Every target is at least `target` points across on screen whatever the zoom.
    /// Where two overlap, a dot or a grip wins over a title bar, and of two dots or grips the nearer one.
    public static func down(at point: CGPoint, zoom: CGFloat, cards: [CardTargets], groups: [GroupTarget] = []) -> Down {
        let least = target / max(zoom, 0.01)
        /// `rect`, made at least a finger's width on screen each way, about its middle.
        func widened(_ rect: CGRect) -> CGRect {
            rect.insetBy(dx: min(0, (rect.width - least) / 2), dy: min(0, (rect.height - least) / 2))
        }
        func gap(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
        }
        func fromMiddle(_ rect: CGRect) -> CGFloat { hypot(rect.midX - point.x, rect.midY - point.y) }
        // The card the finger is squarely on. What is under it can't be seen, so it can't be taken.
        let on = cards.lastIndex { $0.frame.contains(point) }

        if zoom >= handlesFromZoom {
            var best: (down: Down, distance: CGFloat)?
            for (index, card) in cards.enumerated() where on.map({ index >= $0 }) ?? true {
                for output in card.outputs {
                    let dot = CGRect(x: output.point.x - dotSize / 2, y: output.point.y - dotSize / 2, width: dotSize, height: dotSize)
                    guard widened(dot).contains(point) else { continue }
                    let distance = fromMiddle(dot)
                    if distance <= best?.distance ?? .infinity { best = (.link(card: card.id, port: output.port), distance) }
                }
                if widened(card.grip).contains(point) {
                    let distance = fromMiddle(card.grip)
                    if distance <= best?.distance ?? .infinity { best = (.resize(card.id), distance) }
                }
            }
            if let best { return best.down }

            func title(_ card: CardTargets) -> CGRect {
                CGRect(x: card.frame.minX, y: card.frame.minY, width: card.frame.width, height: min(card.titleHeight, card.frame.height))
            }
            if let on {
                return widened(title(cards[on])).contains(point) ? .move(cards[on].id) : .body(cards[on].id)
            }
            var nearest: (id: String, distance: CGFloat)?
            for card in cards where widened(title(card)).contains(point) {
                let distance = gap(title(card))
                if distance <= nearest?.distance ?? .infinity { nearest = (card.id, distance) }
            }
            if let nearest { return .move(nearest.id) }
        } else {
            if let on { return .move(cards[on].id) }
            var nearest: (id: String, distance: CGFloat)?
            for card in cards where widened(card.frame).contains(point) {
                let distance = gap(card.frame)
                if distance <= nearest?.distance ?? .infinity { nearest = (card.id, distance) }
            }
            if let nearest { return .move(nearest.id) }
        }

        var nearest: (id: String, distance: CGFloat)?
        for group in groups where widened(group.handle).contains(point) {
            let distance = gap(group.handle)
            if distance < nearest?.distance ?? .infinity { nearest = (group.id, distance) }
        }
        return nearest.map { .moveGroup($0.id) } ?? .empty
    }

    // MARK: Where a drag settles

    /// Where each card a drag carries is now: its origin plus how far the finger has gone, settled against
    /// the other cards and the grid by where the card under the finger lands. The Mac's own drag, with its
    /// reach of six points on screen whatever the zoom.
    /// - Parameter lead: the card under the finger, as it was when the drag began.
    /// - Parameter others: the cards on show that aren't being dragged.
    public static func moved(_ origins: [String: CGPoint], lead: CGRect, by travel: CGPoint, others: [CGRect], grid: CGFloat,
                             zoom: CGFloat) -> (places: [String: CGPoint], guides: [Snapping.Guide]) {
        let moving = lead.offsetBy(dx: travel.x, dy: travel.y)
        let settled = Snapping.snap(moving, to: others, grid: grid, tolerance: snapReach / max(zoom, 0.01))
        let dx = settled.origin.x - lead.minX, dy = settled.origin.y - lead.minY
        return (origins.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }, settled.guides)
    }

    /// How big a card is with its corner dragged `travel` from where it was `start` big. The corner settles
    /// on the grid, and the card is never smaller than its kind allows, as on the Mac.
    public static func resized(_ card: Card, from start: CGSize, by travel: CGPoint, grid: CGFloat) -> CGSize {
        var width = start.width + travel.x, height = start.height + travel.y
        if grid > 0 {
            width = ((card.x + width) / grid).rounded() * grid - card.x
            height = ((card.y + height) / grid).rounded() * grid - card.y
        }
        return CGSize(width: max(width, Card.minimumWidth(for: card)), height: max(height, Card.minimumHeight(for: card)))
    }

    /// Where to ask for a new card of `kind` so that it lands in the middle of what is on screen, stepped
    /// clear of the cards already there, as one picked from the Mac's list does. The point is where the
    /// middle of the card's title bar goes, which is what the Mac is told.
    public static func placeForNewCard(_ kind: CardKind, centre: CGPoint, taken: [CGRect], titleHeight: CGFloat) -> CGPoint {
        let made = Card.make(kind: kind, name: "x", x: 0, y: 0)
        var spot = CGRect(x: max(20, centre.x - made.width / 2), y: max(20, centre.y - made.height / 2), width: made.width, height: made.height)
        var tries = 0
        while tries < 30, taken.contains(where: { $0.insetBy(dx: -16, dy: -16).intersects(spot) }) {
            spot.origin.x += 48
            spot.origin.y += 48
            tries += 1
        }
        return CGPoint(x: spot.midX, y: spot.minY + titleHeight / 2)
    }

    // MARK: What is under the finger, over what the Mac sent

    /// The cards being dragged, where the finger has them. While a drag lasts the canvas is drawn from the
    /// Mac's flow with these laid over it, so a change the Mac sends to any other card shows at once and the
    /// dragged ones stay under the finger.
    public struct Overlay: Equatable, Sendable {
        public var frames: [String: CGRect]

        public init(frames: [String: CGRect]) { self.frames = frames }

        /// The Mac's flow with the dragged cards where the finger has them. A card the Mac has deleted
        /// meanwhile stays deleted.
        public func applied(to flow: Flow) -> Flow {
            guard flow.cards.contains(where: { frames[$0.id] != nil }) else { return flow }
            var merged = flow
            for index in merged.cards.indices {
                guard let frame = frames[merged.cards[index].id] else { continue }
                merged.cards[index].x = frame.minX
                merged.cards[index].y = frame.minY
                merged.cards[index].width = frame.width
                merged.cards[index].height = frame.height
            }
            return merged
        }

        /// Whether the Mac's flow already has every dragged card where the finger left it, so taking the
        /// overlay away moves nothing.
        public func agrees(with flow: Flow) -> Bool { applied(to: flow) == flow }
    }

    // MARK: How often the Mac is told

    /// Lets a step of a drag leave at most so many times a second.
    public struct Throttle: Equatable, Sendable {
        public let interval: TimeInterval
        private var last: TimeInterval?

        public init(perSecond: Double = TouchEdit.stepsPerSecond) { interval = 1 / max(perSecond, 1) }

        /// Nil when a step may leave now, and it is counted as having left. Otherwise how long until one may.
        public mutating func wait(at now: TimeInterval) -> TimeInterval? {
            // A hair's allowance, so clocks that count in fractions of a second don't hold a step back a whole turn.
            if let last, now - last < interval - 1e-9 { return interval - (now - last) }
            last = now
            return nil
        }
    }

    // MARK: Panning from the edges

    /// Holding a drag near the canvas's edge pans the canvas that way. The Mac's own, number for number:
    /// slow just inside the zone, fast pushed to the edge, and the same speed on screen at any zoom.
    public struct EdgePan: Equatable, Sendable {
        /// How near an edge, in points on screen, a drag starts to pan.
        public static let zone: CGFloat = 40
        /// Points on screen a second: just inside the zone, and pushed to the edge or past it.
        public static let speeds: (slow: CGFloat, fast: CGFloat) = (120, 1400)
        /// How deep in each edge's zone the drag has to get before that edge pans. A drag that starts beside
        /// an edge pans only when pushed further.
        private var slack: [CGFloat]

        /// - Parameter depths: how far into each edge's zone the finger is as the drag begins: left, right, top, bottom.
        public init(depths: [CGFloat]) { slack = depths.map { min(max($0, 0), Self.zone) } }

        /// How far the canvas pans in `elapsed` seconds, in the canvas's own points: right and down are positive.
        public mutating func step(depths: [CGFloat], elapsed: TimeInterval, zoom: CGFloat) -> CGPoint {
            var steps: [CGFloat] = [0, 0, 0, 0]
            for (edge, depth) in depths.enumerated() where edge < slack.count {
                // Pulling back from an edge gives up the allowance the drag started with there.
                slack[edge] = min(slack[edge], max(depth, 0))
                let push = min(max(depth - slack[edge], 0) / max(Self.zone - slack[edge], 1), 1)
                let speed = push > 0 ? Self.speeds.slow + push * push * (Self.speeds.fast - Self.speeds.slow) : 0
                steps[edge] = speed * CGFloat(elapsed) / max(zoom, 0.01)
            }
            return CGPoint(x: steps[1] - steps[0], y: steps[3] - steps[2])
        }

        /// How far into the zone along each edge a point is, in points on screen: left, right, top, bottom.
        public static func depths(of point: CGPoint, in bounds: CGRect) -> [CGFloat] {
            [point.x - bounds.minX, bounds.maxX - point.x, point.y - bounds.minY, bounds.maxY - point.y].map { zone - $0 }
        }
    }
}
