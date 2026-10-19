import Foundation
import Observation
import QueenBeeCore

/// One change to the open flow that a person can ask for by touch. Each becomes one command, which the Mac
/// checks and makes itself: nothing here changes the flow on this device.
nonisolated enum EditAction: Equatable, Sendable {
    /// A new card with the middle of its title bar at a canvas point, or in the middle of what is on screen.
    case add(CardKind, at: CGPoint?)
    case delete(cards: [String], links: [String])
    case duplicate([String])
    case group([String])
    case ungroup(String)
    case fold(String, Bool)
    /// With no name, the name is asked for first.
    case renameGroup(String, to: String?)
    case link(from: String, port: String, to: String)
    /// Moves cards by so much, as the Mac's arrow keys do.
    case nudge([String], dx: Double, dy: Double)
    case undo, redo, tidy
    /// Stage 2's "Run from here…": asks for the message in the card's details.
    case runFrom(String)
    /// Puts up the list of kinds of card, to add one at a canvas point or in the middle of what is on screen.
    case showAdd(at: CGPoint?)
    /// Puts up the list of cards this card's outputs could be linked to. For VoiceOver, which can't drag.
    case showLinks(from: String)
    /// The Mac's Copy: the cards, with the links and groups between them, go on this device's clipboard. Nothing is sent.
    case copy([String])
    /// Copy, then delete, as the Mac's Cut does.
    case cut([String])
    /// Copies of what is on this device's clipboard, with its top-left card at a canvas point, or round the middle of what is on screen.
    case paste(at: CGPoint?)
    /// Selects every card, as the Mac's Select All does.
    case selectAll
    /// A new agent made from a saved role, at a canvas point or in the middle of what is on screen.
    case addRole(String, at: CGPoint?)
    /// One of the run's buttons, from a card's menu: "Run from This Start" or Retry.
    case press(Press)
    /// A Flow card's "Open Its Flow".
    case openSubflow(String)

    /// What kind of command it sends, to tell whether one like it is still on its way to the Mac.
    var kind: String? {
        switch self {
        case .add: "addCard"
        case .delete: "deleteItems"
        case .duplicate: "duplicate"
        case .group: "group"
        case .ungroup: "ungroup"
        case .fold: "foldGroup"
        case .renameGroup: "renameGroup"
        case .link: "addLink"
        case .nudge: "moveCards"
        case .undo: "undo"
        case .redo: "redo"
        case .tidy: "tidy"
        case .cut: "deleteItems"
        case .paste: "paste"
        case .addRole: "addCard"
        case .runFrom, .showAdd, .showLinks, .copy, .selectAll, .press, .openSubflow: nil
        }
    }
}

extension RemoteCommand {
    /// The same names as `EditAction.kind`, for the commands that edit the graph.
    var editKind: String? {
        switch self {
        case .addCard: "addCard"
        case .moveCards: "moveCards"
        case .resizeCard: "resizeCard"
        case .deleteItems: "deleteItems"
        case .addLink: "addLink"
        case .duplicate: "duplicate"
        case .tidy: "tidy"
        case .group: "group"
        case .ungroup: "ungroup"
        case .renameGroup: "renameGroup"
        case .foldGroup: "foldGroup"
        case .undo: "undo"
        case .redo: "redo"
        case .paste: "paste"
        // A card from a role is added as any other card is, and waits behind one.
        case .addRoleCard: "addCard"
        default: nil
        }
    }
}

/// A list of things to do, put up where a finger was held: a card's, a link's, a group's, or the kinds of
/// card that can be added.
nonisolated struct EditMenu: Equatable, Sendable {
    struct Item: Equatable, Identifiable, Sendable {
        var title: String
        var symbol: String?
        var action: EditAction
        var isDestructive = false
        /// False while a command like it is on its way to the Mac and hasn't been answered.
        var isEnabled = true
        /// Tells it from another of the same name, as a role can have a kind's name.
        var key: String?

        init(title: String, symbol: String?, action: EditAction, isDestructive: Bool = false, isEnabled: Bool = true, id: String? = nil) {
            self.title = title; self.symbol = symbol; self.action = action; self.isDestructive = isDestructive; self.isEnabled = isEnabled; key = id
        }

        var id: String { key ?? title }
    }

    /// What it is about: a card's name, or what the list is of.
    var title: String
    var items: [Item]
    /// Where the finger was, in the window. Nil for a list asked for from the bar, which goes above the bar.
    var anchor: CGPoint?
}

/// Something that is checked with the person before an edit is sent.
nonisolated enum EditAsk: Equatable, Sendable {
    /// Deleting more than one thing, or a card that has links.
    case delete(cards: [String], links: [String], title: String, message: String)
    case renameGroup(id: String, name: String)
    /// "Save as a New Role": the role's name, which may be left empty for the card's own.
    case saveRole(cardID: String, name: String)
    /// A Flow card's "New sub-flow": the new flow's name, which may be left empty for the card's own.
    case newSubflow(cardID: String, name: String)
    /// Deleting a saved role can't be undone, so it is asked by the role's name.
    case deleteRole(roleID: String, name: String)
}

/// One button of the editing bar.
nonisolated struct EditBarItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case edit, undo, redo, add, select, tidy, done }

    var kind: Kind
    /// The Mac's name for it. For Undo and Redo, what the Mac's Edit menu calls them just now.
    var title: String
    var symbol: String
    var isEnabled = true
    /// Select, while cards are being selected.
    var isOn = false
    var hint = ""

    var id: Kind { kind }
}

/// What this device is in the middle of while a flow is being edited by touch: whether editing is on, what is
/// under the finger, and what is being asked. Editing is a mode, turned on with Edit and off with Done, so a
/// stray finger never moves a card while a run is being watched. It is this device's own: the Mac is told
/// only of each change.
@Observable
final class EditModel {
    /// The flow being edited. Nil when editing is off, which is how the app always starts.
    private(set) var flowID: String?
    /// What Copy and Cut last put on this device's clipboard. It is the device's own, and is kept from one flow
    /// to the next for as long as the app runs, so cards can be copied out of one flow and pasted into another.
    var clipboard: FlowFragment?
    /// Whether a dragged card settles against the other cards and the grid, as on the Mac. Off is the Mac's Option key.
    var snaps = true
    /// Select was pressed: a drag on bare canvas draws a box, and a tap on a card adds it or takes it out.
    var isSelecting = false

    /// A drag that is under way.
    enum Gesture: Equatable {
        /// Cards being moved: where each was when the drag began, and the one that settles against the others.
        case move(frames: [String: CGRect], lead: String)
        case resize(cardID: String, start: CGRect)
        /// A link being dragged out of one of a card's outputs.
        case link(card: String, port: String)
        /// The box that selects cards, and what was selected before it.
        case box(base: Set<String>)
    }

    private(set) var gesture: Gesture?
    /// The canvas point the finger came down on.
    private(set) var grabbedAt = CGPoint.zero

    /// The cards a drag carries, where the finger has them. It outlives the drag by a moment: until the Mac
    /// has said what became of it.
    struct Carried: Equatable {
        /// Tells one drag's from the next.
        var id: Int
        var flowID: String
        var overlay: TouchEdit.Overlay
        /// What the drag is, for the commands that say where it has got to.
        var drag: RemoteDrag
        /// The finger has lifted and the last step is with the Mac.
        var isSettling = false
        /// The Mac took the last step, and the flow it sends next is the truth. The revision seen when it answered.
        var awaitsFlowAfter: Int?
    }

    private(set) var carried: Carried?
    private var lastCarriedID = 0
    /// The lines that show a dragged card is lined up with another.
    private(set) var guides: [Snapping.Guide] = []

    /// A link being dragged: its route so far, and the card under the finger with whether it would take the link.
    struct PendingLink: Equatable {
        var from: String
        var port: String
        var points: [CGPoint]
        var over: String?
        var accepts = false
    }

    var pendingLink: PendingLink?
    /// The box being drawn round cards, in the canvas's own points.
    var marquee: CGRect?
    /// The list put up by a long press or by the bar's add button.
    var menu: EditMenu?
    /// What is being asked before an edit is sent. Put away by setting it to nil.
    var asking: EditAsk? {
        didSet { if asking == nil { askedIn = nil } }
    }
    /// The flow that was open when the question was asked, which is the only flow its answer is for.
    private(set) var askedIn: String?
    /// How many times the Mac has said it added or copied cards and the flow with them in hasn't come yet.
    /// What is new in the next flow is selected, as the Mac selects what it adds.
    @ObservationIgnored var addsAwaited = 0
    /// The cards of the flow as it was last drawn, to tell which are new.
    @ObservationIgnored var seenCards: Set<String>?
    /// A link the Mac was asked for and took, to be selected when it comes.
    @ObservationIgnored var linkToSelect: (from: String, port: String, to: String)?
    /// Holds a drag's steps to so many a second, and sends the one that was held back.
    @ObservationIgnored var throttle = TouchEdit.Throttle()
    @ObservationIgnored var trailing: Task<Void, Never>?
    /// Gives up on an overlay whose flow from the Mac never came.
    @ObservationIgnored private var settleLimit: Task<Void, Never>?
    #if DEBUG
    /// What each touch-down a test made was taken to mean, and whether a drag began, in order.
    var debugDowns: [(meaning: String, taken: Bool)] = []
    #endif

    func isOn(for flowID: String?) -> Bool { flowID != nil && self.flowID == flowID }

    func start(in flowID: String) {
        guard self.flowID != flowID else { return }
        stop()
        self.flowID = flowID
    }

    /// Done was pressed, or editing has turned itself off. Whatever was under the finger is let go, and goes
    /// back to where the Mac has it. What is selected stays selected.
    func stop() {
        guard flowID != nil || gesture != nil || carried != nil || menu != nil || asking != nil else { return }
        flowID = nil
        isSelecting = false
        dropGesture()
        dropCarried()
        menu = nil
        asking = nil
        addsAwaited = 0
        linkToSelect = nil
    }

    func ask(_ ask: EditAsk, in flowID: String) {
        asking = ask
        askedIn = flowID
    }

    // MARK: Drags

    func begin(_ gesture: Gesture, at point: CGPoint) {
        self.gesture = gesture
        grabbedAt = point
        throttle = TouchEdit.Throttle()
    }

    /// Puts the dragged cards where the finger has them.
    func carry(_ frames: [String: CGRect], drag: RemoteDrag, in flowID: String, guides: [Snapping.Guide] = []) {
        if var carried, !carried.isSettling {
            carried.overlay.frames = frames
            if carried != self.carried { self.carried = carried }
        } else {
            lastCarriedID += 1
            carried = Carried(id: lastCarriedID, flowID: flowID, overlay: TouchEdit.Overlay(frames: frames), drag: drag)
        }
        if self.guides != guides { self.guides = guides }
    }

    /// The finger has lifted.
    func dropGesture() {
        gesture = nil
        trailing?.cancel()
        trailing = nil
        if !guides.isEmpty { guides = [] }
        if pendingLink != nil { pendingLink = nil }
        if marquee != nil { marquee = nil }
    }

    /// The last step has left for the Mac. Returns which drag it was, to know it again when the answer comes.
    func settle() -> Int? {
        guard carried != nil else { return nil }
        carried?.isSettling = true
        return carried?.id
    }

    /// The Mac took a drag's last step. Its copy of the flow is the truth from here: the overlay goes when
    /// that copy next arrives, at once if it is already what the finger left, and before long whatever happens.
    func settled(_ id: Int, on flow: Flow?, revision: Int) {
        guard let carried, carried.id == id else { return }
        guard let flow, !carried.overlay.agrees(with: flow) else { return dropCarried() }
        self.carried?.awaitsFlowAfter = revision
        settleLimit?.cancel()
        settleLimit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled, self?.carried?.id == id { self?.dropCarried() }
        }
    }

    /// Called when the Mac's flow may have changed. An overlay that was waiting for it goes.
    func flowArrived(revision: Int) {
        if let waited = carried?.awaitsFlowAfter, waited != revision { dropCarried() }
    }

    /// Takes the overlay away, so the cards are drawn where the Mac has them. `id` names one drag's overlay,
    /// and another's is left alone.
    func dropCarried(_ id: Int? = nil) {
        if let id, carried?.id != id { return }
        settleLimit?.cancel()
        settleLimit = nil
        if carried != nil { carried = nil }
        if !guides.isEmpty { guides = [] }
    }
}
