import QueenBeeDesign
import SwiftUI

/// The controls the floating panels share, drawn from the tokens so a button, a menu and a
/// stepper all look like parts of the same drawing.

/// A button in a panel. The panels' names for the design system's buttons, so a panel's buttons look like
/// every other button in the app.
struct PanelButtonStyle: ButtonStyle {
    enum Kind {
        /// The usual button: a raised surface with an outline.
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
        let style: DSButtonStyle = switch kind {
        case .outline: .ds(.secondary)
        case .quiet: .ds(.ghost)
        case .filled: .ds(.primary)
        case .live: .ds(.live)
        }
        return style.makeBody(configuration: configuration)
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
            .font(.dsSans(Theme.Size.body, .medium))
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
        padding(.horizontal, DS.Space.s)
            .padding(.vertical, 5)
            .background(Palette.raised.color, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(Palette.hairlineStrong.color))
    }
}
