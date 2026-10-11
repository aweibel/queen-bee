import QueenBeeCore
import SwiftUI

/// What floats over the top of the canvas when there is something to say about the flow as a whole: which
/// cards are waiting on the person, and that an earlier run is on show. Nothing is there when neither is true.
struct CanvasBanners: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let snapshot = client.mirror.snapshot {
                let waiting = WaitingCard.all(in: snapshot)
                if !waiting.isEmpty { NeedsYouBanner(waiting: waiting) }
                if let run = client.canvas.viewedRun {
                    EarlierRunNotice(run: run)
                        .padding(.horizontal, Theme.Space.m)
                        .floatingPanel()
                }
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
    }
}

/// The cards waiting on the person, in canvas order. Tapping one goes to it. When this device may answer,
/// each has its card's buttons under it, at full size however small the card is on screen. What can't be
/// answered from here is said in the last line.
private struct NeedsYouBanner: View {
    @Environment(RemoteClient.self) private var client
    let waiting: [WaitingCard]
    /// More than this many and the rest are counted, so the banner never covers the canvas it points at.
    private static let most = 4

    var body: some View {
        let abilities = client.abilities
        VStack(alignment: .leading, spacing: 0) {
            Label(waiting.count == 1 ? "1 needs you" : "\(waiting.count) need you", systemImage: "hand.raised")
                .dsMono(Theme.Touch.body, .medium)
                .foregroundStyle(Theme.liveInk.ui)
                .padding(.horizontal, Theme.Space.m)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(Theme.liveTint.ui)
                .accessibilityAddTraits(.isHeader)
            ForEach(waiting.prefix(Self.most)) { card in
                Hairline()
                Button { client.go(to: card) } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: CanvasGeometry.icon(for: card.kind))
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name).dsMono(Theme.Touch.body, .medium).lineLimit(1)
                            Text(card.reason).dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.inkSecondary.ui)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Image(systemName: "scope").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.inkSecondary.ui)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Theme.ink.ui)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.xs + 2)
                    .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(card.name). \(card.reason).")
                .accessibilityHint("Goes to this card on the canvas.")
                if let buttons = abilities.cards[card.id] {
                    PressButtons(buttons: buttons, about: card.name)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.bottom, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            let more = waiting.count > Self.most ? "And \(waiting.count - Self.most) more." : nil
            let last = [more, abilities.answerLine].compactMap { $0 }.joined(separator: " ")
            if !last.isEmpty {
                Hairline()
                Text(last)
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .floatingPanel()
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.live.ui, lineWidth: Theme.Stroke.card))
    }

}

extension RemoteClient {
    /// Goes to a card that is waiting: puts it in the middle of the canvas, selects it, and turns the panel
    /// to its details, where what it is waiting with can be read.
    func go(to card: WaitingCard) {
        canvas.select(.card(card.id))
        canvas.centre(onCard: card.id)
        panel.show(PanelPage.details)
    }
}
