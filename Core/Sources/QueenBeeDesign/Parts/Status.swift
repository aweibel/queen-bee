import SwiftUI

/// What state something is in, which is all its colour may say.
public enum StatusTone: Sendable, Hashable {
    /// Nothing to report: not started, idle, a plain count.
    case neutral
    /// Running, or waiting for you.
    case live
    /// Passed through, done.
    case pass
    /// Stopped, failed.
    case fail
    /// Selected, or new.
    case accent

    /// The solid colour: a dot, a ring, an outline.
    public var mark: Shade {
        switch self {
        case .neutral: Palette.textFaint
        case .live: Palette.live
        case .pass: Palette.pass
        case .fail: Palette.fail
        case .accent: Palette.accent
        }
    }

    /// The wash behind a pill.
    public var tint: Shade {
        switch self {
        case .neutral: Palette.hover
        case .live: Palette.liveTint
        case .pass: Palette.passTint
        case .fail: Palette.failTint
        case .accent: Palette.accentTint
        }
    }

    /// Text on that wash, or on any surface.
    public var text: Shade {
        switch self {
        case .neutral: Palette.textMuted
        case .live: Palette.liveText
        case .pass: Palette.passText
        case .fail: Palette.failText
        case .accent: Palette.accent
        }
    }
}

/// A small round mark for a state. Not started is an empty ring; anything else is filled, and live has a halo.
public struct StatusDot: View {
    let tone: StatusTone
    var size: CGFloat

    public init(_ tone: StatusTone, size: CGFloat = 8) {
        self.tone = tone
        self.size = size
    }

    public var body: some View {
        Group {
            if tone == .neutral {
                Circle().strokeBorder(tone.mark.color, lineWidth: 1.5)
            } else {
                Circle().fill(tone.mark.color)
                    .background(Circle().fill(tone == .live ? tone.mark.opacity(0.25).color : .clear).padding(-size * 0.35))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A state in words, in a rounded wash of its colour: "Running · 3:12", "Needs you", "Stopped".
public struct StatusPill: View {
    let text: String
    let tone: StatusTone
    var showsDot: Bool

    public init(_ text: String, tone: StatusTone, dot: Bool = true) {
        self.text = text
        self.tone = tone
        self.showsDot = dot
    }

    @Environment(\.density) private var density

    public var body: some View {
        HStack(spacing: 6) {
            if showsDot { StatusDot(tone, size: 6) }
            Text(text).lineLimit(1)
        }
        .textRole(.caption)
        .fontWeight(.medium)
        .foregroundStyle(tone.text.color)
        .padding(.horizontal, density == .desk ? 8 : 10)
        .frame(minHeight: density == .desk ? 22 : 28)
        .background(tone.tint.color, in: Capsule())
    }
}

/// A count beside a place in the sidebar or a tab: "2".
public struct CountBadge: View {
    let count: Int
    let tone: StatusTone

    public init(_ count: Int, tone: StatusTone = .neutral) {
        self.count = count
        self.tone = tone
    }

    public var body: some View {
        Text("\(count)")
            .textRole(.caption)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(tone.text.color)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(tone.tint.color, in: Capsule())
    }
}
