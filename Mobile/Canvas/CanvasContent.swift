import QueenBeeCore
import UIKit

/// What a card view needs to know beyond its own card. The Mac's `CardContext` in `App/Canvas/CardView.swift`,
/// less what only the Mac knows: which card has the keyboard, whether a session is behind its settings, and
/// whether a schedule has been turned on.
nonisolated struct CardContext: Equatable {
    var isSelected = false
    /// The card is where the run is right now: an agent at work or waiting on a hand-off.
    var isLive = false
    var linkedInputs = false
    var linkedPorts: Set<String> = []
    var warning: String?
    var inputCount = 0
    var result: String?
    /// What the card's session cost in the run on show, like "$0.02". Nil when nothing was used.
    var cost: String?
    /// What a card holding a message is waiting on, in a few words.
    var waiting: String?
    var sessionState: SessionState = .notStarted
    /// A run is under way. Marks left by a run that has ended say where it went, not what is live.
    var isRunning = false
    var mark = RunMark()
}

/// How one link is drawn.
nonisolated struct LinkLook: Equatable {
    var points: [CGPoint]
    var isSelected = false
    /// A message is travelling it now.
    var isLive = false
    /// How many times it has fired in the run on show.
    var count = 0
    /// Which cards it joins, for VoiceOver, which can't see the line.
    var spoken = ""
}

/// How one group is drawn.
nonisolated struct GroupLook: Equatable {
    enum Tone { case plain, live, fail }

    var group: CardGroup
    var tone = Tone.plain
    var isSelected = false
    var detail = ""
}

/// Everything the canvas draws for one flow, worked out from what the Mac sent. Comparing two of these is
/// how the canvas knows which views to touch.
nonisolated struct CanvasContent: Equatable {
    var flowID = ""
    var cards: [Card] = []
    var contexts: [String: CardContext] = [:]
    /// Links in the flow's order. One with no route isn't drawn: both its ends are inside the same folded group.
    var links: [(id: String, look: LinkLook)] = []
    var groups: [GroupLook] = []
    /// Cards folded away inside a group.
    var folded: Set<String> = []

    static func == (a: CanvasContent, b: CanvasContent) -> Bool {
        a.flowID == b.flowID && a.cards == b.cards && a.contexts == b.contexts && a.groups == b.groups && a.folded == b.folded
            && a.links.elementsEqual(b.links) { $0.id == $1.id && $0.look == $1.look }
    }

    /// This mirrors `sync()` and `syncGroups()` in the Mac's `App/Canvas/CanvasView.swift`, reading the
    /// Mac's snapshot where the Mac reads its own controller.
    /// - Parameter siblings: the other flows in the same project, for the name of the flow a Flow card runs.
    /// - Parameter viewed: an earlier run to show in place of the latest.
    init(_ snapshot: RemoteFlowSnapshot, siblings: [RemoteFlowSummary], selection: CanvasModel.Selection, viewed: RunRecord?) {
        let flow = snapshot.flow, run = snapshot.run
        // An earlier run is over: it has marks, counts and results, and nothing in it is live or waiting.
        let marks = viewed?.marks ?? run.marks
        let passes = viewed?.linkPasses ?? run.linkPasses
        let results = viewed?.results ?? run.results
        let isRunning = viewed == nil && run.isRunning
        let holds = viewed == nil ? run.holds : []
        let live = viewed == nil ? Set(run.liveLinkIDs) : []
        // The Mac sends what each session has used in all. What one run used is known once the run is kept.
        let spent = isRunning ? nil : (viewed ?? snapshot.runs.last)?.usage
        let warnings = QueenBeeCore.warnings(for: flow)

        flowID = flow.id
        cards = flow.cards
        for card in flow.cards {
            var context = CardContext()
            context.isSelected = selection == .card(card.id)
            context.linkedInputs = flow.links.contains { $0.to == card.id }
            context.linkedPorts = Set(flow.links(from: card.id).map(\.port))
            context.warning = warnings[card.id]
            context.inputCount = Set(flow.links(into: card.id).map(\.from)).count
            context.result = results[card.id]
            if flow.isSubflow == true, context.result == nil {
                // In a sub-flow the Start and End are its way in and its way out.
                if card.kind == .start, (card.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    context.result = "Gets the Flow card's message"
                } else if card.kind == .end, (card.saveTo ?? "").isEmpty {
                    context.result = "Goes back to the Flow card"
                }
            }
            if card.kind == .flow, context.result == nil, let inner = Self.innerFlow(of: card, in: siblings, excluding: flow.id) {
                // The Mac's second line says how to open the flow, which is done in the list here.
                let cost = spent?[card.id].flatMap { $0.isZero ? nil : "\n\($0.price) in this run" } ?? ""
                context.result = "Runs \(inner.name)\(cost)"
            }
            if let hold = holds.first(where: { $0.cardID == card.id }) {
                context.isLive = true
                context.waiting = hold.kind == .approval ? "Waiting for you to approve"
                    : hold.kind == .flow ? "Running \(hold.command)…"
                    : hold.needsAllow ? "Waiting for you to let its command run" : "Running its command…"
            }
            context.mark = marks[card.id] ?? RunMark()
            context.isRunning = isRunning
            if card.kind == .agent {
                let state = run.sessions[card.id] ?? .notStarted
                context.sessionState = state
                context.isLive = state == .working || state == .needsYou || (isRunning && context.mark.arrivals > context.mark.passes)
                if viewed == nil, run.awaitingAnswer.contains(card.id) { context.waiting = "awaiting answer" }
                if let used = spent?[card.id], !used.isZero { context.cost = used.price }
            }
            contexts[card.id] = context
        }

        for link in flow.links {
            guard let points = CanvasGeometry.route(of: link, in: flow) else { continue }
            let from = flow.card(link.from)?.name ?? "a card", to = flow.card(link.to)?.name ?? "a card"
            links.append((link.id, LinkLook(points: points, isSelected: selection == .link(link.id),
                                            isLive: live.contains(link.id), count: passes[link.id] ?? 0,
                                            spoken: "Link from \(from) to \(to)")))
        }

        // The Mac's `cardsNeedingYou`.
        let held = Set(holds.filter { $0.kind == .approval || $0.needsAllow }.map(\.cardID))
        let waiting = Set(flow.cards.filter { ($0.kind == .agent && run.sessions[$0.id] == .needsYou && viewed == nil) || held.contains($0.id) }.map(\.id))
        for group in flow.groups ?? [] where flow.cards.contains(where: { group.cardIDs.contains($0.id) }) {
            if group.isFolded { folded.formUnion(group.cardIDs) }
            let members = flow.cards.filter { group.cardIDs.contains($0.id) }
            let failed = members.contains { marks[$0.id]?.failed == true }
            let live = members.contains { card in
                waiting.contains(card.id) || holds.contains { $0.cardID == card.id }
                    || (viewed == nil && card.kind == .agent && [.working, .needsYou].contains(run.sessions[card.id] ?? .notStarted))
            }
            let needs = members.filter { waiting.contains($0.id) }.count
            let detail = needs > 0 ? "\(needs) need\(needs == 1 ? "s" : "") you" : live ? "working" : "\(members.count) cards"
            groups.append(GroupLook(group: group, tone: failed ? .fail : live ? .live : .plain,
                                    isSelected: selection == .group(group.id), detail: detail))
        }
    }

    init() {}

    /// The flow a Flow card runs: found by id, or by name when the orchestrator set it. The Mac's
    /// `Nesting.resolve`, over the list of flows the device has.
    static func innerFlow(of card: Card, in siblings: [RemoteFlowSummary], excluding own: String) -> RemoteFlowSummary? {
        let ref = (card.flowRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }
        let others = siblings.filter { $0.id != own }
        return others.first { $0.id == ref } ?? others.first { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
    }
}
