import SwiftUI

/// How tightly a screen is packed. The Mac is read at a desk with a pointer, so rows are short and type is small.
/// The iPhone and iPad are held and tapped, so everything a finger hits is at least 44 points and type is larger.
public enum Density: Sendable {
    case desk, touch

    /// What this device is, unless a view says otherwise.
    public static var platform: Density {
        #if os(macOS)
        .desk
        #else
        .touch
        #endif
    }
}

extension EnvironmentValues {
    @Entry public var density: Density = .platform
}

/// The measures every screen is laid out with. A view takes a number from here or from a part that does.
public enum DS {
    /// Gaps and padding, on a 4-point step.
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    /// Corner radii. Small things get small corners; nothing is fully round except pills and dots.
    public enum Radius {
        /// A key hint, a badge.
        public static let xs: CGFloat = 4
        /// A button, a sidebar row, a menu item.
        public static let s: CGFloat = 6
        /// A field, a terminal inside a card, a menu.
        public static let m: CGFloat = 8
        /// A card, the inset panel.
        public static let l: CGFloat = 10
        /// A popover, the command menu, a floating bar.
        public static let xl: CGFloat = 12
        /// A sheet on the iPhone.
        public static let sheet: CGFloat = 28
    }

    /// Line widths.
    public enum Stroke {
        public static let hairline: CGFloat = 1
        public static let link: CGFloat = 1.5
        /// The ring around a selected card or a focused field.
        public static let focus: CGFloat = 2
    }

    /// Heights and widths that keep the layout in line from screen to screen.
    public enum Size {
        /// The least height of anything a finger is meant to hit.
        public static let touchTarget: CGFloat = 44
        /// A row in the Mac's sidebar.
        public static let navRow: CGFloat = 28
        /// A row in a list on the Mac.
        public static let listRow: CGFloat = 40
        /// A list's group header on the Mac.
        public static let groupHeader: CGFloat = 36
        /// The header across the top of the inset panel.
        public static let header: CGFloat = 44
        /// The row of pill tabs under it.
        public static let tabRow: CGFloat = 40
        /// A button on the Mac.
        public static let control: CGFloat = 28
        /// The Mac's sidebar.
        public static let sidebarWidth: CGFloat = 236
        /// How far the inset panel sits in from the window's edges.
        public static let panelInset: CGFloat = 8
    }

    /// Timing, the same on every device.
    public enum Motion {
        /// Hover, press, anything tied to the pointer or a finger.
        public static let quickDuration: TimeInterval = 0.15
        /// Selecting, panels opening, a panel changing height.
        public static let standardDuration: TimeInterval = 0.25
        /// The canvas moving: zoom, fit, going to a card.
        public static let travelDuration: TimeInterval = 0.3
        /// One step of the dashes marching along a live link.
        public static let march: TimeInterval = 0.8

        /// Springs with no bounce, so a change that is interrupted carries on from where it was.
        public static let quick: Animation = .snappy(duration: quickDuration, extraBounce: 0)
        public static let standard: Animation = .snappy(duration: standardDuration, extraBounce: 0)
    }
}
