import QueenBeeCore
import SwiftUI

/// What floats over the canvas besides the bars: the map of the whole flow, the way back out of a sub-flow, the
/// message the Mac puts at the top of a flow when something didn't work, and the note an empty flow shows.

/// One choice of the canvas's own menu.
struct CanvasMenuItem: Identifiable {
    enum Kind { case map, fit, settings }
    let kind: Kind
    let title: String
    let symbol: String
    var id: String { title }
}

extension RemoteClient {
    /// What the canvas's own menu offers: the map and showing the whole flow, which change nothing on the Mac, and
    /// the flow's own settings when this device may change them. With nothing selected there are no details to
    /// reach them from, so they are here, as well as in the flow's menu in the list.
    var canvasMenu: [CanvasMenuItem] {
        guard mirror.snapshot != nil else { return [] }
        var items = [CanvasMenuItem(kind: .map, title: canvas.showsMap ? "Hide the Map" : "Show the Map", symbol: canvas.showsMap ? "map.fill" : "map"),
                     CanvasMenuItem(kind: .fit, title: "Zoom to Fit", symbol: "arrow.up.left.and.arrow.down.right")]
        if abilities.canAct { items.append(CanvasMenuItem(kind: .settings, title: "Flow Settings…", symbol: "slider.horizontal.3")) }
        return items
    }

    func choose(_ item: CanvasMenuItem.Kind) {
        switch item {
        case .map: canvas.setMap(!canvas.showsMap)
        case .fit: canvas.fit()
        case .settings: showFlowSettings()
        }
    }
}

/// The canvas's own menu, beside the run bar: the map, showing the whole flow, and the flow's settings.
struct CanvasMore: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        let items = client.canvasMenu
        if !items.isEmpty {
            Menu {
                ForEach(items) { item in
                    if item.kind == .settings { Divider() }
                    Button { client.choose(item.kind) } label: { Label(item.title, systemImage: item.symbol) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.ink.ui)
                    .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                    .contentShape(Rectangle())
            }
            .padding(Theme.Space.xs)
            .floatingPanel()
            .accessibilityLabel("Canvas")
            .accessibilityHint(client.abilities.canAct ? "Shows or hides a map of the whole flow, shows all of it on the canvas, or opens the flow's settings."
                                   : "Shows or hides a map of the whole flow, or shows all of it on the canvas.")
        }
    }
}

/// The whole flow in a corner, as the Mac's minimap has it: every card, what is live or waiting, and the part of the
/// canvas on screen. A tap or a drag on it goes there.
struct Minimap: View {
    @Environment(RemoteClient.self) private var client
    static let size = CGSize(width: 190, height: 124)

    var body: some View {
        if client.canvas.showsMap, let snapshot = client.mirror.snapshot {
            let map = MapLayout(snapshot: snapshot, visible: client.canvas.visibleRect, selected: client.canvas.selection.cardIDs)
            Canvas { context, _ in
                for card in map.cards {
                    context.fill(Path(card.rect), with: .color(card.tone.ui.opacity(card.isStrong ? 1 : 0.55)))
                    if card.isSelected {
                        context.stroke(Path(card.rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(Theme.select.ui), lineWidth: 1.5)
                    }
                }
                if let view = map.view { context.stroke(Path(view), with: .color(Theme.select.ui), lineWidth: 1) }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Theme.paper.ui)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .floatingPanel()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in client.canvas.look(at: map.point(at: drag.location)) })
            .accessibilityElement()
            .accessibilityLabel("Map of the flow")
            .accessibilityHint("The whole flow. Tap or drag on it to go to a part of it.")
            .accessibilityAction(named: "Show the whole flow") { client.canvas.fit() }
            .transition(.opacity)
        }
    }
}

/// Where each card of a flow goes on the map, and the part of the canvas on screen, worked out once so the drawing
/// and a tap agree.
nonisolated struct MapLayout {
    struct Spot {
        var rect: CGRect
        var tone: UIColor
        var isStrong: Bool
        var isSelected: Bool
    }

    var cards: [Spot] = []
    var view: CGRect?
    private var world: CGRect
    private var scale: CGFloat
    private var inset: CGSize

    @MainActor init(snapshot: RemoteFlowSnapshot, visible: CGRect, selected: Set<String>, size: CGSize = Minimap.size) {
        let flow = snapshot.flow, run = snapshot.run
        let frames = flow.cards.map(CanvasGeometry.frame(of:))
        // The map is of the flow, so the cards fill it, with the screen's outline drawn over them.
        world = (frames.isEmpty ? visible : frames.reduce(CGRect.null) { $0.union($1) }).insetBy(dx: -80, dy: -80)
        scale = world.isNull || world.width <= 0 || world.height <= 0 ? 1 : min(size.width / world.width, size.height / world.height)
        inset = CGSize(width: (size.width - world.width * scale) / 2, height: (size.height - world.height * scale) / 2)
        let waiting = Set(WaitingCard.all(in: snapshot).map(\.id))
        for card in flow.cards {
            let failed = run.marks[card.id]?.failed == true
            let live = waiting.contains(card.id) || run.holds.contains { $0.cardID == card.id }
                || (card.kind == .agent && [.working, .needsYou].contains(run.sessions[card.id] ?? .notStarted))
            let tone = failed ? Theme.failInk : live ? Theme.live : card.kind == .agent ? Theme.ink : Theme.inkSecondary
            cards.append(Spot(rect: place(CanvasGeometry.frame(of: card)), tone: tone, isStrong: failed || live, isSelected: selected.contains(card.id)))
        }
        if !visible.isEmpty { view = place(visible) }
    }

    private func place(_ rect: CGRect) -> CGRect {
        CGRect(x: inset.width + (rect.minX - world.minX) * scale, y: inset.height + (rect.minY - world.minY) * scale,
               width: max(2, rect.width * scale), height: max(2, rect.height * scale))
    }

    /// The canvas point under a point of the map.
    func point(at spot: CGPoint) -> CGPoint {
        CGPoint(x: world.minX + (spot.x - inset.width) / max(scale, 0.0001), y: world.minY + (spot.y - inset.height) / max(scale, 0.0001))
    }
}

/// The way back out of a sub-flow, to the flow whose Flow card runs it, as the Mac's breadcrumb has it.
struct BackToParent: View {
    @Environment(RemoteClient.self) private var client
    let parent: RemoteFlowSummary

    var body: some View {
        Button { client.goBackToParent() } label: {
            HStack(spacing: Theme.Space.xs + 2) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                Text("Back to \(parent.name)").dsMono(Theme.Touch.body, .medium).lineLimit(1)
            }
            .foregroundStyle(Theme.ink.ui)
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: Theme.Touch.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floatingPanel()
        .accessibilityHint("Shows the flow that runs this one.")
    }
}

/// The message the Mac shows at the top of a flow when something didn't work. With control, it can be closed here,
/// which closes it on the Mac as well.
struct FailureBanner: View {
    @Environment(RemoteClient.self) private var client
    let text: String

    var body: some View {
        let canClose = client.abilities.canAct
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .medium)).accessibilityHidden(true)
            Text(text)
                .dsSans()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canClose {
                let command = client.dismissBannerCommand()
                Button { Task { await client.dismissBanner() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(command.map(client.isSending) ?? true)
                .accessibilityLabel("Close")
                .accessibilityHint("Closes this message, on your Mac too.")
            }
        }
        .foregroundStyle(Theme.failInk.ui)
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, canClose ? 0 : Theme.Space.m)
        .padding(.vertical, canClose ? 0 : Theme.Space.s)
        .frame(minHeight: Theme.Touch.target)
        .background(Theme.failTint.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.failInk.ui, lineWidth: Theme.Stroke.card))
        .accessibilityElement(children: .contain)
    }
}

/// What an empty flow shows, as the Mac's note beside the orchestrator does: that the orchestrator builds a flow
/// from a description, with the way to start it, and the way to build it by hand.
struct CalloutView: View {
    @Environment(RemoteClient.self) private var client
    let callout: Callout

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(Callout.title).dsMono(Theme.Touch.body, .medium).accessibilityAddTraits(.isHeader)
            Text(callout.text)
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
                .fixedSize(horizontal: false, vertical: true)
            // Side by side where both fit whole, the way to start it above the other where they don't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) {
                    build
                    Spacer(minLength: 0)
                    start
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    start
                    build
                }
            }
        }
        .foregroundStyle(Theme.ink.ui)
        .padding(Theme.Space.m)
        .frame(maxWidth: 360, alignment: .leading)
        .floatingPanel()
    }

    private var build: some View {
        Button(callout.canBuild ? "Build it by hand" : "Close") { client.buildByHand() }
            .buttonStyle(.panel(.quiet))
            .fixedSize()
            .accessibilityHint(callout.canBuild ? "Puts this note away and shows the cards you can add." : "Puts this note away.")
    }

    @ViewBuilder private var start: some View {
        if let start = callout.start {
            Button("Start the orchestrator") { client.startOrchestratorFromCallout() }
                .buttonStyle(.panel(.live))
                .fixedSize()
                .disabled(!start.isEnabled)
                .accessibilityHint("Starts the session that builds and runs this flow, on your Mac, and shows it.")
        }
    }
}
