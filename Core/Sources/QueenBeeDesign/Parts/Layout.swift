import SwiftUI

/// The rounded panel the content of the window sits in, raised off the chrome by a hairline rather than a shadow.
public struct InsetPanel: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
        content
            .background(Palette.panel.color, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline.color, lineWidth: DS.Stroke.hairline))
    }
}

/// Something raised on the panel: a card, a group of properties, a menu.
public struct RaisedSurface: ViewModifier {
    var radius: CGFloat
    var ground: Shade

    public init(radius: CGFloat = DS.Radius.l, ground: Shade = Palette.raised) {
        self.radius = radius
        self.ground = ground
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(ground.color, in: shape)
            .overlay(shape.strokeBorder(Palette.hairlineStrong.color, lineWidth: DS.Stroke.hairline))
    }
}

extension View {
    public func insetPanel() -> some View { modifier(InsetPanel()) }

    public func raisedSurface(radius: CGFloat = DS.Radius.l, ground: Shade = Palette.raised) -> some View {
        modifier(RaisedSurface(radius: radius, ground: ground))
    }
}

/// A one-point line between rows or sections.
public struct DSDivider: View {
    var isVertical: Bool

    public init(vertical: Bool = false) { isVertical = vertical }

    public var body: some View {
        Rectangle()
            .fill(Palette.hairline.color)
            .frame(width: isVertical ? DS.Stroke.hairline : nil, height: isVertical ? nil : DS.Stroke.hairline)
            .accessibilityHidden(true)
    }
}

/// The small heading over a group: "Pinned", a project's name, "Properties". Something may sit at its end, like a + button.
public struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    @Environment(\.density) private var density

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(title).lineLimit(1).accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Space.s)
            trailing
        }
        .textRole(.sectionHeader)
        .foregroundStyle(Palette.textFaint.color)
        .padding(.horizontal, DS.Space.s)
        .frame(minHeight: density == .desk ? 26 : 32)
    }
}

extension SectionHeader where Trailing == EmptyView {
    public init(_ title: String) { self.init(title) { EmptyView() } }
}

/// A keyboard shortcut, as it is shown beside a menu item or a button: ⌘K.
public struct KeyHint: View {
    let keys: [String]

    public init(_ keys: String...) { self.keys = keys }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .textRole(.monoCaption)
                    .foregroundStyle(Palette.textMuted.color)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Palette.hover.color, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}
