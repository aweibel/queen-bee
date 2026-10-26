/// Every colour the Mac and the iPhone and iPad apps draw with, as light and dark pairs.
///
/// Colour carries meaning and nothing else. The surfaces and text are Queen Bee's navy and ink. Orange is live,
/// green is "the run passed through", red is "it stopped here", and blue is selected, focused, or the one thing a
/// screen is asking you to do. Depth comes from the surface ladder and hairlines, not from shadows.
public enum Palette {
    // MARK: Surfaces, from the back of the window to the front

    /// The window behind everything: the sidebar and the strip above the content.
    public static let chrome = Shade(0xEFF3F7, 0x0A1422)
    /// The rounded panel the content sits in, and the canvas.
    public static let panel = Shade(0xFFFFFF, 0x0F1B2B)
    /// Something on the panel: a card, a field, a group header, a menu.
    public static let raised = Shade(0xF6F8FB, 0x132235)
    /// Something over everything else: a popover, a sheet, the command menu.
    public static let overlay = Shade(0xFFFFFF, 0x16263A)
    /// Under the pointer or a finger.
    public static let hover = Shade(0xE7ECF3, 0x1B2E46)
    /// The selected row or tab.
    public static let selected = Shade(0xE4EAF2, 0x223955)
    /// Dims what is behind a sheet or the command menu.
    public static let scrim = Shade(0x0A1422, 0x04090F, alpha: 0.28, 0.55)

    // MARK: Lines

    /// Between rows, and around panels and cards.
    public static let hairline = Shade(0x1F3A5F, 0xCFE0F5, alpha: 0.10, 0.08)
    /// Around controls, and wherever a line has to be seen.
    public static let hairlineStrong = Shade(0x1F3A5F, 0xCFE0F5, alpha: 0.18, 0.15)

    // MARK: Text and icons

    /// What is read: titles, names, values.
    public static let text = Shade(0x1F3A5F, 0xCFE0F5)
    /// What explains: labels, descriptions, times, icons at rest.
    public static let textMuted = Shade(0x546A88, 0x8AA3C2)
    /// What can be passed over: placeholders, things that can't be used yet. Never the only place something is said.
    public static let textFaint = Shade(0x7A8DA8, 0x6F87A6)

    // MARK: Accent

    /// Selected, focused, and the one action a screen is asking for.
    public static let accent = Shade(0x2A63D8, 0x6EA0FF)
    /// A wash of the accent behind something selected.
    public static let accentTint = Shade(0xE8EEFC, 0x1A2F52)
    /// Text and icons on the accent.
    public static let onAccent = Shade(0xFFFFFF, 0x0A1422)

    // MARK: States

    /// Live: running, or waiting for you. A dot, a fill, an outline.
    public static let live = Shade(0xE8551A, 0xFF8A4C)
    public static let liveTint = Shade(0xFFE4D6, 0x4A2413)
    public static let liveText = Shade(0x8A3410, 0xFFC7A8)

    /// Passed: the run went through here.
    public static let pass = Shade(0x2E8B57, 0x7FD6A0)
    public static let passTint = Shade(0xDDF3E4, 0x143524)
    public static let passText = Shade(0x17603A, 0x7FD6A0)

    /// Stopped: the run ended here, or something failed.
    public static let fail = Shade(0xC73E3E, 0xF09595)
    public static let failTint = Shade(0xFBE3E3, 0x4A1B1B)
    public static let failText = Shade(0xA32D2D, 0xF09595)

    // MARK: The canvas and the terminal

    /// The canvas's dot matrix.
    public static let canvasDot = Shade(0x1F3A5F, 0xCFE0F5, alpha: 0.16, 0.08)
    /// Behind a terminal. Dark in both modes, as a terminal is.
    public static let terminal = Shade(0x10243D, 0x08111C)
    public static let terminalText = Shade(0xCFE0F5, 0xCFE0F5)
}
