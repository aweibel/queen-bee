import SwiftUI

/// What a piece of text is for, which decides its size, weight and letter spacing. Sans for everything read;
/// monospace only for what is copied or compared character by character: ids, paths, branches, costs, code.
///
/// Larger text is drawn slightly tighter, as Linear's is. On touch devices text also grows with the
/// person's text size.
public struct TextRole: Sendable, Hashable {
    public let desk: CGFloat
    public let touch: CGFloat
    public let weight: Font.Weight
    /// Letter spacing in points at the desk size; scaled with the size on touch.
    public let tracking: CGFloat
    public let isMono: Bool

    public init(desk: CGFloat, touch: CGFloat, weight: Font.Weight = .regular, tracking: CGFloat = 0, isMono: Bool = false) {
        self.desk = desk
        self.touch = touch
        self.weight = weight
        self.tracking = tracking
        self.isMono = isMono
    }

    public func size(_ density: Density) -> CGFloat { density == .desk ? desk : touch }

    public func tracking(_ density: Density) -> CGFloat { density == .desk ? tracking : tracking * touch / desk }

    /// The font at a fixed size, for drawing that is zoomed rather than read at the person's text size: the canvas.
    public func font(_ density: Density = .platform) -> Font {
        .system(size: size(density), weight: weight, design: isMono ? .monospaced : .default)
    }

    /// The screen's title: "Needs you", a flow's name in its header on the phone.
    public static let largeTitle = TextRole(desk: 22, touch: 30, weight: .bold, tracking: -0.5)
    /// A panel's or a sheet's title: the selected card's name in the inspector.
    public static let title = TextRole(desk: 17, touch: 22, weight: .semibold, tracking: -0.3)
    /// A name in a row or a card's title bar.
    public static let headline = TextRole(desk: 13, touch: 16, weight: .semibold)
    /// A sentence.
    public static let body = TextRole(desk: 13, touch: 15)
    /// A control's text: buttons, tabs, sidebar rows, menu items.
    public static let label = TextRole(desk: 13, touch: 15, weight: .medium)
    /// Small print: a time, a hint under a field.
    public static let caption = TextRole(desk: 11.5, touch: 13)
    /// The small heading over a group: "Pinned", a project's name, "Properties".
    public static let sectionHeader = TextRole(desk: 12, touch: 13, weight: .medium)
    /// Ids, paths, branches, costs.
    public static let mono = TextRole(desk: 12, touch: 14, isMono: true)
    public static let monoCaption = TextRole(desk: 11, touch: 12, isMono: true)
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole
    @Environment(\.density) private var density
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        // Names and figures grow half as fast as sentences: they sit in rows and pills, where twice the size no longer fits.
        let grow = density == .touch ? (role.isMono ? 1 + (scale - 1) / 2 : scale) : 1
        content
            .font(.system(size: role.size(density) * grow, weight: role.weight, design: role.isMono ? .monospaced : .default))
            .tracking(role.tracking(density))
    }
}

extension View {
    /// Sets the font for what this text is for, at the size for this device.
    public func textRole(_ role: TextRole) -> some View {
        modifier(TextRoleModifier(role: role))
    }
}
