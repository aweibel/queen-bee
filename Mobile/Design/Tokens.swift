import SwiftUI
import UIKit

/// The Flight plan design system, as the iPad and iPhone app uses it. These mirror `App/Design/Tokens.swift`
/// value for value, so a flow looks the same on the device as it does on the Mac: drafting paper, ink
/// lines, and one signal colour for whatever is live. Change a value there and change it here.
///
/// Colour carries meaning and nothing else. Ink is structure. Orange is live. Green is "the run passed
/// through". Red is "it stopped here". Cobalt is selected or focused.
nonisolated enum Theme {
    // MARK: Colour, as light and dark pairs

    static let paper = pair(0xE3EAF1, 0x0F1B2B)
    static let surface = pair(0xFFFFFF, 0x16263A)
    static let bar = pair(0xF3F6FA, 0x1B2E46)
    /// Under a finger, where the Mac has the pointer over it.
    static let barHover = pair(0xE7EDF4, 0x223955)
    static let ink = pair(0x1F3A5F, 0xCFE0F5)
    static let inkSecondary = pair(0x5A7190, 0x8AA3C2)
    static let hairline = pair(0x1F3A5F, 0xCFE0F5, alpha: 0.22, 0.2)
    /// The canvas's dot matrix.
    static let dot = pair(0x1F3A5F, 0xCFE0F5, alpha: 0.26, 0.2)

    static let live = pair(0xFF6B2C, 0xFF8A4C)
    static let liveTint = pair(0xFFE4D6, 0x4A2413)
    static let liveInk = pair(0x8A3410, 0xFFC7A8)
    static let passTint = pair(0xDDF3E4, 0x143524)
    static let passInk = pair(0x17603A, 0x7FD6A0)
    static let failTint = pair(0xFBE3E3, 0x4A1B1B)
    static let failInk = pair(0xA32D2D, 0xF09595)
    static let select = pair(0x2F6FED, 0x6EA0FF)

    static let terminal = pair(0x10243D, 0x0A1420)
    static let terminalInk = pair(0xCFE0F5, 0xCFE0F5)

    private static func pair(_ light: Int, _ dark: Int, alpha lightAlpha: CGFloat = 1, _ darkAlpha: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark, darkAlpha) : rgb(light, lightAlpha) }
    }

    private static func rgb(_ hex: Int, _ alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // MARK: Type

    /// Monospace, for anything that names or counts: card titles, ports, badges, flow names.
    /// A fixed size, for the canvas, which is zoomed rather than read at the system's text size.
    static func mono(_ size: CGFloat = Size.body, _ weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Sans, for anything read as a sentence: settings, help text, instructions.
    static func sans(_ size: CGFloat = Size.body, _ weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// The Mac's sizes, which is what the canvas is drawn in so a card matches the Mac's.
    enum Size {
        static let caption: CGFloat = 11
        static let body: CGFloat = 12
        static let title: CGFloat = 13
        static let heading: CGFloat = 15
    }

    /// The same four steps for everything outside the canvas. A list held in the hand and tapped with a
    /// finger needs bigger type than one read at a desk with a pointer. These grow with the person's text size.
    enum Touch {
        static let caption: CGFloat = 12
        static let body: CGFloat = 15
        static let title: CGFloat = 17
        static let heading: CGFloat = 22
        /// The least height of anything a finger is meant to hit.
        static let target: CGFloat = 44
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

    /// The paper's dot matrix: one dot at every step, as on the Mac's canvas.
    enum Grid {
        static let step: CGFloat = 24
        static let dot: CGFloat = 1.6
    }

    // MARK: Motion

    enum Motion {
        /// A press, anything tied to the finger.
        static let quickDuration: TimeInterval = 0.15
        /// Selecting, panels opening, a panel changing height.
        static let standardDuration: TimeInterval = 0.25
        /// The canvas moving: zoom, fit, going to a card.
        static let travelDuration: TimeInterval = 0.3
        /// One step of the dashes marching along a live link.
        static let march: TimeInterval = 0.8

        /// False when the person has asked the device for less motion.
        @MainActor static var isAllowed: Bool { !UIAccessibility.isReduceMotionEnabled }

        /// Springs with no bounce, so a change that is interrupted carries on from where it was.
        /// Nil, which is no animation, with motion off.
        @MainActor static var quick: Animation? { isAllowed ? .snappy(duration: quickDuration, extraBounce: 0) : nil }
        @MainActor static var standard: Animation? { isAllowed ? .snappy(duration: standardDuration, extraBounce: 0) : nil }
    }
}

extension UIColor {
    /// The same colour for SwiftUI views.
    nonisolated var ui: Color { Color(uiColor: self) }
}

extension Font {
    /// Fixed sizes, for the canvas. Everything else uses `dsMono` and `dsSans` on a view, which grow with the text size.
    static func dsMono(_ size: CGFloat = Theme.Size.body, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func dsSans(_ size: CGFloat = Theme.Size.body, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// One of the two faces at a size that follows the person's text size. Sentences grow all the way. Names and
/// figures grow half as fast: they sit in rows and badges, where a name twice the size no longer fits.
private struct ScaledType: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let base: CGFloat
    private let weight: Font.Weight
    private let isMono: Bool

    init(size: CGFloat, weight: Font.Weight, isMono: Bool) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: .body)
        base = size
        self.weight = weight
        self.isMono = isMono
    }

    func body(content: Content) -> some View {
        content.font(isMono ? .system(size: base + (scaled - base) / 2, weight: weight, design: .monospaced)
                            : .system(size: scaled, weight: weight))
    }
}

extension View {
    /// Monospace, for a name or a figure outside the canvas.
    func dsMono(_ size: CGFloat = Theme.Touch.body, _ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledType(size: size, weight: weight, isMono: true))
    }

    /// Sans, for a sentence outside the canvas.
    func dsSans(_ size: CGFloat = Theme.Touch.body, _ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledType(size: size, weight: weight, isMono: false))
    }
}
