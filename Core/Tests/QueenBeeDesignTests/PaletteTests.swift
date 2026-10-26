import Testing
@testable import QueenBeeDesign

/// Every colour pairing the screens can draw has to be readable, in light mode and in dark mode.
@Suite struct PaletteTests {
    private static let textColours: [(String, Shade)] = [
        ("text", Palette.text), ("textMuted", Palette.textMuted),
    ]

    private static let grounds: [(String, Shade)] = [
        ("chrome", Palette.chrome), ("panel", Palette.panel), ("raised", Palette.raised),
        ("overlay", Palette.overlay), ("hover", Palette.hover), ("selected", Palette.selected),
    ]

    @Test(arguments: Shade.Mode.allCases)
    func textIsReadableOnEverySurface(mode: Shade.Mode) {
        for (name, colour) in Self.textColours {
            for (groundName, ground) in Self.grounds {
                let ratio = colour.contrast(with: ground, in: mode)
                #expect(ratio >= 4.5, "\(name) on \(groundName) in \(mode) is \(ratio)")
            }
        }
    }

    /// Faint text is for placeholders and things that can't be used yet, and dots, rings and outlines are not
    /// read as words: these need 3:1 on the surfaces they are drawn on.
    @Test(arguments: Shade.Mode.allCases)
    func marksStandOutFromTheirSurfaces(mode: Shade.Mode) {
        let marks: [(String, Shade)] = [
            ("textFaint", Palette.textFaint), ("accent", Palette.accent),
            ("live", Palette.live), ("pass", Palette.pass), ("fail", Palette.fail),
        ]
        for (name, colour) in marks {
            for (groundName, ground) in [("chrome", Palette.chrome), ("panel", Palette.panel), ("raised", Palette.raised)] {
                let ratio = colour.contrast(with: ground, in: mode)
                #expect(ratio >= 3, "\(name) on \(groundName) in \(mode) is \(ratio)")
            }
        }
    }

    @Test(arguments: Shade.Mode.allCases)
    func stateTextIsReadableOnItsWashAndOnThePanel(mode: Shade.Mode) {
        for tone in [StatusTone.neutral, .live, .pass, .fail, .accent] {
            for ground in [tone.tint, Palette.panel, Palette.raised] {
                let ratio = tone.text.contrast(with: ground, in: mode)
                #expect(ratio >= 4.5, "\(tone) text in \(mode) is \(ratio)")
            }
        }
    }

    @Test(arguments: Shade.Mode.allCases)
    func textOnTheAccentIsReadable(mode: Shade.Mode) {
        let ratio = Palette.onAccent.contrast(with: Palette.accent, in: mode)
        #expect(ratio >= 4.5, "on the accent in \(mode) is \(ratio)")
    }

    @Test(arguments: Shade.Mode.allCases)
    func terminalTextIsReadable(mode: Shade.Mode) {
        #expect(Palette.terminalText.contrast(with: Palette.terminal, in: mode) >= 7)
        #expect(Palette.terminalMuted.contrast(with: Palette.terminal, in: mode) >= 4.5)
    }

    /// The surfaces step up from the back of the window to the front in dark mode, as Linear's do, so a raised
    /// thing reads as raised without a shadow.
    @Test func darkSurfacesGetLighterTowardsTheFront() {
        let ladder = [Palette.chrome, Palette.panel, Palette.raised, Palette.overlay, Palette.hover, Palette.selected]
        let brightness = ladder.map { shade in
            let c = shade.resolved(.dark)
            return c.r + c.g + c.b
        }
        #expect(brightness == brightness.sorted())
    }

    @Test func contrastMatchesKnownValues() {
        let black = Shade(0x000000, 0x000000), white = Shade(0xFFFFFF, 0xFFFFFF)
        #expect(abs(black.contrast(with: white, in: .light) - 21) < 0.01)
        #expect(abs(white.contrast(with: white, in: .dark) - 1) < 0.01)
    }

    @Test func seeThroughColoursAreMixedWithTheirGround() {
        let halfBlack = Shade(0x000000, 0x000000, alpha: 0.5, 0.5)
        let white = Shade(0xFFFFFF, 0xFFFFFF)
        let mixed = halfBlack.resolved(.light, over: white)
        #expect(abs(mixed.r - 0.5) < 0.001 && abs(mixed.g - 0.5) < 0.001 && abs(mixed.b - 0.5) < 0.001)
    }

    /// Until the screens move over, both apps draw with these. They must stay exactly as they were.
    @Test func classicColoursAreUnchanged() {
        #expect(Palette.Classic.paper == Shade(0xE3EAF1, 0x0F1B2B))
        #expect(Palette.Classic.ink == Shade(0x1F3A5F, 0xCFE0F5))
        #expect(Palette.Classic.inkSecondary == Shade(0x5A7190, 0x8AA3C2))
        #expect(Palette.Classic.hairline == Shade(0x1F3A5F, 0xCFE0F5, alpha: 0.22, 0.2))
        #expect(Palette.Classic.live == Shade(0xFF6B2C, 0xFF8A4C))
        #expect(Palette.Classic.select == Shade(0x2F6FED, 0x6EA0FF))
        #expect(Palette.Classic.terminal == Shade(0x10243D, 0x0A1420))
    }
}
