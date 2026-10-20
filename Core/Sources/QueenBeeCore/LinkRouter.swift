import CoreGraphics

/// Draws a link as a right-angled route, the way a wiring diagram does. Outputs sit on a
/// card's right edge and inputs on its left, so a route always leaves to the right and
/// arrives from the left.
public enum LinkRouter {
    /// How far a route runs straight out of a port before it may turn.
    public static let stub: CGFloat = 18
    /// The gap a route keeps from the cards it passes around.
    public static let clearance: CGFloat = 22

    /// The corner points of a route from `a` (an output on `source`) to `b` (an input on `target`).
    /// `lane` spreads routes that would otherwise run on top of each other: each step moves
    /// this route's turns a little further out.
    public static func route(from a: CGPoint, to b: CGPoint, source: CGRect, target: CGRect, lane: Int = 0) -> [CGPoint] {
        let spread = CGFloat(lane) * 7
        if b.x - a.x >= stub * 2 {
            if abs(a.y - b.y) < 0.5 { return [a, b] }
            let mid = ((a.x + b.x) / 2).rounded() + spread
            let turn = min(max(mid, a.x + stub), b.x - stub)
            return [a, CGPoint(x: turn, y: a.y), CGPoint(x: turn, y: b.y), b]
        }
        // The target is level with or behind the source: go out to the right, pass above or
        // below both cards, and come back in from the left.
        let out = a.x + stub + spread
        let back = b.x - stub - spread
        let below = max(source.maxY, target.maxY) + clearance + spread
        let above = min(source.minY, target.minY) - clearance - spread
        let viaBelow = above < 8 || abs(below - a.y) + abs(below - b.y) <= abs(above - a.y) + abs(above - b.y)
        let y = viaBelow ? below : above
        return [a, CGPoint(x: out, y: a.y), CGPoint(x: out, y: y), CGPoint(x: back, y: y), CGPoint(x: back, y: b.y), b]
    }

    /// A path through the points with each corner rounded.
    public static func path(through points: [CGPoint], radius: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last, points.count == 2 { path.addLine(to: last) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let corner = points[i], next = points[i + 1], previous = points[i - 1]
            // A corner can't be rounder than half the shorter of the two runs that meet at it.
            let reach = min(hypot(corner.x - previous.x, corner.y - previous.y), hypot(next.x - corner.x, next.y - corner.y)) / 2
            path.addArc(tangent1End: corner, tangent2End: next, radius: min(radius, reach))
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// The middle of the route's longest run: where a label sits without covering a corner.
    public static func labelPoint(of points: [CGPoint]) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        var best = (length: CGFloat(-1), point: points[0])
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            if length > best.length { best = (length, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)) }
        }
        return best.point
    }
}

/// Everything the drawn links of a flow depend on: the links, where each card is and how big, its outputs, and
/// the groups that fold cards away. Two flows with equal geometry draw the same links, so a change elsewhere,
/// such as a card's name or instructions, needn't redraw them.
public struct LinkGeometry: Equatable, Sendable {
    struct Shape: Equatable, Sendable {
        var id: String
        var frame: CGRect
        var ports: [String]
    }

    let links: [Link]
    let cards: [Shape]
    let groups: [CardGroup]

    public init(_ flow: Flow?) {
        links = flow?.links ?? []
        cards = (flow?.cards ?? []).map {
            Shape(id: $0.id, frame: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height), ports: ports(of: $0))
        }
        groups = flow?.groups ?? []
    }
}
