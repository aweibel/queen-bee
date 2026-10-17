import Foundation
import QueenBeeCore

/// What a role gives a card: everything but its name.
nonisolated struct RoleSettings: Codable, Equatable, Sendable {
    var instructions = ""
    var model = ""
    var effort = ""
    var permissionMode = ""
}

/// Which paired device saved or last changed a role, and when.
nonisolated struct RoleMark: Codable, Equatable, Sendable {
    var device: String
    var date: Date
}

/// A role a device deleted, kept a while so the person at the Mac can put it back.
nonisolated struct DeletedRole: Codable, Equatable, Sendable, Identifiable {
    var role: AgentRole
    var device: String
    var date: Date
    var id: String { role.id }
}

/// An agent's settings saved under a name, to make more agents like it in any flow.
nonisolated struct AgentRole: Codable, Identifiable, Equatable, Sendable {
    var id = Flow.newID()
    var name: String
    var instructions = ""
    var model = ""
    var effort = ""
    var permissionMode = ""
    /// Set when a paired device saved the role or changed it, until the person at this Mac agrees to use it or
    /// saves it here. The Mac marks it, and asks once before using it.
    var changedFrom: RoleMark?
    /// What the role held before a device changed it, so the Mac can put it back.
    var earlier: RoleSettings?

    var settings: RoleSettings {
        get { RoleSettings(instructions: instructions, model: model, effort: effort, permissionMode: permissionMode) }
        set {
            instructions = newValue.instructions
            model = newValue.model
            effort = newValue.effort
            permissionMode = newValue.permissionMode
        }
    }

    /// "Changed from iPad at 14:02", for the role menu, the palette and the inspector.
    var changedLine: String? {
        changedFrom.map { "Changed from \($0.device) \($0.date.formatted(date: Calendar.current.isDateInToday($0.date) ? .omitted : .abbreviated, time: .shortened))" }
    }

    init(from card: Card) {
        name = card.name
        instructions = card.instructions ?? ""
        model = card.model ?? ""
        effort = card.effort ?? ""
        permissionMode = card.permissionMode ?? ""
    }

    /// The role's settings as a change to a card. Its name is left to the card.
    var patch: CardPatch {
        var patch = CardPatch()
        patch.instructions = instructions
        patch.model = model
        patch.effort = effort
        patch.permissionMode = permissionMode
        return patch
    }

    /// Whether a card still has exactly what the role holds.
    func matches(_ card: Card) -> Bool {
        instructions == (card.instructions ?? "") && model == (card.model ?? "")
            && effort == (card.effort ?? "") && permissionMode == (card.permissionMode ?? "")
    }
}
