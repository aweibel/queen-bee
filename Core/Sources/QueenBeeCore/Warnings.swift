import Foundation

/// One short warning per card whose wiring would leave a run stuck, keyed by card id.
/// A card with several problems shows the first, so fixing them one at a time walks through the rest.
public func warnings(for flow: Flow) -> [String: String] {
    let circling = logicCardsInACircle(in: flow)
    var found: [String: String] = [:]
    for card in flow.cards {
        if let warning = warning(for: card, in: flow, circling: circling.contains(card.id)) {
            found[card.id] = warning
        }
    }
    return found
}

private func warning(for card: Card, in flow: Flow, circling: Bool) -> String? {
    let outgoing = flow.links(from: card.id)
    let incoming = flow.links(into: card.id)
    func nothing(on port: String) -> Bool { !outgoing.contains { $0.port == port } }
    func blank(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    switch card.kind {
    case .agent, .note:
        return nil
    case .start:
        if outgoing.isEmpty { return flow.isSubflow == true ? "Link it to a card" : "Link it to an agent" }
        // A sub-flow's Start is given its message by the Flow card that runs it.
        if blank(card.command), flow.isSubflow != true { return "Write the command" }
        return nil
    case .ifElse:
        if nothing(on: "yes") { return "Nothing on Yes" }
        if nothing(on: "no") { return "Nothing on No" }
        if blank(card.value) { return "Set its condition" }
    case .loop:
        if nothing(on: "again") { return "Nothing on Again" }
        if blank(card.value) { return "Set its condition" }
        // Without it, a run that gets the answer it was looping for stops there with nothing to show.
        if nothing(on: "done") { return "Nothing on Done" }
    case .switchCard:
        if (card.branches ?? []).isEmpty { return "Add a branch" }
    case .and:
        // An And waits for one message per card that links in, so two links from one card are one input.
        if Set(incoming.map(\.from)).count < 2 { return "Link in 2 or more cards" }
        if let split = branch(splitting: card, in: flow) { return "Its inputs are on different sides of \(split.name)" }
    case .approval:
        if nothing(on: "approved") { return "Nothing on Approved" }
    case .script:
        if blank(card.command) { return "Write the command" }
        if nothing(on: "pass") { return "Nothing on Pass" }
    case .flow:
        if blank(card.flowRef) { return "Choose a flow" }
        if nothing(on: "done") { return "Nothing on Done" }
    case .end:
        if Checks.isProtectedSavePath(card.saveTo ?? "") { return "Can't save there" }
    case .forEach:
        if nothing(on: "each") { return "Nothing on Each" }
        // An item's result comes back along a link into this card from the cards on Each.
        if !comesBack(to: card, in: flow) { return "Nothing on Each links back to it" }
        if nothing(on: "done") { return "Nothing on Done" }
    case .or, .prompt:
        break
    }

    if incoming.isEmpty { return "Nothing is linked to it" }
    if circling { return "Goes round with no agent" }
    return nil
}

/// An If or Switch card that an And's inputs can only be reached through by different outputs. A message
/// leaves such a card by one output, so the And never hears from every input and the run ends there. A card
/// that a run can come back round to is left out: on the next time round it can go the other way.
private func branch(splitting and: Card, in flow: Flow) -> Card? {
    var sources: [String] = []
    for link in flow.links(into: and.id) where !sources.contains(link.from) { sources.append(link.from) }
    let starts = flow.cards.filter { $0.kind == .start }.map(\.id)
    for branch in flow.cards where branch.kind == .ifElse || branch.kind == .switchCard {
        guard !reachable(from: flow.links(from: branch.id).map(\.to), in: flow).contains(branch.id) else { continue }
        // What a run can reach without passing this card.
        let around = reachable(from: starts, in: flow, avoiding: branch.id)
        var sides: Set<String> = []
        var split = 0
        for source in sources where source != branch.id && !around.contains(source) {
            let ports = Set(flow.links(from: branch.id).filter { reachable(from: [$0.to], in: flow).contains(source) }.map(\.port))
            guard ports.count == 1, let port = ports.first else { continue }
            sides.insert(port)
            split += 1
        }
        if sides.count >= 2, split >= 2 { return branch }
    }
    return nil
}

/// Whether a card reached from a For each card's Each output links back into it, which is how each item's result returns.
private func comesBack(to forEach: Card, in flow: Flow) -> Bool {
    let body = reachable(from: flow.links(from: forEach.id, port: "each").map(\.to), in: flow, avoiding: forEach.id)
    return flow.links(into: forEach.id).contains { body.contains($0.from) }
}

/// Every card a message can reach from `ids`, them included, never passing through `avoiding`.
private func reachable(from ids: [String], in flow: Flow, avoiding: String? = nil) -> Set<String> {
    var seen: Set<String> = []
    var next = ids.filter { $0 != avoiding }
    while let id = next.popLast() {
        guard seen.insert(id).inserted else { continue }
        next += flow.links(from: id).map(\.to).filter { $0 != avoiding }
    }
    return seen
}

/// Logic cards that can reach themselves without passing through an agent. A message entering such a circle
/// would go round until the engine's arrival limit drops it, because only an agent's turn breaks up a run.
private func logicCardsInACircle(in flow: Flow) -> Set<String> {
    let passesMessagesOn: Set<CardKind> = [.ifElse, .switchCard, .and, .or, .prompt, .loop]
    let logic = Set(flow.cards.filter { passesMessagesOn.contains($0.kind) }.map(\.id))
    var next: [String: [String]] = [:]
    for link in flow.links where logic.contains(link.from) && logic.contains(link.to) {
        next[link.from, default: []].append(link.to)
    }

    var circling: Set<String> = []
    for id in logic {
        var seen: Set<String> = []
        var stack = next[id] ?? []
        while let current = stack.popLast() {
            if current == id { circling.insert(id); break }
            if seen.insert(current).inserted { stack.append(contentsOf: next[current] ?? []) }
        }
    }
    return circling
}
