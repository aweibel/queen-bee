import QueenBeeCore
import SwiftUI
import UIKit

/// Takes the keyboard for a session's terminal, in place of the terminal itself. The terminal on screen is a
/// `MirrorTerminalView`, which can't have the keyboard at all: whatever SwiftTerm sends for a key goes out
/// by the same door as its answers to the program's questions, and that door is shut. So keys come here,
/// to a view that draws nothing, and are handed on as what was pressed. The bytes are made in `TerminalKeys`.
///
/// It works the same with the keyboard on screen and with a real one. With a real one, iOS shows no
/// keyboard and sends the presses here all the same.
final class KeyCatcher: UIView, UIKeyInput {
    /// Text from the keyboard: a letter, a word chosen from above the keys, or the Return key as a new line.
    var onText: ((String) -> Void)?
    var onKey: ((TerminalKey) -> Void)?
    /// Ctrl held with a character on a real keyboard. Returns false if Ctrl does nothing to it.
    var onControl: ((Character) -> Bool)?
    /// Told when it gets the keyboard and when it loses it, by any means: a button here, or the person
    /// putting the keyboard away.
    var onFocus: ((Bool) -> Void)?
    private var isWanted = false
    /// The last character taken with Ctrl held, and when: see `insertText`.
    private var taken: (character: String, at: TimeInterval)?
    /// How long after Ctrl with a letter was taken the same letter arriving as text is counted as that same press.
    private static let sameWithin: TimeInterval = 0.15

    override var canBecomeFirstResponder: Bool { true }

    /// Asks for the keyboard, or gives it up.
    func want(_ wanted: Bool) {
        isWanted = wanted
        // Not from inside the update that said so: taking the keyboard changes what is on screen.
        Task { [weak self] in self?.settle() }
    }

    private func settle() {
        if isWanted, !isFirstResponder, window != nil {
            becomeFirstResponder()
        } else if !isWanted, isFirstResponder {
            resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { settle() }
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let did = super.becomeFirstResponder()
        if did { onFocus?(true) }
        return did
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let did = super.resignFirstResponder()
        if did { onFocus?(false) }
        return did
    }

    // MARK: The keyboard on screen, and plain typing on a real one

    var hasText: Bool { true }

    func insertText(_ text: String) {
        // Ctrl with a letter is taken in `pressesBegan`. If the keyboard hands the same press on as a control
        // character too, it is not typed twice. Return and Tab are the two that are typed.
        let typed = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }))
        // Nor is it typed again if the keyboard hands it on as the plain letter, a moment after.
        if let taken, ProcessInfo.processInfo.systemUptime - taken.at < Self.sameWithin, typed.lowercased() == taken.character { return }
        if !typed.isEmpty { onText?(typed) }
    }

    func deleteBackward() { onKey?(.backspace) }

    // A terminal is typed into letter for letter: nothing is corrected, capitalised or made curly.
    var autocapitalizationType = UITextAutocapitalizationType.none
    var autocorrectionType = UITextAutocorrectionType.no
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no
    var keyboardType = UIKeyboardType.default
    var keyboardAppearance = UIKeyboardAppearance.default

    // MARK: A real keyboard's other keys

    private static let named: [(input: String, flags: UIKeyModifierFlags, key: TerminalKey)] = [
        (UIKeyCommand.inputUpArrow, [], .up), (UIKeyCommand.inputDownArrow, [], .down),
        (UIKeyCommand.inputLeftArrow, [], .left), (UIKeyCommand.inputRightArrow, [], .right),
        (UIKeyCommand.inputEscape, [], .escape), ("\t", [], .tab), ("\t", .shift, .backTab),
    ]

    /// The keys that type nothing. They come as commands, ahead of what iOS would do with them: move the
    /// focus, or close what is on screen.
    override var keyCommands: [UIKeyCommand]? {
        Self.named.map { entry in
            let command = UIKeyCommand(input: entry.input, modifierFlags: entry.flags, action: #selector(pressed(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func pressed(_ command: UIKeyCommand) {
        if let entry = Self.named.first(where: { $0.input == command.input && $0.flags == command.modifierFlags }) { onKey?(entry.key) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = presses
        for press in presses {
            // Ctrl with a letter, as in Ctrl-C. With the Command key too it is a shortcut of the app's or of iOS.
            guard let key = press.key, key.modifierFlags.contains(.control), !key.modifierFlags.contains(.command),
                  let character = key.charactersIgnoringModifiers.first, onControl?(character) == true else { continue }
            taken = (String(character).lowercased(), ProcessInfo.processInfo.systemUptime)
            rest.remove(press)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }
}

/// Puts the key catcher in a SwiftUI view. It takes no room and draws nothing.
struct KeyCatcherHost: UIViewRepresentable {
    /// Whether it should have the keyboard now.
    let isWanted: Bool
    let onText: (String) -> Void
    let onKey: (TerminalKey) -> Void
    let onControl: (Character) -> Bool
    let onFocus: (Bool) -> Void

    func makeUIView(context: Context) -> KeyCatcher {
        let catcher = KeyCatcher()
        catcher.isAccessibilityElement = false
        return catcher
    }

    func updateUIView(_ catcher: KeyCatcher, context: Context) {
        catcher.onText = onText
        catcher.onKey = onKey
        catcher.onControl = onControl
        catcher.onFocus = onFocus
        catcher.want(isWanted)
    }

    static func dismantleUIView(_ catcher: KeyCatcher, coordinator: ()) {
        catcher.onFocus = nil
        catcher.want(false)
    }
}
