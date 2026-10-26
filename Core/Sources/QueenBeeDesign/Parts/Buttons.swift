import SwiftUI

/// The app's buttons. One kind per job, so a screen never has two buttons shouting at once.
public struct DSButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// The one action a screen is asking for: Run, Approve, Send. Filled with the accent.
        case primary
        /// An ordinary action: a raised surface with an outline.
        case secondary
        /// An action that stays out of the way: text only until the pointer or a finger is on it.
        case ghost
        /// An action that can't be taken back: Delete, Forget this Mac.
        case danger
        /// An answer something live is waiting for, and Stop.
        case live
    }

    public var kind: Kind
    /// As wide as the space it is given.
    public var isWide: Bool

    public init(_ kind: Kind = .secondary, wide: Bool = false) {
        self.kind = kind
        self.isWide = wide
    }

    public func makeBody(configuration: Configuration) -> some View {
        DSButton(configuration: configuration, kind: kind, isWide: isWide)
    }
}

private struct DSButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let isWide: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.density) private var density
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: density == .desk ? DS.Radius.s : DS.Radius.m, style: .continuous)
        configuration.label
            .textRole(.label)
            .lineLimit(1)
            .foregroundStyle(foreground.color)
            .padding(.horizontal, density == .desk ? 10 : DS.Space.l)
            .frame(maxWidth: isWide ? .infinity : nil,
                   minHeight: density == .desk ? DS.Size.control : DS.Size.touchTarget)
            .background(background.color, in: shape)
            .overlay(shape.strokeBorder(border.color, lineWidth: DS.Stroke.hairline))
            .opacity(configuration.isPressed && isEnabled ? 0.75 : 1)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(DS.Motion.quick, value: configuration.isPressed)
            .animation(DS.Motion.quick, value: isHovered)
    }

    private var isLit: Bool { isEnabled && (isHovered || configuration.isPressed) }

    // A button that can't be pressed keeps its shape, faintly, with no fill.
    private var foreground: Shade {
        guard isEnabled else { return Palette.textFaint }
        switch kind {
        case .primary: return Palette.onAccent
        case .secondary, .ghost: return isLit || kind == .secondary ? Palette.text : Palette.textMuted
        case .danger: return Palette.failText
        case .live: return Palette.liveText
        }
    }

    private var background: Shade {
        guard isEnabled else { return Palette.panel.opacity(0) }
        switch kind {
        case .primary: return Palette.accent
        case .secondary: return isLit ? Palette.hover : Palette.raised
        case .ghost: return isLit ? Palette.hover : Palette.panel.opacity(0)
        case .danger: return isLit ? Palette.failTint : Palette.panel.opacity(0)
        case .live: return Palette.liveTint
        }
    }

    private var border: Shade {
        guard isEnabled else { return kind == .ghost ? Palette.hairline.opacity(0) : Palette.hairline }
        switch kind {
        case .primary: return Palette.accent
        case .secondary: return Palette.hairlineStrong
        case .ghost: return Palette.hairline.opacity(0)
        case .danger: return Palette.fail.opacity(0.5)
        case .live: return Palette.live.opacity(0.5)
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    public static func ds(_ kind: DSButtonStyle.Kind = .secondary, wide: Bool = false) -> DSButtonStyle {
        DSButtonStyle(kind, wide: wide)
    }
}

/// A square button with only an icon: a toolbar's search, more, pin. Give it an accessibility label.
public struct DSIconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DSIconButton(configuration: configuration)
    }
}

private struct DSIconButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.density) private var density
    @State private var isHovered = false

    var body: some View {
        let side = density == .desk ? DS.Size.control : DS.Size.touchTarget
        configuration.label
            .font(.system(size: density == .desk ? 13 : 17, weight: .medium))
            .foregroundStyle((isEnabled ? (isHovered ? Palette.text : Palette.textMuted) : Palette.textFaint).color)
            .frame(width: side, height: side)
            .background((isHovered || configuration.isPressed ? Palette.hover : Palette.panel.opacity(0)).color,
                        in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(DS.Motion.quick, value: isHovered)
    }
}

extension ButtonStyle where Self == DSIconButtonStyle {
    public static var dsIcon: DSIconButtonStyle { DSIconButtonStyle() }
}
