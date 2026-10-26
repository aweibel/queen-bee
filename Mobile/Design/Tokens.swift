import QueenBeeDesign
import SwiftUI
import UIKit

/// The iPad and iPhone app's names for the design system in `QueenBeeDesign`, which the Mac app shares, so a
/// flow looks the same on the device as it does on the Mac. Colours come from there and nowhere else.
///
/// Colour carries meaning and nothing else. Ink is structure. Orange is live. Green is "the run passed
/// through". Red is "it stopped here". Cobalt is selected or focused.
nonisolated enum Theme {
    // MARK: Colour, as light and dark pairs
    // The app's long-standing names for the roles in `Palette`, the same as the Mac's. New code can take `Palette` directly.

    /// Behind a screen's content, and the canvas.
    static let paper = Palette.panel.platform
    /// A panel, a sheet, a list.
    static let surface = Palette.overlay.platform
    /// A strip or a row set off from what it sits on: a header, a field, a card.
    static let bar = Palette.raised.platform
    /// Under a finger, where the Mac has the pointer over it.
    static let barHover = Palette.hover.platform
    static let ink = Palette.text.platform
    static let inkSecondary = Palette.textMuted.platform
    static let hairline = Palette.hairline.platform
    /// A line that has to be seen: around a control or a card.
    static let outline = Palette.hairlineStrong.platform
    /// The canvas's dot matrix.
    static let dot = Palette.canvasDot.platform

    static let live = Palette.live.platform
    static let liveTint = Palette.liveTint.platform
    static let liveInk = Palette.liveText.platform
    static let passTint = Palette.passTint.platform
    static let passInk = Palette.passText.platform
    static let failTint = Palette.failTint.platform
    static let failInk = Palette.failText.platform
    static let select = Palette.accent.platform

    static let terminal = Palette.terminal.platform
    static let terminalInk = Palette.terminalText.platform

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
        static let card: CGFloat = DS.Radius.m
        static let badge: CGFloat = DS.Radius.xs
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
