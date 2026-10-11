import QueenBeeCore
import SwiftUI

/// The details page: the selected card, link or group, or the flow when nothing is selected.
struct DetailsPage: View {
    @Environment(RemoteClient.self) private var client
    let snapshot: RemoteFlowSnapshot
    let run: RunOnShow

    var body: some View {
        ScrollView {
            let siblings = client.openFlow?.project.flows ?? []
            if let details = Details(selection: client.canvas.selection, snapshot: snapshot, run: run, siblings: siblings) {
                DetailsView(details: details, card: client.canvas.selection.cardID.flatMap(snapshot.flow.card),
                            flow: snapshot.flow, run: run, abilities: client.abilities)
                    // A fresh view for each thing selected, so one card's opened-up text isn't left open on the next.
                    .id(client.canvas.selection)
            } else {
                overview
                    .padding(Theme.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
        }
    }
}

/// One card, link or group: a header that names it, then what it is set to, as the Mac's settings panel has
/// it. Nothing it is set to can be changed here, and the last line says where it can. What a run is waiting
/// on can be answered here, and a run started at the card, when this device may control the Mac.
private struct DetailsView: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(details.items.enumerated()), id: \.offset) { _, item in
                Hairline()
                ItemView(item: item, answerLine: details.answerLine ? abilities.answerLine ?? WaitingCard.answer : nil,
                         hold: hold, buttons: hold.flatMap { abilities.cards[$0.cardID] } ?? [])
            }
            if let messages = details.messages {
                Hairline()
                MessageList(title: details.messagesTitle, messages: messages)
            }
            if let card, abilities.canAct {
                let start = card.kind == .agent ? abilities.details[card.id] ?? [] : []
                if !start.isEmpty || abilities.runFrom.contains(card.id) {
                    Hairline()
                    CardActions(card: card, buttons: start, canRunFrom: abilities.runFrom.contains(card.id),
                                // The Mac's `lastMessage(into:)`: what "Run from here" starts with.
                                lastMessage: flow.links(into: card.id).compactMap { run.messages[$0.id]?.last }.max { $0.date < $1.date }?.text ?? "")
                }
            }
            Hairline()
            Text(Details.changes)
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: details.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink.ui)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(details.title)
                .dsMono(Theme.Touch.title, .medium)
                .foregroundStyle(Theme.ink.ui)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.s)
            if let state = details.state {
                Badge(text: state.label.lowercased(), tone: state.tone)
            } else {
                Text(details.kind).dsMono(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
        .background(Theme.bar.ui)
        .accessibilityElement(children: .combine)
    }
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
private struct ItemView: View {
    let item: DetailItem
    /// Said under what is waiting, when it can't be answered here.
    let answerLine: String?
    /// The held message this card is waiting with, and the buttons that answer it, when it can be answered here.
    var hold: PendingHold?
    var buttons: [PressButton] = []

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
        case .warning:
            Label(item.label, systemImage: "exclamationmark.triangle")
                .dsSans(Theme.Touch.body, .medium)
                .foregroundStyle(Theme.failInk.ui)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
        case .stopped:
            Text(item.label)
                .dsSans(Theme.Touch.body, .medium)
                .foregroundStyle(Theme.failInk.ui)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
                .background(Theme.failTint.ui)
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
private struct MessageList: View {
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
