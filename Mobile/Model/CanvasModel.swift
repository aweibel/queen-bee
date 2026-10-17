import Observation
import QueenBeeCore
import UIKit

/// What this device is looking at on the canvas: what is selected, and where each flow was left. It is the
/// device's own. The Mac is never told, and its own selection and zoom are never shown here.
@Observable
final class CanvasModel {
    nonisolated enum Selection: Hashable, Sendable {
        case none
        case card(String)
        case link(String)
        /// A group, picked by its name strip or by its one card when folded.
        case group(String)
        /// Two or more cards, picked one by one or with a box while editing.
        case cards(Set<String>)

        var cardID: String? { if case .card(let id) = self { id } else { nil } }
        var linkID: String? { if case .link(let id) = self { id } else { nil } }

        /// One card is `.card`, so its details show. Several are `.cards`.
        static func of(_ ids: Set<String>) -> Selection {
            ids.count > 1 ? .cards(ids) : ids.first.map { .card($0) } ?? .none
        }

        /// The cards that are selected as cards. A group is selected as a group.
        var cardIDs: Set<String> {
            switch self {
            case .card(let id): [id]
            case .cards(let ids): ids
            case .none, .link, .group: []
            }
        }
    }

    /// The card, link or group the person tapped. The details panel shows it.
    private(set) var selection: Selection = .none
    /// The canvas's zoom, where 1 is the Mac's own size.
    fileprivate(set) var zoom: CGFloat = 1
    /// An earlier run to show on the canvas in place of the latest: its marks, its counts and its results.
    /// Nil for the latest. Only this device's canvas and panels change: the Mac is never told.
    private(set) var viewedRun: RunRecord?
    #if DEBUG
    /// The last earlier run that was put on show, for a test to see that one was, after it has gone again.
    private(set) var debugLastViewed: String?
    #endif

    /// Where a flow was left: its zoom, the canvas point in the middle of the clear part of the screen, and
    /// whether it was still as fitted, in which case it is fitted again for whatever room there is now.
    struct Viewport {
        var zoom: CGFloat
        var centre: CGPoint
        var isFitted: Bool
    }

    /// Kept for as long as the app runs, by flow id.
    @ObservationIgnored var viewports: [String: Viewport] = [:]
    /// The map of the whole flow is on show in the canvas's corner, as the Mac's minimap is.
    var showsMap = false
    /// The part of the canvas on screen, in canvas points, for the map to outline. Kept up to date while the map is on show.
    private(set) var visibleRect = CGRect.zero
    /// The flows whose "Describe the flow you want" note has been put away on this device, as "Build it by hand" does.
    var calloutPutAway: Set<String> = []
    /// A card Find went to in a flow that wasn't open: its flow and its name. It is selected and put in the middle of
    /// the canvas once that flow is on it.
    @ObservationIgnored var wantedCard: (flowID: String, name: String)?
    /// The canvas on screen, when there is one.
    @ObservationIgnored weak var view: CanvasView?
    /// Gives the terminal for a session, by its key: a card's id. Nil until there are terminals to give.
    /// When a terminal comes or goes, `terminalsChanged` puts the right one in each card.
    @ObservationIgnored var terminalSource: ((_ key: String) -> UIView?)?
    /// Opens a session's terminal full screen. The canvas calls it when the mark on an agent's card is tapped.
    @ObservationIgnored var expandTerminal: ((_ key: String) -> Void)?
    /// Opens an agent card's browser full screen. The canvas calls it when the mark at the end of the card's browser bar is tapped.
    @ObservationIgnored var expandBrowser: ((_ cardID: String) -> Void)?
    /// Does what a button drawn on a card is for. The canvas calls it when a tap lands on one.
    @ObservationIgnored var onPress: ((Press) -> Void)?
    #if DEBUG
    /// Goes up whenever what the canvas shows has changed, so the state a test reads is written again.
    private(set) var shownRevision = 0
    @ObservationIgnored private var shownCount = 0
    func didChangeWhatIsShown() {
        // Counted on the side, so that the canvas, which calls this while it is being watched, isn't
        // taken to depend on the count.
        shownCount += 1
        shownRevision = shownCount
    }
    #endif

    func select(_ new: Selection) {
        if selection != new { selection = new }
    }

    /// Adds a card to the ones selected, or takes it out, as a tap does while cards are being selected.
    func toggle(_ id: String) {
        select(.of(selection.cardIDs.symmetricDifference([id])))
    }

    /// Puts an earlier run on show, or the latest with nil.
    func view(_ run: RunRecord?) {
        if viewedRun != run { viewedRun = run }
        #if DEBUG
        if let run { debugLastViewed = run.id }
        #endif
    }

    func noteZoom(_ new: CGFloat) {
        if abs(zoom - new) > 0.004 { zoom = new }
    }

    /// Shows or hides the map, which outlines what is on screen from the moment it comes.
    func setMap(_ on: Bool) {
        showsMap = on
        if on, let view { noteVisible(view.visible) }
    }

    func noteVisible(_ rect: CGRect) {
        // A pan moves this by fractions of a point many times a second. The map only needs whole points.
        if abs(rect.minX - visibleRect.minX) > 1 || abs(rect.minY - visibleRect.minY) > 1 || abs(rect.width - visibleRect.width) > 1 { visibleRect = rect }
    }

    /// Pans so a canvas point is in the middle of the part of the canvas the panels leave clear, as a tap on the map does.
    func look(at point: CGPoint) { view?.look(at: point) }

    /// Pans so a card is in the middle of the part of the canvas the panels leave clear, without changing the zoom.
    func centre(onCard id: String) { view?.centre(onCard: id) }
    /// Zooms so one card fills the clear part of the canvas.
    func zoom(toCard id: String) { view?.zoom(toCard: id) }
    /// Shows the whole flow.
    func fit() { view?.zoomToFit() }
    func terminalsChanged() { view?.attachTerminals() }
}
