import QueenBeeCore
import SwiftUI

/// What the run on show did, step by step, newest at the bottom. It follows new lines as they arrive until
/// the person scrolls up to read, and follows again once they are back at the bottom.
struct LogPage: View {
    @Environment(RemoteClient.self) private var client
    let lines: [LogLine]
    /// The Mac's Clear is on offer: this device may act, the latest run is on show, and there is something to clear.
    var canClear = false
    @State private var follows = true
    @State private var asksToClear = false

    var body: some View {
        VStack(spacing: 0) {
            if canClear {
                let command = client.clearLogCommand()
                HStack(spacing: Theme.Space.s) {
                    Text("\(lines.count) \(lines.count == 1 ? "line" : "lines")").dsSans(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui)
                    Spacer(minLength: Theme.Space.s)
                    Button("Clear") { asksToClear = true }
                        .buttonStyle(.panel(.quiet))
                        .disabled(command.map(client.isSending) ?? true)
                        .accessibilityHint("Asks first, then clears the log and the list of earlier runs on your Mac.")
                }
                .padding(.leading, Theme.Space.l)
                .padding(.trailing, Theme.Space.s)
                Hairline()
            }
            list(lines)
        }
        .confirmationDialog("Clear the log?", isPresented: $asksToClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await client.clearLog() } }
        } message: {
            Text("The log and the list of earlier runs are emptied on your Mac. This can't be undone.")
        }
    }

    private func list(_ lines: [LogLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                    if lines.isEmpty {
                        Text("What each run did shows here, step by step: who passed what to whom, which way each decision went, and why a run stopped.")
                            .dsSans()
                            .foregroundStyle(Theme.inkSecondary.ui)
                    }
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text(Clock.time(line.date)).foregroundStyle(Theme.inkSecondary.ui)
                            Text(line.text)
                                .foregroundStyle(Theme.ink.ui)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .dsSans(Theme.Touch.caption + 1)
                        .accessibilityElement(children: .combine)
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.l)
            }
            // A long log opens at its newest line. A short one starts at the top of the page, as a list does.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            // Only a finger changes whether the log follows: a new line makes the page longer, which is not
            // the person scrolling away from the end.
            .onScrollPhaseChange { old, new, context in
                guard new == .idle, old != .idle, old != .animating else { return }
                let now = context.geometry
                follows = now.contentOffset.y + now.containerSize.height >= now.contentSize.height - 40
            }
            // By the last line, not the count: a full log stays the same length as it turns over.
            .onChange(of: lines.last?.id) {
                if follows, let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !follows, let last = lines.last {
                    Button {
                        follows = true
                        withAnimation(Theme.Motion.standard) { proxy.scrollTo(last.id, anchor: .bottom) }
                    } label: {
                        Label("Newest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.panel(.filled))
                    .padding(Theme.Space.m)
                    .accessibilityHint("Goes to the newest line and follows the log again.")
                }
            }
            .animation(Theme.Motion.standard, value: follows)
        }
    }
}

/// Each End card's answer in the run on show, under the card's name.
struct OutputPage: View {
    let flow: Flow
    let results: [String: String]

    var body: some View {
        let ends = flow.cards.filter { $0.kind == .end }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if ends.isEmpty {
                    Text("This flow has no End card. An End card collects a run's final answer, and it would show here.")
                        .dsSans()
                        .foregroundStyle(Theme.inkSecondary.ui)
                }
                ForEach(ends) { card in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Image(systemName: CanvasGeometry.icon(for: .end))
                                .font(.system(size: 13, weight: .medium))
                                .accessibilityHidden(true)
                            Text(card.name).dsSans(Theme.Touch.body, .medium).accessibilityAddTraits(.isHeader)
                            Spacer(minLength: Theme.Space.s)
                            if let file = card.saveTo, !file.isEmpty, results[card.id] != nil {
                                Text(file)
                                    .dsSans(Theme.Touch.caption)
                                    .foregroundStyle(Theme.inkSecondary.ui)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .accessibilityLabel("Saved on your Mac as \(file)")
                            }
                        }
                        .foregroundStyle(Theme.ink.ui)
                        if let text = results[card.id] {
                            LongText(text: text, lines: 14).foregroundStyle(Theme.ink.ui).fieldBox()
                        } else {
                            Text("Nothing yet. This fills in when a run reaches the card.")
                                .dsSans()
                                .foregroundStyle(Theme.inkSecondary.ui)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
        }
    }
}

/// The runs the Mac has kept, newest first. Picking one puts it on this device's canvas and panels, as the
/// Mac's "Earlier run" menu does there. Nothing is sent to the Mac.
struct RunsPage: View {
    @Environment(RemoteClient.self) private var client
    let snapshot: RemoteFlowSnapshot

    var body: some View {
        let rows = RunRow.all(in: snapshot, viewed: client.canvas.viewedRun)
        let isRunning = snapshot.run.isRunning
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if rows.isEmpty {
                    Text(isRunning ? "This is the flow's first run. It is listed here once it ends."
                         : "Each run is listed here once it ends, so you can look back at where it went.")
                        .dsSans()
                        .foregroundStyle(Theme.inkSecondary.ui)
                } else {
                    Text(isRunning ? "Earlier runs can be looked at once this one ends."
                         : "Tap a run to see where it went, on the canvas and in the log. Only this device changes.")
                        .dsSans(Theme.Touch.caption + 1)
                        .foregroundStyle(Theme.inkSecondary.ui)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows) { row in
                    Button { client.show(run: row.id) } label: { RunRowView(row: row) }
                        .buttonStyle(.plain)
                        .disabled(isRunning)
                        .opacity(isRunning ? 0.6 : 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.spoken)
                        .accessibilityAddTraits(row.isOnShow ? [.isButton, .isSelected] : [.isButton])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
        }
    }

}

extension RemoteClient {
    /// Puts one of the kept runs on show on this device. The latest run is what is on show when nothing is
    /// picked, so picking it is going back to the latest. While a run is going, that run stays on show.
    func show(run id: String) {
        guard let snapshot = mirror.snapshot, !snapshot.run.isRunning else { return }
        canvas.view(id == snapshot.runs.last?.id ? nil : snapshot.runs.first { $0.id == id })
    }
}

private struct RunRowView: View {
    let row: RunRow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(row.started).dsSans(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
                Badge(text: row.outcome.rawValue, tone: tone)
                Spacer(minLength: Theme.Space.s)
                Text(row.cost ?? "–").dsMono(Theme.Touch.body, .medium).foregroundStyle((row.cost == nil ? Theme.inkSecondary : Theme.ink).ui)
            }
            Text(row.command)
                .dsSans()
                .foregroundStyle(Theme.ink.ui)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: Theme.Space.s) {
                Text("\(row.length) · \(row.handOffs)").dsSans(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui)
                Spacer(minLength: Theme.Space.s)
                if row.isOnShow { Text("On show").dsSans(Theme.Touch.caption, .medium).foregroundStyle(Theme.select.ui) }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: Theme.Touch.target, alignment: .leading)
        .background(Theme.surface.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder((row.isOnShow ? Theme.select : Theme.hairline).ui, lineWidth: row.isOnShow ? Theme.Stroke.selected : Theme.Stroke.card))
        .contentShape(Rectangle())
    }

    private var tone: Badge.Tone {
        switch row.outcome {
        case .finished: .pass
        case .stopped: .plain
        case .failed: .fail
        }
    }
}

/// Where the cost went: the run on show card by card, then everything the flow has used so far.
struct CostPage: View {
    @Environment(RemoteClient.self) private var client
    let sheet: CostSheet
    let flowName: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PanelSection(title: sheet.runTitle) {
                    if let lines = sheet.runLines, let total = sheet.runTotal {
                        ForEach(lines) { line in
                            CostLine(line: line)
                            Hairline()
                        }
                        TotalLine(label: sheet.runSoFar ? "This run so far" : "This run", usage: total)
                    } else {
                        Text(sheet.runPending ?? "")
                            .dsSans()
                            .foregroundStyle(Theme.inkSecondary.ui)
                            .padding(Theme.Space.m)
                    }
                }
                PanelSection(title: "Cost of \(flowName), in all") {
                    if sheet.total.isZero {
                        Text("Nothing yet. A figure appears here once an agent in this flow has replied.")
                            .dsSans()
                            .foregroundStyle(Theme.inkSecondary.ui)
                            .padding(Theme.Space.m)
                    } else {
                        ForEach(sheet.sessions) { line in
                            CostLine(line: line)
                            Hairline()
                        }
                        TotalLine(label: "In all", usage: sheet.total)
                    }
                }
                if !sheet.subflows.isEmpty {
                    PanelSection(title: "Sub-flows") {
                        ForEach(sheet.subflows) { sub in
                            Button { client.open(sub.id) } label: {
                                CostLine(line: CostSheet.Line(id: sub.id, name: sub.name, icon: "arrow.turn.down.right", usage: sub.usage, share: sub.share),
                                         indent: CGFloat(sub.depth) * 14, opens: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens \(sub.name), to see its own breakdown.")
                            Hairline()
                        }
                        if let all = sheet.withSubflows { TotalLine(label: "With sub-flows", usage: all) }
                    }
                }
                if let outer = sheet.outer {
                    Button { client.open(outer.id) } label: {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "arrow.turn.left.up").font(.system(size: 12, weight: .medium)).frame(width: 18).accessibilityHidden(true)
                            Text("Part of \(outer.name)").dsSans(Theme.Touch.body, .medium).lineLimit(1)
                            Spacer(minLength: Theme.Space.s)
                            Text("\(outer.usage.price) in all").dsMono(Theme.Touch.caption)
                        }
                        .foregroundStyle(Theme.ink.ui)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(minHeight: Theme.Touch.target)
                        .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Goes back to \(outer.name).")
                }
                Text(CostSheet.explanation)
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
        }
    }
}

/// One card or session: its name, what it used, and a bar for its share of the whole.
private struct CostLine: View {
    let line: CostSheet.Line
    /// How far in a sub-flow is, under the flow that runs it.
    var indent: CGFloat = 0
    /// A chevron, for a line that opens its flow.
    var opens = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: line.icon).font(.system(size: 12, weight: .medium)).frame(width: 18).accessibilityHidden(true)
                Text(line.name).dsSans(Theme.Touch.body, .medium).lineLimit(1)
                if opens { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkSecondary.ui).accessibilityHidden(true) }
                Spacer(minLength: Theme.Space.s)
                Text(line.usage.price).dsMono(Theme.Touch.body, .medium)
            }
            .foregroundStyle(Theme.ink.ui)
            Text(line.usage.tokenCount).dsMono(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui).padding(.leading, 18 + Theme.Space.s)
            GeometryReader { space in
                Rectangle().fill(Theme.ink.ui)
                    .frame(width: max(line.usage.isZero ? 0 : 2, space.size.width * min(1, max(0, line.share))), height: 2)
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
        .padding(.leading, indent)
        .padding(Theme.Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.name), \(line.usage.price), \(line.usage.tokenCount)")
    }
}

private struct TotalLine: View {
    let label: String
    let usage: Usage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(label).dsSans(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
            Spacer(minLength: Theme.Space.s)
            Text(usage.tokenCount).dsMono(Theme.Touch.caption).foregroundStyle(Theme.inkSecondary.ui)
            Text(usage.price).dsMono(Theme.Touch.title, .medium).foregroundStyle(Theme.ink.ui)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: Theme.Touch.target)
        .background(Theme.bar.ui)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(usage.price), \(usage.tokenCount)")
    }
}
