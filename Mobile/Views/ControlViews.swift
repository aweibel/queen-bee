import QueenBeeCore
import SwiftUI

/// The controls this device has when the Mac lets it do more than watch: the run bar, the buttons that
/// answer what a run is waiting on, and the questions asked before anything that stops work or runs a
/// command. What is on offer is decided in one place, `Abilities`. Nothing here decides it again.

/// A row of buttons that each ask the Mac for one thing. The same buttons are on the card, in the banner
/// and in the details, so they are drawn from the same values everywhere.
struct PressButtons: View {
    @Environment(RemoteClient.self) private var client
    let buttons: [PressButton]
    /// The card they are about, for VoiceOver, which hears each button by itself.
    var about = ""

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(buttons) { button in
                Button(button.title) { client.press(button.press) }
                    .buttonStyle(.panel(button.isMain ? .live : .outline))
                    .disabled(!button.isEnabled)
                    .accessibilityLabel(about.isEmpty ? button.title : "\(button.title), \(about)")
                    .accessibilityHint(button.hint)
            }
        }
    }
}

/// What floats over the foot of the canvas, and the one place its order is set: a refusal on top, since it
/// is about what was just pressed, then the run bar and the connection strip. Side by side where there is
/// room, the connection at the left as before and the run bar at the right, under the thumb. One above the
/// other where there isn't. The canvas is told how tall all of it is, and fits the flow clear of it. The
/// banners are at the canvas's top, so nothing here can meet them.
struct CanvasFoot: View {
    @Environment(RemoteClient.self) private var client
    let showSettings: () -> Void

    var body: some View {
        let abilities = client.abilities
        VStack(alignment: .trailing, spacing: Theme.Space.s) {
            if let refusal = client.controls.refusal {
                RefusalNotice(text: refusal.text) { client.controls.refusal = nil }
                    .transition(.opacity)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: Theme.Space.m) {
                    ConnectionBar(showSettings: showSettings)
                    Spacer(minLength: 0)
                    RunBar(abilities: abilities)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    RunBar(abilities: abilities)
                    ConnectionBar(showSettings: showSettings)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(Theme.Motion.standard, value: client.controls.refusal)
    }
}

/// Run and Stop, as the Mac's toolbar has them: Run when nothing is going, Stop while a run is. The Mac's
/// Run takes no words of its own, and neither does this one: a run starts with what its Start card says.
/// When this device may only watch, one line here says how to change that, and there are no buttons.
struct RunBar: View {
    @Environment(RemoteClient.self) private var client
    let abilities: Abilities

    var body: some View {
        if let hint = abilities.hint {
            Text(hint)
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300, alignment: .leading)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(minHeight: Theme.Touch.target)
                .floatingPanel()
        } else if !abilities.bar.isEmpty {
            HStack(spacing: Theme.Space.s) {
                if let note = abilities.barNote {
                    Text(note)
                        .dsSans(Theme.Touch.caption + 1)
                        .foregroundStyle(Theme.inkSecondary.ui)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 240, alignment: .leading)
                        .padding(.leading, Theme.Space.s)
                }
                ForEach(abilities.bar) { button in
                    Button { client.press(button.press) } label: {
                        switch button.press {
                        case .run: Label(button.title, systemImage: "play.fill")
                        case .stop: Label(button.title, systemImage: "stop.fill")
                        default: Text(button.title)
                        }
                    }
                    .buttonStyle(.panel(button.press == .run ? .run : button.press == .stop ? .stop : .outline))
                    .disabled(!button.isEnabled)
                    .accessibilityHint(button.hint)
                }
            }
            .padding(Theme.Space.xs)
            .floatingPanel()
        }
    }
}

/// Something the Mac wouldn't do, in its own words. A tap puts it away, and so does the next thing that works.
struct RefusalNotice: View {
    let text: String
    /// Which side it keeps to where there is more room than it needs.
    var alignment = Alignment.trailing
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(text)
                    .dsSans()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(Theme.failInk.ui)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(minHeight: Theme.Touch.target)
            .background(Theme.failTint.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.failInk.ui, lineWidth: Theme.Stroke.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 420, alignment: alignment)
        .accessibilityHint("Puts this message away.")
    }
}

/// The answer to a held message, under the message in a card's details: the card's own buttons, and for an
/// approval the Mac's way of changing the message before it is sent on.
struct HoldAnswer: View {
    @Environment(RemoteClient.self) private var client
    let hold: PendingHold
    let buttons: [PressButton]
    /// The message as the person is rewriting it. Nil until they ask to.
    @State private var draft: String?

    var body: some View {
        if hold.kind == .approval {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let draft {
                    TextEditor(text: Binding { draft } set: { self.draft = $0 })
                        .dsSans()
                        .foregroundStyle(Theme.ink.ui)
                        .scrollContentBackground(.hidden)
                        .frame(height: 160)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.xs)
                        .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.live.ui))
                        .accessibilityLabel("The message to send on")
                }
                HStack(spacing: Theme.Space.s) {
                    ForEach(buttons.filter { !$0.isMain }) { button in
                        Button(button.title) { client.press(button.press) }
                            .buttonStyle(.panel())
                            .disabled(!button.isEnabled)
                            .accessibilityHint(button.hint)
                    }
                    Spacer(minLength: 0)
                    Button(draft == nil ? "Edit" : "Don't edit") { draft = draft == nil ? hold.text : nil }
                        .buttonStyle(.panel(.quiet))
                        .accessibilityHint(draft == nil ? "Lets you change the message before approving it." : "Puts the message back as it was.")
                    let edited = draft.map { $0 != hold.text } ?? false
                    Button(edited ? "Approve edited" : "Approve") { client.press(.approve(holdID: hold.id, text: draft ?? hold.text)) }
                        .buttonStyle(.panel(.live))
                        .disabled(buttons.contains { !$0.isEnabled })
                        .accessibilityHint("Sends the message on along the Approved link.")
                }
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                ForEach(buttons) { button in
                    if button.isMain { Spacer(minLength: 0) }
                    Button(button.title) { client.press(button.press) }
                        .buttonStyle(.panel(button.isMain ? .live : .outline))
                        .disabled(!button.isEnabled)
                        .accessibilityHint(button.hint)
                }
            }
        }
    }
}

/// What can be done to the selected card from here: start or restart its agent, and start a run at it.
struct CardActions: View {
    @Environment(RemoteClient.self) private var client
    let card: Card
    let buttons: [PressButton]
    let canRunFrom: Bool
    /// The last message that reached the card in the run on show, which "Run from here" starts with.
    let lastMessage: String
    /// The message the run will start with. Nil until "Run from here…" is pressed.
    @State private var draft: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let draft {
                Text("The message \(card.name) gets").dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
                TextEditor(text: Binding { draft } set: { self.draft = $0 })
                    .dsSans()
                    .foregroundStyle(Theme.ink.ui)
                    .scrollContentBackground(.hidden)
                    .frame(height: 120)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, Theme.Space.xs)
                    .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
                    .accessibilityLabel("The message \(card.name) gets")
                HStack(spacing: Theme.Space.s) {
                    Button("Cancel") { self.draft = nil }.buttonStyle(.panel(.quiet))
                    Spacer(minLength: 0)
                    Button("Run from here") {
                        self.draft = nil
                        Task { await client.run(from: card.id, text: draft) }
                    }
                    .buttonStyle(.panel(.filled))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Starts a run on your Mac at this card, skipping everything that comes before.")
                }
            } else {
                let runFrom = Button("Run from here…") { draft = lastMessage }
                    .buttonStyle(.panel(.quiet))
                    .fixedSize()
                    .accessibilityHint("Starts a run at this card with a message you give it, skipping everything that comes before.")
                // Side by side where both names fit whole, and one above the other where they don't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.s) {
                        if canRunFrom { runFrom }
                        Spacer(minLength: 0)
                        PressButtons(buttons: buttons, about: card.name).fixedSize()
                    }
                    VStack(alignment: .trailing, spacing: Theme.Space.s) {
                        PressButtons(buttons: buttons, about: card.name)
                        if canRunFrom { runFrom }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }
}

/// Turning a held message down: what it says, and room for a few words on why. The note is the Mac's:
/// it goes out ahead of the message along the Rejected link, and may be left empty.
private struct RejectSheet: View {
    @Environment(RemoteClient.self) private var client
    let ask: Ask
    let name: String
    let from: String
    let text: String
    @State private var note = ""

    var body: some View {
        AskSheet(title: "Reject this message?") {
            Text("From \(from), held at \(name)").dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
            LongText(text: text, lines: 6).foregroundStyle(Theme.ink.ui).fieldBox()
            TextField("Why you're rejecting it (optional)", text: $note, axis: .vertical)
                .lineLimit(2...5)
                .dsSans()
                .foregroundStyle(Theme.ink.ui)
                .fieldBox()
            Text("The message goes on along the Rejected link, with your reason ahead of it if you give one.")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
                .fixedSize(horizontal: false, vertical: true)
        } action: {
            Button("Reject") { client.confirm(ask, note: note) }.buttonStyle(.panel(.filled))
        }
    }
}

/// Letting a script's command run: the whole command first, and that it runs on the Mac.
private struct AllowSheet: View {
    @Environment(RemoteClient.self) private var client
    let ask: Ask
    let name: String
    let command: String

    var body: some View {
        AskSheet(title: "Allow \(name) to run this?") {
            Text("This command will run on your Mac, in the project's folder, as if you had typed it in Terminal. Read all of it first.")
                .dsSans()
                .foregroundStyle(Theme.ink.ui)
                .fixedSize(horizontal: false, vertical: true)
            // All of it, however long: nothing is cut short behind a button here.
            Text(command)
                .dsMono(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.ink.ui)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fieldBox()
                .accessibilityLabel("The command: \(command)")
            Text("This card won't ask again unless the command changes.")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
                .fixedSize(horizontal: false, vertical: true)
        } action: {
            Button("Allow and run") { client.confirm(ask) }.buttonStyle(.panel(.live))
        }
    }
}

/// The frame of a question asked in a sheet: what is being asked, what to read, and Cancel beside the answer.
private struct AskSheet<Content: View, Action: View>: View {
    @Environment(RemoteClient.self) private var client
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var action: Action

    var body: some View {
        let asked = VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title)
                .dsMono(Theme.Touch.title, .medium)
                .foregroundStyle(Theme.ink.ui)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        VStack(spacing: 0) {
            // As tall as what it asks, and no taller. Only something too long for the screen scrolls.
            ViewThatFits(in: .vertical) {
                asked
                ScrollView { asked }
            }
            Hairline()
            HStack(spacing: Theme.Space.s) {
                Button("Cancel") { client.controls.asking = nil }.buttonStyle(.panel(.quiet))
                Spacer(minLength: 0)
                action
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.bar.ui)
        }
        .background(Theme.surface.ui)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    }
}

private struct AsksBeforeActing: ViewModifier {
    @Environment(RemoteClient.self) private var client

    /// What is being asked, if it is asked the way this binding is for: in a sheet, or in an alert.
    private func asking(sheet: Bool) -> Binding<Ask?> {
        Binding {
            client.controls.asking.flatMap { $0.isSheet == sheet ? $0 : nil }
        } set: { new in
            if new == nil, client.controls.asking?.isSheet == sheet { client.controls.asking = nil }
        }
    }

    func body(content: Content) -> some View {
        let alert = asking(sheet: false)
        content
            .sheet(item: asking(sheet: true)) { ask in
                switch ask {
                case .reject(_, let name, let from, let text): RejectSheet(ask: ask, name: name, from: from, text: text)
                case .allow(_, let name, let command): AllowSheet(ask: ask, name: name, command: command)
                case .stop, .restart: EmptyView()
                }
            }
            .alert(alertTitle, isPresented: Binding { alert.wrappedValue != nil } set: { if !$0 { alert.wrappedValue = nil } },
                   presenting: alert.wrappedValue) { ask in
                switch ask {
                case .stop: Button("Stop", role: .destructive) { client.confirm(ask) }
                default: Button("Restart agent") { client.confirm(ask) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { ask in
                switch ask {
                case .stop: Text("The run on your Mac stops where it is.")
                case .restart(_, _, let isWorking):
                    Text(isWorking ? "Restarting interrupts what the agent is doing now. It keeps its conversation so far." : "The agent keeps its conversation so far.")
                default: Text("")
                }
            }
            // What was being asked about may have gone while the question was up: answered on the Mac, or the link dropped.
            .onChange(of: client.abilities) { _, now in
                if let ask = client.controls.asking, !now.stillOffers(ask) { client.controls.asking = nil }
            }
    }

    private var alertTitle: String {
        switch client.controls.asking {
        case .restart(_, let name, _): "Restart \(name)?"
        default: "Stop the run?"
        }
    }
}

extension Abilities {
    /// Whether what a question is about can still be done.
    func stillOffers(_ ask: Ask) -> Bool {
        let presses = (bar + cards.values.joined() + details.values.joined()).map(\.press)
        return switch ask {
        case .stop: presses.contains(.stop)
        case .restart(let cardID, _, _): presses.contains(.startAgent(cardID: cardID))
        case .allow(let holdID, _, _): presses.contains(.allow(holdID: holdID))
        case .reject(let holdID, _, _, _): presses.contains(.reject(holdID: holdID))
        }
    }
}

extension View {
    /// Puts up the questions that are asked before a press is sent: stopping a run, restarting an agent
    /// that is running, letting a command run, and the note that goes with a rejection.
    func asksBeforeActing() -> some View { modifier(AsksBeforeActing()) }
}
