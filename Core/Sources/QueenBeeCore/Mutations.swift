import Foundation

/// Why an edit to a flow was refused. The message is written for the person or the orchestrator to read.
public enum FlowError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notFound(String), invalid(String)

    public var description: String {
        switch self {
        case .notFound(let message), .invalid(let message): message
        }
    }

    public var errorDescription: String? { description }
}

extension Card {
    public static func minimumWidth(for card: Card) -> Double {
        guard card.kind == .agent else { return 180 }
        // A card with a browser holds a terminal and a page side by side.
        return card.browser == true ? 640 : 320
    }
}

extension Link {
    public static let defaultMaxPasses = 3
    public static let maxPassesRange = 1...50
}

/// Every edit to a flow goes through these, whether it comes from the canvas or from the orchestrator's tools,
/// so both are held to the same rules.
extension Flow {
    /// By id, else by name ignoring case.
    public func resolveCard(_ ref: String) -> Card? {
        let wanted = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        return card(wanted) ?? cards.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// `base` if no card has it, otherwise "base 2", "base 3" and so on.
    public func uniqueName(_ base: String) -> String {
        let taken = Set(cards.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    @discardableResult
    /// With `clearOfOthers`, a card that would land on top of another is moved right until it
    /// doesn't. The orchestrator's tools ask for that, since it places cards without seeing them.
    public mutating func addCard(kind: CardKind, name: String? = nil, x: Double? = nil, y: Double? = nil,
                                 patch: CardPatch = CardPatch(), clearOfOthers: Bool = false) throws -> Card {
        var rest = patch
        let chosen: String
        if let given = name ?? patch.name {
            chosen = try checkedName(given, for: nil)
        } else {
            chosen = uniqueName(kind.label)
        }
        let spot = nextCardPosition()
        let card = Card.make(kind: kind, name: chosen, x: x ?? patch.x ?? spot.x, y: y ?? patch.y ?? spot.y)
        rest.name = nil; rest.x = nil; rest.y = nil
        var finished = try patched(card, with: rest)
        if clearOfOthers {
            // Each move takes the card past the one it overlapped, so this ends within one pass per card.
            for _ in cards {
                let wanted = (minX: finished.x - 40, maxX: finished.x + finished.width + 40,
                              minY: finished.y - 40, maxY: finished.y + finished.height + 40)
                guard let blocker = cards.first(where: {
                    $0.x < wanted.maxX && $0.x + $0.width > wanted.minX && $0.y < wanted.maxY && $0.y + $0.height > wanted.minY
                }) else { break }
                finished.x = blocker.x + blocker.width + 60
            }
        }
        cards.append(finished)
        return finished
    }

    @discardableResult
    public mutating func updateCard(_ ref: String, patch: CardPatch) throws -> Card {
        guard let found = resolveCard(ref), let index = cards.firstIndex(where: { $0.id == found.id }) else {
            throw FlowError.notFound("No card called \"\(ref)\"")
        }
        let card = try patched(found, with: patch)
        cards[index] = card
        if card.kind == .switchCard, patch.branches != nil {
            let live = Set(ports(of: card))
            links.removeAll { $0.from == card.id && !live.contains($0.port) }
        }
        return card
    }

    public mutating func removeCard(_ ref: String) throws {
        guard let card = resolveCard(ref) else { throw FlowError.notFound("No card called \"\(ref)\"") }
        cards.removeAll { $0.id == card.id }
        links.removeAll { $0.from == card.id || $0.to == card.id }
        pruneGroups()
    }

    // MARK: Groups

    public func group(containing cardID: String) -> CardGroup? {
        (groups ?? []).first { $0.cardIDs.contains(cardID) }
    }

    /// Frames these cards together under a name. A card is in one group at most, so any of
    /// them that were in another leave it.
    @discardableResult
    public mutating func addGroup(name: String? = nil, cardIDs: [String]) throws -> CardGroup {
        let members = cards.map(\.id).filter(cardIDs.contains)
        guard members.count >= 2 else { throw FlowError.invalid("A group needs at least two cards") }
        var all = groups ?? []
        for index in all.indices { all[index].cardIDs.removeAll(where: members.contains) }
        let taken = Set(all.map { $0.name.lowercased() })
        var chosen = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if chosen.isEmpty {
            var n = 1
            while taken.contains("group \(n)") { n += 1 }
            chosen = "Group \(n)"
        }
        let group = CardGroup(name: chosen, cardIDs: members)
        all.append(group)
        groups = all
        pruneGroups()
        return group
    }

    public mutating func updateGroup(_ id: String, name: String? = nil, isFolded: Bool? = nil) throws {
        guard let index = (groups ?? []).firstIndex(where: { $0.id == id }) else { throw FlowError.notFound("No group with id \"\(id)\"") }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw FlowError.invalid("A group needs a name") }
            groups?[index].name = trimmed
        }
        if let isFolded { groups?[index].isFolded = isFolded }
    }

    public mutating func removeGroup(_ id: String) {
        groups?.removeAll { $0.id == id }
        if groups?.isEmpty == true { groups = nil }
    }

    /// Drops cards that are gone from their groups, and groups left with fewer than two cards.
    mutating func pruneGroups() {
        guard var all = groups else { return }
        let present = Set(cards.map(\.id))
        for index in all.indices { all[index].cardIDs.removeAll { !present.contains($0) } }
        all.removeAll { $0.cardIDs.count < 2 }
        groups = all.isEmpty ? nil : all
    }

    /// A plain-English reason the link can't be made, or nil if it can. `from` and `to` are card ids.
    public func linkProblem(from: String, port: String, to: String) -> String? {
        guard let source = card(from) else { return "The card this link starts from is gone" }
        guard let target = card(to) else { return "The card this link goes to is gone" }
        if source.id == target.id { return "A card can't link to itself" }
        let outputs = ports(of: source)
        if outputs.isEmpty { return "\(source.kind.label) cards have no outputs" }
        if !outputs.contains(port) {
            return "\"\(source.name)\" has no output called \"\(port)\". Its outputs are: \(outputs.joined(separator: ", "))"
        }
        if !acceptsInput(target) {
            return target.kind == .start ? "A Start card takes no input" : "A Note carries no messages"
        }
        if links.contains(where: { $0.from == from && $0.port == port && $0.to == to }) {
            return "\"\(source.name)\" is already linked to \"\(target.name)\" from \(portLabel(port))"
        }
        return nil
    }

    @discardableResult
    public mutating func addLink(from: String, port: String? = nil, to: String, maxPasses: Int? = nil) throws -> Link {
        guard let source = resolveCard(from) else { throw FlowError.notFound("No card called \"\(from)\"") }
        guard let target = resolveCard(to) else { throw FlowError.notFound("No card called \"\(to)\"") }
        let outputs = ports(of: source)
        let asked = port?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "Yes" and "yes" mean the same output; keep the spelling the card uses.
        let chosen = asked.isEmpty
            ? outputs.first ?? "out"
            : outputs.first { $0.caseInsensitiveCompare(asked) == .orderedSame } ?? asked
        if let problem = linkProblem(from: source.id, port: chosen, to: target.id) { throw FlowError.invalid(problem) }
        let link = Link(from: source.id, port: chosen, to: target.id,
                        maxPasses: Self.clampedPasses(maxPasses ?? Link.defaultMaxPasses))
        links.append(link)
        return link
    }

    public mutating func updateLink(_ id: String, maxPasses: Int) throws {
        guard let index = links.firstIndex(where: { $0.id == id }) else { throw FlowError.notFound("No link with id \"\(id)\"") }
        links[index].maxPasses = Self.clampedPasses(maxPasses)
    }

    public mutating func removeLink(_ id: String) throws {
        guard links.contains(where: { $0.id == id }) else { throw FlowError.notFound("No link with id \"\(id)\"") }
        links.removeAll { $0.id == id }
    }

    // MARK: -

    private static func clampedPasses(_ n: Int) -> Int {
        min(max(n, Link.maxPassesRange.lowerBound), Link.maxPassesRange.upperBound)
    }

    private func checkedName(_ raw: String, for cardID: String?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FlowError.invalid("A card needs a name") }
        if cards.contains(where: { $0.id != cardID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw FlowError.invalid("Another card is already called \"\(name)\"")
        }
        return name
    }

    private func nextCardPosition() -> (x: Double, y: Double) {
        guard let last = cards.max(by: { $0.x + $0.width < $1.x + $1.width }) else { return (80, 80) }
        return (last.x + last.width + 60, last.y)
    }

    /// `original` with the patch applied. Settings that belong to another kind of card are left alone,
    /// so a flow file never carries a command on an agent or a template on a switch.
    private func patched(_ original: Card, with patch: CardPatch) throws -> Card {
        var card = original
        if let name = patch.name { card.name = try checkedName(name, for: card.id) }
        if let x = patch.x { card.x = x }
        if let y = patch.y { card.y = y }
        if let width = patch.width { card.width = width }
        if let height = patch.height { card.height = height }

        switch card.kind {
        case .agent:
            if let instructions = patch.instructions { card.instructions = instructions }
            if let model = patch.model { card.model = Self.setOrCleared(model) }
            if let effort = patch.effort { card.effort = Self.setOrCleared(effort) }
            if let mode = patch.permissionMode {
                guard mode.isEmpty || Card.permissionModes.contains(mode) else {
                    throw FlowError.invalid("Unknown permission mode \"\(mode)\". Use one of: \(Card.permissionModes.joined(separator: ", "))")
                }
                card.permissionMode = Self.setOrCleared(mode)
            }
            if let cwd = patch.cwd { card.cwd = Self.setOrCleared(cwd) }
            if let browser = patch.browser, browser != (card.browser == true) {
                card.browser = browser ? true : nil
                // The browser takes the card's right half, so the terminal keeps the room it had. A patch that
                // also sets the width has said how wide the card should be.
                if patch.width == nil { card.width = browser ? card.width * 2 : card.width / 2 }
            }
        case .start, .script:
            if let command = patch.command { card.command = command }
            if card.kind == .script, let minutes = patch.waitMinutes { card.waitMinutes = Self.waitOrCleared(minutes) }
        case .ifElse, .loop:
            if let check = patch.check { card.check = check }
            if let value = patch.value { card.value = value }
            if card.kind == .loop, let tries = patch.maxTries { card.maxTries = min(max(tries, 1), 50) }
        case .switchCard:
            if let branches = patch.branches { card.branches = Self.cleanBranches(branches) }
        case .prompt:
            if let template = patch.template { card.template = template }
        case .end:
            if let saveTo = patch.saveTo {
                guard !Checks.isProtectedSavePath(saveTo) else {
                    throw FlowError.invalid("An End card can't save inside \(Checks.protectedSaveFolders.joined(separator: ", ")). Choose another file.")
                }
                card.saveTo = saveTo
            }
        case .note, .approval:
            if let text = patch.text { card.text = text }
            guard card.kind == .approval else { break }
            if let minutes = patch.waitMinutes { card.waitMinutes = Self.waitOrCleared(minutes) }
            if let answer = patch.whenNoAnswer {
                let chosen = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard chosen.isEmpty || chosen == "approved" || chosen == "rejected" else {
                    throw FlowError.invalid("Unknown answer \"\(answer)\". Use approved or rejected")
                }
                card.whenNoAnswer = chosen.isEmpty ? nil : chosen
            }
        case .forEach:
            if let split = patch.split { card.split = split }
            if let items = patch.maxItems { card.maxItems = min(max(items, 1), Engine.mostItems) }
        case .flow:
            if let flowRef = patch.flowRef { card.flowRef = Self.setOrCleared(flowRef) }
        case .and, .or:
            break
        }

        card.width = max(card.width, Card.minimumWidth(for: card))
        card.height = max(card.height, Card.minimumHeight(for: card))
        return card
    }

    /// A time limit as it is kept: 0 or less for none, and never longer than a week.
    private static func waitOrCleared(_ minutes: Int) -> Int? {
        minutes > 0 ? min(minutes, HoldTimeLimit.longestMinutes) : nil
    }

    private static func setOrCleared(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Branch names double as port names, so they can't be blank, repeat, or take the built-in "other".
    private static func cleanBranches(_ branches: [String]) -> [String] {
        var seen: Set<String> = ["other"]
        return branches
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
