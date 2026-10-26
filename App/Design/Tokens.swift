import AppKit
import QueenBeeDesign
import SwiftUI

/// The Mac's names for the design system in `QueenBeeDesign`, which the iPhone and iPad app shares. Every
/// view takes its colours, type, spacing and timing from here or from that module, so the look changes in
/// one place for both apps.
///
/// Colour carries meaning and nothing else. Ink is structure. Orange is live. Green is
/// "the run passed through". Red is "it stopped here". Cobalt is selected or focused.
enum Theme {
    // MARK: Colour, as light and dark pairs
    // The colours from before the redesign, for the screens that haven't moved to `Palette` yet.

    static let paper = Palette.Classic.paper.platform
    static let surface = Palette.Classic.surface.platform
    static let bar = Palette.Classic.bar.platform
    static let barHover = Palette.Classic.barHover.platform
    static let ink = Palette.Classic.ink.platform
    static let inkSecondary = Palette.Classic.inkSecondary.platform
    static let hairline = Palette.Classic.hairline.platform
    /// The canvas's dot matrix.
    static let dot = Palette.Classic.dot.platform

    static let live = Palette.Classic.live.platform
    static let liveTint = Palette.Classic.liveTint.platform
    static let liveInk = Palette.Classic.liveInk.platform
    static let passTint = Palette.Classic.passTint.platform
    static let passInk = Palette.Classic.passInk.platform
    static let failTint = Palette.Classic.failTint.platform
    static let failInk = Palette.Classic.failInk.platform
    static let select = Palette.Classic.select.platform

    static let terminal = Palette.Classic.terminal.platform
    static let terminalInk = Palette.Classic.terminalInk.platform

    // MARK: Type

    /// Monospace, for anything that names or counts: card titles, ports, badges, the log.
    static func mono(_ size: CGFloat = Size.body, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Sans, for anything read as a sentence: settings, help text, instructions.
    static func sans(_ size: CGFloat = Size.body, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    enum Size {
        static let caption: CGFloat = 11
        static let body: CGFloat = 12
        static let title: CGFloat = 13
        static let heading: CGFloat = 15
    }

    // MARK: Shape

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 3
        static let badge: CGFloat = 2
    }

    enum Stroke {
        static let card: CGFloat = 1
        static let link: CGFloat = 1.5
        static let selected: CGFloat = 2
    }

    // MARK: Motion

    enum Motion {
        /// Hover, press, anything tied to the pointer.
        static let quickDuration: TimeInterval = 0.15
        /// Selecting, panels opening, a panel changing height.
        static let standardDuration: TimeInterval = 0.25
        /// The canvas moving: zoom, fit, going to a card.
        static let travelDuration: TimeInterval = 0.3
        /// One step of the dashes marching along a live link.
        static let march: TimeInterval = 0.8

        /// False when the person has asked the Mac for less motion.
        static var isAllowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        /// The SwiftUI curves. Springs with no bounce, so a change that is interrupted
        /// carries on from where it was. Nil, which is no animation, with motion off.
        static var quick: Animation? { isAllowed ? .snappy(duration: quickDuration, extraBounce: 0) : nil }
        static var standard: Animation? { isAllowed ? .snappy(duration: standardDuration, extraBounce: 0) : nil }

        /// Runs AppKit changes made through `animator()` on the travel curve.
        static func travel(_ changes: () -> Void, then done: (@Sendable () -> Void)? = nil) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = isAllowed ? travelDuration : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                changes()
            }, completionHandler: done)
        }
    }

    // MARK: Appearance

    /// System, light or dark, as chosen in the View menu and Settings.
    enum Mode: String, CaseIterable {
        case system, light, dark

        var label: String {
            switch self {
            case .system: "Match the system"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    static let modeKey = "appearance"

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .system
    }

    static func apply(_ mode: Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    /// The same colour for SwiftUI views.
    var ui: Color { Color(nsColor: self) }

    /// The colour as it looks in `appearance`, for layers, which don't follow light and dark by themselves.
    func cg(in appearance: NSAppearance) -> CGColor {
        var resolved = cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = self.cgColor }
        return resolved
    }

    /// The colour fixed to how it looks in `appearance`, for views that take a plain colour once.
    func fixed(in appearance: NSAppearance) -> NSColor {
        NSColor(cgColor: cg(in: appearance)) ?? self
    }
}

extension CALayer {
    /// Sets a colour, width or path, easing from what is on screen now. Layers that belong
    /// to views don't animate by themselves, so the change is given its own animation.
    func ease(_ keyPath: String, to value: Any?, animated: Bool = true, duration: TimeInterval = Theme.Motion.quickDuration) {
        let shown = presentation()?.value(forKeyPath: keyPath) ?? self.value(forKeyPath: keyPath)
        setValue(value, forKeyPath: keyPath)
        guard animated, Theme.Motion.isAllowed, let shown, let value,
              !CFEqual(shown as CFTypeRef, value as CFTypeRef) else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = shown
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(animation, forKey: keyPath)
    }
}

extension Font {
    static func dsMono(_ size: CGFloat = Theme.Size.body, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func dsSans(_ size: CGFloat = Theme.Size.body, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// The look shared by the controls that float over the canvas: the palette, the settings
/// panel, the zoom pill, the status strip. Drawn like a card: a surface and an ink outline,
/// with no shadow.
struct FloatingPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.ink.ui, lineWidth: Theme.Stroke.card))
    }
}

extension View {
    func floatingPanel() -> some View { modifier(FloatingPanel()) }
}

/// A small tinted label: a state, a count, a check.
struct Badge: View {
    enum Tone { case plain, live, pass, fail }
    let text: String
    var symbol: String?
    var tone: Tone = .plain

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            if !text.isEmpty { Text(text) }
        }
        .font(.dsMono(Theme.Size.caption, .medium))
        .foregroundStyle(foreground.ui)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(background.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
    }

    private var foreground: NSColor {
        switch tone {
        case .plain: Theme.inkSecondary
        case .live: Theme.liveInk
        case .pass: Theme.passInk
        case .fail: Theme.failInk
        }
    }

    private var background: NSColor {
        switch tone {
        case .plain: Theme.bar
        case .live: Theme.liveTint
        case .pass: Theme.passTint
        case .fail: Theme.failTint
        }
    }
}
