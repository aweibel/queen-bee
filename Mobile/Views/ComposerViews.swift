import QueenBeeCore
import SwiftUI

/// The bar under a session's terminal, for typing into it. It has two modes. Message is a box to write in
/// and a Send button: the Mac enters what was written when the session is ready for it. Keys is the
/// keyboard and a row of the keys a touch keyboard lacks, each sent as it is pressed.
///
/// Whether there is a bar at all is decided in `Abilities`, as `Typing`. When there is none, one quiet line
/// says why. Nothing here reads SwiftTerm or is read by it: what is typed is built into bytes by
/// `TerminalKeys` and sent as a command.
struct ComposerBar: View {
    @Environment(RemoteClient.self) private var client
    /// The session: a card's id, or the orchestrator's key.
    let key: String
    /// In the panel beside the canvas: the message box alone, with no keys.
    var isCompact = false
    @FocusState private var isWriting: Bool

    var body: some View {
        // One or the other, or nothing at all: a session whose flow has gone has nothing to say.
        Group { content }.notesFrame(isCompact ? "panel" : "viewer")
    }

    @ViewBuilder private var content: some View {
        let typing = client.abilities.typing[key] ?? Typing()
        let composer = client.composer, id = client.composerID(key)
        if typing.hasBar {
            let mode = isCompact ? ComposerModel.Mode.message : composer.mode
            VStack(alignment: .leading, spacing: 0) {
                Hairline()
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let refusal = id.flatMap({ composer.refusals[$0] }) {
                        RefusalNotice(text: refusal, alignment: .leading) { composer.dismissRefusal(id) }
                    }
                    if isCompact {
                        // The panel has no keys, so a session waiting for some is answered full screen.
                        if let note = typing.wantsKeys ? Typing.waitingInPanel : typing.note { NoteText(text: note) }
                    } else {
                        HStack(spacing: Theme.Space.m) {
                            ModeSwitch(mode: mode) { switchTo($0) }
                            NoteText(text: mode == .keys ? (typing.isAway ? Typing.away : "Each key goes to the session as you press it.") : typing.note ?? "")
                            Spacer(minLength: 0)
                            keyboardButton(mode)
                        }
                    }
                    if mode == .message {
                        MessageBox(key: key, name: name, typing: typing, isCompact: isCompact, isWriting: $isWriting)
                    } else {
                        KeysRow(key: key, isEnabled: !typing.isAway)
                    }
                }
                .padding(.horizontal, isCompact ? Theme.Space.m : Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .animation(Theme.Motion.quick, value: mode)
            }
            .background(Theme.bar.ui)
            // Keys mode can be asked for from outside: by "Open its terminal", for a session waiting in it.
            .onChange(of: composer.mode) { _, now in if now == .keys { isWriting = false } }
        } else if let line = typing.line {
            VStack(alignment: .leading, spacing: 0) {
                Hairline()
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    // Starting the session is a control like any other, and what the Mac says to it shows here too.
                    if !isCompact, let refusal = client.controls.refusal {
                        RefusalNotice(text: refusal.text, alignment: .leading) { client.controls.refusal = nil }
                    }
                    HStack(spacing: Theme.Space.m) {
                        NoteText(text: line)
                        Spacer(minLength: 0)
                        if let action = typing.action {
                            Button(action.title) { client.press(action.press) }
                                .buttonStyle(.panel())
                                .disabled(!action.isEnabled)
                                .fixedSize()
                                .accessibilityHint(action.hint)
                        }
                    }
                }
                .padding(.horizontal, isCompact ? Theme.Space.m : Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
            }
            .background(Theme.bar.ui)
        }
    }

    private var name: String {
        key == Remote.orchestratorKey ? "the orchestrator" : client.mirror.snapshot?.flow.card(key)?.name ?? "this session"
    }

    /// Changes mode and keeps the keyboard as it was: up stays up, with the new mode's keys going where they should.
    private func switchTo(_ mode: ComposerModel.Mode) {
        let composer = client.composer
        guard mode != composer.mode else { return }
        let wasUp = isWriting || composer.isCatching
        composer.mode = mode
        // Keys mode is asked for to press keys, so its keyboard comes up with it.
        composer.wantsKeyboard = mode == .keys
        isWriting = mode == .message && wasUp
    }

    /// Puts the keyboard away, and in keys mode brings it back.
    @ViewBuilder private func keyboardButton(_ mode: ComposerModel.Mode) -> some View {
        let composer = client.composer
        let isUp = mode == .keys ? composer.isCatching : isWriting
        if isUp || mode == .keys {
            Button {
                if mode == .keys { composer.wantsKeyboard = !isUp } else { isWriting = false }
            } label: {
                Image(systemName: isUp ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.ink.ui)
                    .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isUp ? "Hide the keyboard" : "Show the keyboard")
        }
    }
}

/// A quiet sentence in the bar: when a message will be delivered, or why there is nothing to type in.
private struct NoteText: View {
    let text: String

    var body: some View {
        Text(text)
            .dsSans(Theme.Touch.caption + 1)
            .foregroundStyle(Theme.inkSecondary.ui)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Message or Keys, side by side: the one in use is inked in.
private struct ModeSwitch: View {
    let mode: ComposerModel.Mode
    let pick: (ComposerModel.Mode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(.message, "Message", "text.bubble", hint: "Write a message and send it whole.")
            segment(.keys, "Keys", "keyboard", hint: "Press keys in the terminal, one at a time.")
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.ink.ui, lineWidth: Theme.Stroke.card))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How to type")
    }

    private func segment(_ which: ComposerModel.Mode, _ title: String, _ symbol: String, hint: String) -> some View {
        let isOn = which == mode
        return Button { pick(which) } label: {
            Label(title, systemImage: symbol)
                .dsMono(Theme.Touch.body, .medium)
                .lineLimit(1)
                .foregroundStyle((isOn ? Theme.surface : Theme.ink).ui)
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: Theme.Touch.target)
                .background(isOn ? Theme.ink.ui : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// The box a message is written in, and Send. The box grows to a few lines and then scrolls. What is in it
/// belongs to the session and is kept in `ComposerModel`, so it outlasts this view.
private struct MessageBox: View {
    @Environment(RemoteClient.self) private var client
    let key: String
    let name: String
    let typing: Typing
    let isCompact: Bool
    var isWriting: FocusState<Bool>.Binding

    /// The count shows once this few characters are left, and not before.
    private static let nearLimit = 1_000

    var body: some View {
        let composer = client.composer, id = client.composerID(key)
        let draft = composer.draft(id)
        let isSending = id.map(composer.sending.contains) ?? false
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField("Message \(name)", text: Binding { composer.draft(id) } set: { composer.write($0, for: id) }, axis: .vertical)
                .lineLimit(1 ... (isCompact ? 4 : 6))
                .dsSans()
                .foregroundStyle(Theme.ink.ui)
                .tint(Theme.select.ui)
                .focused(isWriting)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s + 2)
                .frame(minHeight: Theme.Touch.target)
                .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder((isWriting.wrappedValue ? Theme.select : Theme.ink).ui, lineWidth: Theme.Stroke.card))
                .accessibilityLabel("Message for \(name)")
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if draft.count > Remote.promptLimit - Self.nearLimit {
                    let isOver = draft.count > Remote.promptLimit
                    Text("\(draft.count.formatted()) of \(Remote.promptLimit.formatted())")
                        .dsMono(Theme.Touch.caption)
                        .foregroundStyle((isOver ? Theme.failInk : Theme.inkSecondary).ui)
                        .fixedSize()
                        .accessibilityLabel("\(draft.count) characters. The most is \(Remote.promptLimit).")
                }
                Button { Task { await client.sendMessage(to: key) } } label: {
                    // The word keeps its room while the Mac is answering, so the box beside it doesn't jump.
                    Label("Send", systemImage: "arrow.up")
                        .opacity(isSending ? 0 : 1)
                        .overlay { if isSending { ProgressView().tint(Theme.inkSecondary.ui) } }
                }
                .buttonStyle(.panel(.filled))
                .disabled(isSending || typing.isAway || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(isSending ? "Sending" : "Send")
                .accessibilityHint(typing.note == Typing.queued || typing.wantsKeys
                    ? "Sends your message to your Mac, which gives it to \(name) when it is ready."
                    : "Sends your message to \(name) on your Mac.")
            }
        }
    }
}

/// One key of the row beside the keyboard.
private struct ExtraKey: Identifiable {
    enum Kind { case named(TerminalKey), text(String), control }
    let id: String
    let kind: Kind
    /// What is drawn: a word, or with `symbol` a picture.
    var title = ""
    var symbol: String?
    /// What VoiceOver calls it.
    let spoken: String

    static let all: [ExtraKey] = [
        ExtraKey(id: "esc", kind: .named(.escape), title: "Esc", spoken: "Escape"),
        ExtraKey(id: "tab", kind: .named(.tab), title: "Tab", spoken: "Tab"),
        ExtraKey(id: "backtab", kind: .named(.backTab), title: "Tab", symbol: "shift", spoken: "Shift Tab"),
        ExtraKey(id: "ctrl", kind: .control, title: "Ctrl", spoken: "Control"),
        ExtraKey(id: "up", kind: .named(.up), symbol: "arrow.up", spoken: "Up arrow"),
        ExtraKey(id: "down", kind: .named(.down), symbol: "arrow.down", spoken: "Down arrow"),
        ExtraKey(id: "left", kind: .named(.left), symbol: "arrow.left", spoken: "Left arrow"),
        ExtraKey(id: "right", kind: .named(.right), symbol: "arrow.right", spoken: "Right arrow"),
        ExtraKey(id: "enter", kind: .named(.enter), title: "Enter", symbol: "return", spoken: "Enter"),
    ]
    /// What Claude Code's own questions are answered with: a numbered choice, or yes or no.
    static let answers: [ExtraKey] = ["1", "2", "3", "y", "n"].map { ExtraKey(id: $0, kind: .text($0), title: $0, spoken: $0) }
}

/// The keys a touch keyboard lacks, and the few that answer Claude Code's questions, in a row that scrolls
/// sideways where it doesn't fit. Behind the row sits the key catcher, which is what has the keyboard.
private struct KeysRow: View {
    @Environment(RemoteClient.self) private var client
    let key: String
    let isEnabled: Bool

    var body: some View {
        let composer = client.composer
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.xs + 2) {
                ForEach(ExtraKey.all) { cap($0) }
                Rectangle().fill(Theme.hairline.ui).frame(width: 1, height: 28).padding(.horizontal, Theme.Space.xs)
                    .accessibilityHidden(true)
                ForEach(ExtraKey.answers) { cap($0) }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .disabled(!isEnabled)
        .background {
            KeyCatcherHost(isWanted: composer.wantsKeyboard && isEnabled,
                           onText: { client.type($0, into: key) },
                           onKey: { client.press($0, in: key) },
                           onControl: { client.control($0, in: key) },
                           onFocus: { has in
                               composer.isCatching = has
                               // Put away by the person, with the keyboard's own key or a drag.
                               if !has { composer.wantsKeyboard = false }
                           })
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keys")
    }

    @ViewBuilder private func cap(_ extra: ExtraKey) -> some View {
        let composer = client.composer
        switch extra.kind {
        case .control:
            let isHeld = composer.typer.isControlHeld
            Button { composer.toggleControl() } label: { KeyCap(extra: extra, isHeld: isHeld) }
                .buttonStyle(KeyCapStyle())
                .accessibilityLabel(extra.spoken)
                .accessibilityValue(isHeld ? "On" : "Off")
                .accessibilityHint("Goes with the next key you press, as in Control C.")
        case .named(let named):
            let isArrow = [.up, .down, .left, .right].contains(named)
            Button { client.press(named, in: key) } label: { KeyCap(extra: extra) }
                .buttonStyle(KeyCapStyle())
                // An arrow held down goes on moving, as on a keyboard.
                .buttonRepeatBehavior(isArrow ? .enabled : .disabled)
                .accessibilityLabel(extra.spoken)
        case .text(let text):
            Button { client.type(text, into: key) } label: { KeyCap(extra: extra) }
                .buttonStyle(KeyCapStyle())
                .accessibilityLabel(extra.spoken)
        }
    }
}

/// How one key is drawn: a cap as tall and at least as wide as a finger needs.
private struct KeyCap: View {
    let extra: ExtraKey
    var isHeld = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if let symbol = extra.symbol { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
            if !extra.title.isEmpty { Text(extra.title) }
        }
        .dsMono(Theme.Touch.body, .medium)
        .lineLimit(1)
        .foregroundStyle((isHeld ? Theme.surface : isEnabled ? Theme.ink : Theme.inkSecondary.withAlphaComponent(0.55)).ui)
        .padding(.horizontal, Theme.Space.s)
        .frame(minWidth: Theme.Touch.target, minHeight: Theme.Touch.target)
        .background((isHeld ? Theme.select : Theme.surface).ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder((isHeld ? Theme.select : isEnabled ? Theme.ink : Theme.hairline).ui, lineWidth: Theme.Stroke.card))
        .contentShape(Rectangle())
    }
}

private struct KeyCapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

extension View {
    /// In a build for testing, says where a bar is on screen, for a test that can't see it. Nothing otherwise.
    @ViewBuilder fileprivate func notesFrame(_ name: String) -> some View {
        #if DEBUG
        modifier(FrameNote(name: name))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct FrameNote: ViewModifier {
    @Environment(RemoteClient.self) private var client
    let name: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { client.composer.debugFrames[name] = $0.height > 0 ? $0 : nil }
            .onDisappear { client.composer.debugFrames[name] = nil }
    }
}
#endif
