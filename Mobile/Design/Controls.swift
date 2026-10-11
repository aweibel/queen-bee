import SwiftUI

/// The parts every screen is built from, drawn from the tokens so a button, a badge and a panel all look
/// like parts of the same drawing. They mirror `App/Design/Controls.swift` and the panel and badge in the
/// Mac's `Tokens.swift`, made big enough for a finger.

/// The look of anything that sits on the paper: a surface and an ink outline, with no shadow.
struct FloatingPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.ink.ui, lineWidth: Theme.Stroke.card))
    }
}

extension View {
    func floatingPanel() -> some View { modifier(FloatingPanel()) }

    /// The box a panel's text is typed into, or a value is shown in.
    func fieldBox() -> some View {
        padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
    }
}

/// A thin rule between two parts of a panel.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline.ui).frame(height: 1) }
}

extension View {
    /// A rule down one side, from the top of the screen to the bottom, where a column meets the paper.
    func edgeRule(_ edge: HorizontalAlignment) -> some View {
        overlay(alignment: Alignment(horizontal: edge, vertical: .center)) {
            Rectangle().fill(Theme.hairline.ui).frame(width: 1).ignoresSafeArea().accessibilityHidden(true)
        }
    }
}

/// A small tinted label: a state, a count, a check.
struct Badge: View {
    enum Tone { case plain, live, pass, fail }
    let text: String
    var symbol: String?
    var tone: Tone = .plain

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            if !text.isEmpty { Text(text) }
        }
        .dsMono(Theme.Touch.caption, .medium)
        .foregroundStyle(foreground.ui)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(background.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
    }

    private var foreground: UIColor {
        switch tone {
        case .plain: Theme.inkSecondary
        case .live: Theme.liveInk
        case .pass: Theme.passInk
        case .fail: Theme.failInk
        }
    }

    private var background: UIColor {
        switch tone {
        case .plain: Theme.bar
        case .live: Theme.liveTint
        case .pass: Theme.passTint
        case .fail: Theme.failTint
        }
    }
}

/// A button in a panel: an ink outline by default, quieter or louder by kind.
struct PanelButtonStyle: ButtonStyle {
    enum Kind {
        /// The usual button: ink text in an ink outline.
        case outline
        /// For an action that should stay out of the way: text only.
        case quiet
        /// The one action a screen is asking for.
        case filled
        /// An action that can't be taken back, like forgetting the Mac.
        case danger
    }

    var kind: Kind = .outline
    /// As wide as the space it is given, for the one button at the foot of a screen.
    var isWide = false

    func makeBody(configuration: Configuration) -> some View {
        PanelButton(configuration: configuration, kind: kind, isWide: isWide)
    }
}

private struct PanelButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: PanelButtonStyle.Kind
    let isWide: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .dsMono(Theme.Touch.body, .medium)
            .lineLimit(1)
            .foregroundStyle(foreground.ui)
            .padding(.horizontal, kind == .quiet ? Theme.Space.s : Theme.Space.l)
            .frame(maxWidth: isWide ? .infinity : nil, minHeight: Theme.Touch.target)
            .background(background.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(border.ui, lineWidth: Theme.Stroke.card))
            .opacity(configuration.isPressed && isEnabled ? 0.6 : 1)
            .contentShape(Rectangle())
            .animation(Theme.Motion.quick, value: configuration.isPressed)
            .animation(Theme.Motion.quick, value: isEnabled)
    }

    // A button that can't be pressed is drawn as a faint outline of itself: no fill, no ink border, grey text.
    private var foreground: UIColor {
        guard isEnabled else { return Theme.inkSecondary.withAlphaComponent(0.55) }
        switch kind {
        case .outline: return Theme.ink
        case .quiet: return Theme.inkSecondary
        case .filled: return Theme.surface
        case .danger: return Theme.failInk
        }
    }

    private var background: UIColor {
        guard isEnabled else { return .clear }
        switch kind {
        case .outline, .quiet: return configuration.isPressed ? Theme.barHover : .clear
        case .filled: return Theme.ink
        case .danger: return configuration.isPressed ? Theme.failTint : .clear
        }
    }

    private var border: UIColor {
        guard isEnabled else { return kind == .quiet ? .clear : Theme.hairline }
        switch kind {
        case .outline, .filled: return Theme.ink
        case .quiet: return .clear
        case .danger: return Theme.failInk
        }
    }
}

extension ButtonStyle where Self == PanelButtonStyle {
    static func panel(_ kind: PanelButtonStyle.Kind = .outline, wide: Bool = false) -> PanelButtonStyle {
        PanelButtonStyle(kind: kind, isWide: wide)
    }
}

/// The drafting paper with its dot matrix: what the canvas is drawn on, and what stands behind every
/// full-screen message.
struct Paper: View {
    var body: some View {
        Canvas { context, size in
            let step = Theme.Grid.step, dot = Theme.Grid.dot
            var dots = Path()
            var y = step
            while y < size.height {
                var x = step
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    x += step
                }
                y += step
            }
            context.fill(dots, with: .color(Theme.dot.ui))
        }
        .background(Theme.paper.ui)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A titled group of rows in a panel or a sheet: a small mono heading over a bordered box.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .dsMono(Theme.Touch.caption)
                .foregroundStyle(Theme.inkSecondary.ui)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
        }
    }
}

/// One line of a `PanelSection`: what it is on the left, its value on the right.
struct PanelRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(label).dsSans().foregroundStyle(Theme.ink.ui)
            Spacer(minLength: Theme.Space.s)
            Text(value).dsMono().foregroundStyle(Theme.inkSecondary.ui).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: Theme.Touch.target)
        .accessibilityElement(children: .combine)
    }
}

/// A plate in the middle of the paper, like a drawing's title block: a symbol, a name, a sentence, and
/// at most one thing to do.
struct Plate<Actions: View>: View {
    var symbol: String?
    let title: String
    var text: String = ""
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.ink.ui)
                    .accessibilityHidden(true)
            }
            VStack(spacing: Theme.Space.s) {
                Text(title)
                    .dsMono(Theme.Touch.heading, .medium)
                    .foregroundStyle(Theme.ink.ui)
                    .accessibilityAddTraits(.isHeader)
                if !text.isEmpty {
                    Text(text)
                        .dsSans()
                        .foregroundStyle(Theme.inkSecondary.ui)
                }
            }
            .multilineTextAlignment(.center)
            actions
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 440)
        .floatingPanel()
        .padding(Theme.Space.l)
    }
}

extension Plate where Actions == EmptyView {
    init(symbol: String? = nil, title: String, text: String = "") {
        self.init(symbol: symbol, title: title, text: text) { EmptyView() }
    }
}
