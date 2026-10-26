import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One colour as it is in light mode and in dark mode, written as hex so the numbers can be read against a
/// mockup. Every colour the apps draw with is one of these, from `Palette`.
public struct Shade: Sendable, Hashable {
    public let light: Int
    public let dark: Int
    public let lightAlpha: Double
    public let darkAlpha: Double

    public init(_ light: Int, _ dark: Int, alpha lightAlpha: Double = 1, _ darkAlpha: Double = 1) {
        self.light = light
        self.dark = dark
        self.lightAlpha = lightAlpha
        self.darkAlpha = darkAlpha
    }

    /// The same colour, see-through by `alpha` in both modes.
    public func opacity(_ alpha: Double) -> Shade {
        Shade(light, dark, alpha: lightAlpha * alpha, darkAlpha * alpha)
    }

    /// The colour for SwiftUI, following light and dark by itself.
    public var color: Color { Color(platform) }

    #if canImport(AppKit)
    /// The colour for AppKit, following the appearance of whatever draws it.
    public var platform: NSColor {
        let light = light, dark = dark, lightAlpha = lightAlpha, darkAlpha = darkAlpha
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? Self.rgb(dark, darkAlpha) : Self.rgb(light, lightAlpha)
        }
    }

    private static func rgb(_ hex: Int, _ alpha: Double) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    #elseif canImport(UIKit)
    /// The colour for UIKit, following the trait collection of whatever draws it.
    public var platform: UIColor {
        let light = light, dark = dark, lightAlpha = lightAlpha, darkAlpha = darkAlpha
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? Self.rgb(dark, darkAlpha) : Self.rgb(light, lightAlpha)
        }
    }

    private static func rgb(_ hex: Int, _ alpha: Double) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    #endif
}

// MARK: Contrast

extension Shade {
    public enum Mode: CaseIterable, Sendable { case light, dark }

    /// The colour in `mode` once laid over `ground`, as plain red, green and blue from 0 to 1.
    /// A see-through colour is mixed with what is under it, which is what a person sees.
    public func resolved(_ mode: Mode, over ground: Shade? = nil) -> (r: Double, g: Double, b: Double) {
        let hex = mode == .light ? light : dark
        let alpha = mode == .light ? lightAlpha : darkAlpha
        let own = Self.channels(hex)
        guard alpha < 1, let ground else { return own }
        let under = ground.resolved(mode)
        return (own.r * alpha + under.r * (1 - alpha),
                own.g * alpha + under.g * (1 - alpha),
                own.b * alpha + under.b * (1 - alpha))
    }

    /// How far apart two colours are to the eye, as WCAG counts it: 1 when they are the same, 21 for black on
    /// white. Text needs 4.5, and large text, icons and outlines need 3.
    public func contrast(with ground: Shade, in mode: Mode) -> Double {
        let a = Self.luminance(resolved(mode, over: ground))
        let b = Self.luminance(ground.resolved(mode))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func channels(_ hex: Int) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }
}
