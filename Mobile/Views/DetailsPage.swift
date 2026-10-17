import QueenBeeCore
import SwiftUI

/// The details page: the selected card, link or group, or the flow when nothing is selected. With editing
/// on, what is selected has its settings open to change. Editing is the canvas's own mode, so one switch
/// governs all of it, and the foot of the page says which way it is set.
struct DetailsPage: View {
    @Environment(RemoteClient.self) private var client
    let snapshot: RemoteFlowSnapshot
    let run: RunOnShow
    /// The setting the keyboard is in.
    @FocusState private var focus: FieldFocus?

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                let siblings = client.openFlow?.project.flows ?? []
                let card = client.canvas.selection.cardID.flatMap(snapshot.flow.card)
                if let form = client.editForm {
                    EditDetails(form: form, card: card, flow: snapshot.flow, run: run, abilities: client.abilities, focus: $focus)
                        .id(client.canvas.selection)
                } else if let details = Details(selection: client.canvas.selection, snapshot: snapshot, run: run, siblings: siblings,
                                                roles: client.mirror.library?.roles ?? []) {
                    DetailsView(details: details, card: card, flow: snapshot.flow, run: run, abilities: client.abilities)
                        // A fresh view for each thing selected, so one card's opened-up text isn't left open on the next.
                        .id(client.canvas.selection)
                } else {
                    overview
                        .padding(Theme.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // The box being written in is kept clear of the keyboard and of the foot of the page.
            .onChange(of: focus) { _, new in
                guard let new else { return }
                withAnimation(Theme.Motion.standard) { scroll.scrollTo(new, anchor: .center) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { EditFoot(focus: $focus) }
        .onChange(of: focus) { old, new in client.focusMoved(from: old?.key, to: new?.key) }
        // What was written for the thing that was selected is sent before the next thing's settings come up.
        .onChange(of: client.canvas.selection) {
            focus = nil
            client.flushFields()
        }
        .onChange(of: client.isEditing) { _, isEditing in
            if !isEditing { focus = nil }
        }
        .onDisappear { client.flushFields() }
        #if DEBUG
        // A test can't tap a box. With `-qbFocus <setting>` the keyboard is put in that setting's box once it is on show.
        .task(id: client.canvas.selection) {
            guard let wanted = DebugLaunch.focus else { return }
            for _ in 0..<40 {
                if let key = client.editForm?.fields.first(where: { $0.key.name.rawValue == wanted })?.key {
                    try? await Task.sleep(for: .milliseconds(600))
                    focus = FieldFocus(key: key)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        #endif
    }

    /// Nothing selected: the flow itself.
    private var overview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            PanelSection(title: "Flow") {
                PanelRow(label: "Name", value: snapshot.flow.name)
                if let project = client.openFlow?.project.name {
                    Hairline()
                    PanelRow(label: "Project", value: project)
                }
                Hairline()
                PanelRow(label: "Cards", value: "\(snapshot.flow.cards.count)")
            }
            Text("Tap a card or a link on the canvas to see what it is set to.")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
            if client.abilities.canAct {
                Button { client.showFlowSettings() } label: { Label("Flow Settings…", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.panel())
                    .accessibilityHint("Renames the flow, and sets how deep its sub-flows go and whether the orchestrator is told when a run ends.")
            }
        }
    }
}

/// One card, link or group: a header that names it, then what it is set to, as the Mac's settings panel has
/// it. Nothing it is set to can be changed here: that is `EditDetails`, once Edit is pressed. For a device
/// that may only watch, the last line says where changes are made. What a run is waiting on can be answered
/// here, and a run started at the card, when this device may control the Mac.
private struct DetailsView: View {
    @Environment(RemoteClient.self) private var client
    let details: Details
    /// The card, when it is a card that is selected.
    let card: Card?
    let flow: Flow
    let run: RunOnShow
    let abilities: Abilities

    /// The message held at this card, when it is one this device may answer.
    private var hold: PendingHold? {
        guard let card, abilities.cards[card.id] != nil else { return nil }
        return run.holds.first { $0.cardID == card.id && ($0.kind == .approval || $0.needsAllow) }
    }

    /// The card, when it is an agent waiting in its terminal and this device may open that and answer.
    private var inTerminal: Card? {
        guard let card, abilities.inTerminal.contains(card.id), client.terminals.sizes[card.id] != nil else { return nil }
        return card
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(details.items.enumerated()), id: \.offset) { _, item in
                Hairline()
                ItemView(item: item, answerLine: details.answerLine ? abilities.answerLine ?? WaitingCard.answer : nil,
                         hold: hold, buttons: hold.flatMap { abilities.cards[$0.cardID] } ?? [], inTerminal: inTerminal,
                         retry: card.flatMap { abilities.retry[$0.id] })
            }
            if let messages = details.messages {
                Hairline()
                MessageList(title: details.messagesTitle, messages: messages)
            }
            if let card {
                // A Start card's schedule turned on or off, and the flow a Flow card runs, to go and look at.
                if card.kind == .start, card.trigger != nil, abilities.canAct {
                    Hairline()
                    ScheduleSwitch(cardID: card.id, isOn: client.mirror.snapshot?.edit.armed.contains(card.id) == true)
                }
                if card.kind == .flow, let inner = client.innerFlow(of: card.id) {
                    Hairline()
                    SubflowRow(cardID: card.id, inner: inner)
                }
            }
            if let card, abilities.canAct {
                let start = CardActions.buttons(for: card, in: abilities)
                if !start.isEmpty || abilities.runFrom.contains(card.id) {
                    Hairline()
                    CardActions(card: card, buttons: start, canRunFrom: abilities.runFrom.contains(card.id),
                                // The Mac's `lastMessage(into:)`: what "Run from here" starts with.
                                lastMessage: flow.links(into: card.id).compactMap { run.messages[$0.id]?.last }.max { $0.date < $1.date }?.text ?? "")
                }
            }
            // A device that may control the Mac is told how at the foot of the page, where Edit is.
            if !abilities.canAct {
                Hairline()
                Text(Details.changes)
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
            }
        }
    }

    private var header: some View { DetailsHeader(icon: details.icon, title: details.title, kind: details.kind, state: details.state) }
}

extension SessionState {
    /// The tint a session's state is written in, wherever it is written.
    var tone: Badge.Tone {
        switch self {
        case .working, .needsYou: .live
        case .failed, .exited: .fail
        case .idle, .notStarted, .starting: .plain
        }
    }
}

/// One line of the details, drawn for what kind of line it is.
struct ItemView: View {
    let item: DetailItem
    /// Said under what is waiting, when it can't be answered here.
    let answerLine: String?
    /// The held message this card is waiting with, and the buttons that answer it, when it can be answered here.
    var hold: PendingHold?
    var buttons: [PressButton] = []
    /// The agent this is about, when it is waiting in its terminal and that can be opened and answered here.
    var inTerminal: Card?
    /// Retry, beside "The run stopped here.", when this device may give the card its message again.
    var retry: PressButton?

    var body: some View {
        switch item.style {
        case .row:
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(item.label).dsSans().foregroundStyle(Theme.inkSecondary.ui)
                Spacer(minLength: Theme.Space.s)
                Text(item.value).dsMono(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .frame(minHeight: Theme.Touch.target)
            .accessibilityElement(children: .combine)
        case .text, .code:
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(item.label).dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
                LongText(text: item.value, isMono: item.style == .code).foregroundStyle(Theme.ink.ui).fieldBox()
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        case .note:
            Text(item.label)
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
        case .caution:
            Label(item.label, systemImage: "exclamationmark.circle")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.liveInk.ui)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
                .background(Theme.liveTint.ui)
        case .warning:
            Label(item.label, systemImage: "exclamationmark.triangle")
                .dsSans(Theme.Touch.body, .medium)
                .foregroundStyle(Theme.failInk.ui)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
        case .stopped:
            HStack(spacing: Theme.Space.s) {
                Text(item.label)
                    .dsSans(Theme.Touch.body, .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let retry { PressButtons(buttons: [retry]).fixedSize() }
            }
            .foregroundStyle(Theme.failInk.ui)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.failTint.ui)
        case .pending:
            Label(item.label, systemImage: "clock.arrow.circlepath")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.liveInk.ui)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
                .background(Theme.liveTint.ui)
        case .waiting:
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(item.label)
                    .dsSans(Theme.Touch.body, .medium)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.value.isEmpty {
                    LongText(text: item.value, isMono: item.isCode)
                        .foregroundStyle(Theme.ink.ui)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
                        .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.live.ui))
                }
                if let hold, !buttons.isEmpty {
                    HoldAnswer(hold: hold, buttons: buttons)
                } else if let inTerminal {
                    OpenTerminalButton(cardID: inTerminal.id, name: inTerminal.name)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else if let answerLine {
                    Text(answerLine).dsSans(Theme.Touch.caption + 1).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Theme.liveInk.ui)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.liveTint.ui)
        }
    }
}

/// Text that may run long: instructions, a message, an answer. It can be selected and copied. Past a few
/// lines it is cut short, with a button to read all of it.
struct LongText: View {
    let text: String
    var isMono = false
    /// How many lines show before it is cut short.
    var lines = 8
    @State private var isOpen = false

    /// A guess, made from the text alone: how it wraps isn't known until it is drawn.
    private var isLong: Bool {
        text.count > lines * 36 || text.split(separator: "\n", omittingEmptySubsequences: false).count > lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isMono { Text(text).dsMono(Theme.Touch.caption + 1) } else { Text(text).dsSans() }
            }
            .lineLimit(isLong && !isOpen ? lines : nil)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if isLong {
                Button(isOpen ? "Show less" : "Show all") { isOpen.toggle() }
                    .buttonStyle(.panel(.quiet))
                    .padding(.leading, -Theme.Space.s)
                    .accessibilityHint(isOpen ? "Cuts the text short again." : "Shows the whole text.")
            }
        }
    }
}

/// What a link carried in the run on show, oldest first, so it reads down the page in the order it happened.
struct MessageList: View {
    let title: String
    let messages: [LinkMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
                .accessibilityAddTraits(.isHeader)
            if messages.isEmpty {
                Text("Nothing has gone along this link in the run on show.")
                    .dsSans()
                    .foregroundStyle(Theme.inkSecondary.ui)
            }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("\(Clock.time(message.date)) · from \(message.from)")
                        .dsMono(Theme.Touch.caption)
                        .foregroundStyle(Theme.inkSecondary.ui)
                    LongText(text: message.text, lines: 6).foregroundStyle(Theme.ink.ui)
                }
                .fieldBox()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }
}
