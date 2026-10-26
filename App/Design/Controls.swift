import SwiftUI

/// The controls the floating panels share, drawn from the tokens so a button, a menu and a
/// stepper all look like parts of the same drawing.

/// A button in a panel: an ink outline by default, quieter or louder by kind.
struct PanelButtonStyle: ButtonStyle {
    enum Kind {
        /// The usual button: ink text in an ink outline.
        case outline
        /// For an action that should stay out of the way, like Delete or Skip: text only.
        case quiet
        /// The one action a panel is asking for.
        case filled
        /// An action that touches a live session.
        case live
    }

    var kind: Kind = .outline

    func makeBody(configuration: Configuration) -> some View {
        PanelButton(configuration: configuration, kind: kind)
    }
}

private struct PanelButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: PanelButtonStyle.Kind
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.dsMono(Theme.Size.caption, .medium))
            .foregroundStyle(foreground.ui)
            .padding(.horizontal, kind == .quiet ? 6 : 10)
            .padding(.vertical, 4)
            .background(background.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(border.ui, lineWidth: Theme.Stroke.card))
            .opacity(configuration.isPressed && isEnabled ? 0.6 : 1)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(Theme.Motion.quick, value: isHovered)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
            .animation(Theme.Motion.quick, value: isEnabled)
    }

    // A button that can't be pressed is drawn as a faint outline of itself: no fill, no ink
    // border, grey text. One that can is ink, and the one a panel is asking for is filled.
    private var foreground: NSColor {
        guard isEnabled else { return Theme.inkSecondary.withAlphaComponent(0.55) }
        switch kind {
        case .outline: return Theme.ink
        case .quiet: return isHovered ? Theme.ink : Theme.inkSecondary
        case .filled: return Theme.surface
        case .live: return Theme.liveInk
        }
    }

    private var background: NSColor {
        guard isEnabled else { return .clear }
        switch kind {
        case .outline: return isHovered ? Theme.barHover : .clear
        case .quiet: return isHovered ? Theme.barHover : .clear
        case .filled: return isHovered ? Theme.inkSecondary : Theme.ink
        case .live: return isHovered ? Theme.live.withAlphaComponent(0.25) : Theme.liveTint
        }
    }

    private var border: NSColor {
        guard isEnabled else { return kind == .quiet ? .clear : Theme.hairline }
        switch kind {
        case .outline: return Theme.ink
        case .quiet: return .clear
        case .filled: return isHovered ? Theme.inkSecondary : Theme.ink
        case .live: return Theme.live
        }
    }
}

extension ButtonStyle where Self == PanelButtonStyle {
    static func panel(_ kind: PanelButtonStyle.Kind = .outline) -> PanelButtonStyle { PanelButtonStyle(kind: kind) }
}

/// A choice from a short list: the current value, with a menu of the others behind it.
struct MenuField<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    /// Lets a long label be cut short in the middle to fit, for names of any length such as branches. Otherwise
    /// the field is always as wide as its label.
    var shortensToFit = false
    let pick: (Value) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Toggle(option.label, isOn: Binding(get: { option.value == selection }, set: { _ in pick(option.value) }))
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary.ui)
            }
            .font(.dsMono(Theme.Size.caption, .medium))
            .foregroundStyle(Theme.ink.ui)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !shortensToFit, vertical: true)
    }
}

/// A small whole number with a button either side of it.
struct StepField: View {
    let value: Int
    let range: ClosedRange<Int>
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            step("minus", to: value - 1)
            Text("\(value)")
                .font(.dsMono(Theme.Size.caption, .medium))
                .frame(minWidth: 22)
                .contentTransition(.numericText())
                .animation(Theme.Motion.quick, value: value)
            step("plus", to: value + 1)
        }
        .foregroundStyle(Theme.ink.ui)
    }

    private func step(_ symbol: String, to next: Int) -> some View {
        Button { set(next) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!range.contains(next))
        .opacity(range.contains(next) ? 1 : 0.35)
    }
}

extension View {
    /// The box a panel's text is typed into.
    func fieldBox() -> some View {
        padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
    }
}
