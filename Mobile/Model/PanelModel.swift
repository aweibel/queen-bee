import CoreGraphics
import Observation
import QueenBeeCore

/// One page of the panel beside the canvas. What is selected isn't one of them: its details come up over
/// the panel, whichever page is on show, and go when nothing is selected.
enum PanelPage: String, CaseIterable, Identifiable {
    case orchestrator, log, output, runs, cost

    var id: String { rawValue }

    /// Its name, where it shares a tab with another page. The Mac's names for the same things.
    var title: String {
        switch self {
        case .orchestrator: "Orchestrator"
        case .log: "Log"
        case .output: "Output"
        case .runs: "Runs"
        case .cost: "Cost"
        }
    }

    var tab: PanelTab {
        switch self {
        case .orchestrator: .orchestrator
        case .log, .output: .run
        case .runs, .cost: .history
        }
    }
}

/// The panel's tabs, the orchestrator first. Five names don't fit across a column this narrow at a size a
/// finger can hit, so the two pages about the run on show share a tab, and so do the two about every run so far.
enum PanelTab: String, CaseIterable, Identifiable {
    case orchestrator, run, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orchestrator: "Orchestrator"
        case .run: "Run"
        case .history: "History"
        }
    }

    var pages: [PanelPage] { PanelPage.allCases.filter { $0.tab == self } }
}

/// What comes up over the canvas on an iPhone, where there is no room for a panel beside it: the details of
/// what is selected, or the panel's tabs. One at a time.
enum PanelSheet: String, Identifiable {
    case details, tabs

    var id: String { rawValue }
}

/// Which page of the panel is on show. Kept outside the panel's view, so it is the same page when the panel
/// is hidden and brought back, and when the details that came up over it go again.
@Observable
final class PanelModel {
    private(set) var page = PanelPage.orchestrator
    /// How much of the canvas's foot the panel covers, when it is a sheet that comes up over the canvas as
    /// on an iPhone. Nothing when it is beside the canvas, or put away. The canvas fits the flow into what is left.
    var cover: CGFloat = 0
    /// True where the panel and the details are sheets over the canvas, as on an iPhone.
    var usesSheets = false
    /// The sheet has finished coming up. Until then nothing can be put up over it, so a question asked as
    /// something is selected waits for this, and is asked over the sheet once it is there.
    var isSheetSettled = false
    /// A sheet is on the screen, or on its way up or down: set by the sheet itself.
    var isSheetPresented = false
    /// On an iPhone: the panel's tabs were asked for, as a sheet of their own. Selecting something puts them away.
    var showsTabs = false
    /// The details are on the screen, over the panel beside the canvas or in their sheet. Set by the details themselves.
    var isDetailsShown = false
    /// What the way back at the top of the details is called, while they are pushed over the panel: the tab under them.
    var detailsBack: String?
    /// Where on the screen the row of tabs starts, beside the canvas. The details pushed over them put their
    /// bar there too, so the rule under both stays put as the page slides in: a page pushed while the column
    /// is on screen isn't always given the column's room at the top.
    var tabsTop: CGFloat = 0
    /// How tall the row of tabs is, for the details' bar to be as tall.
    var tabsHeight: CGFloat = 0
    /// The page each tab was last left on, so going back to a tab goes back to that page.
    @ObservationIgnored private var left: [PanelTab: PanelPage] = [:]

    func show(_ page: PanelPage) {
        left[page.tab] = page
        if self.page != page { self.page = page }
    }

    func show(_ tab: PanelTab) {
        show(left[tab] ?? tab.pages[0])
    }
}

extension RemoteClient {
    /// Something is selected, so its details are wanted: over the panel beside the canvas, or in a sheet.
    var wantsDetails: Bool { canvas.selection != .none }

    /// What is up over the canvas on an iPhone. The details win: selecting something puts the tabs away. None
    /// while a terminal or a browser is open full screen: a sheet steps aside for it, and is back when it closes.
    var sheet: PanelSheet? {
        guard panel.usesSheets, terminals.expandedKey == nil, browsers.expandedCard == nil else { return nil }
        // A question already put up over the canvas is answered first: nothing can come up over it, and the
        // sheet comes once it has gone. One asked with a sheet up is put up over the sheet instead.
        guard panel.isSheetPresented || !isAskingOverCanvas else { return nil }
        if wantsDetails { return .details }
        return panel.showsTabs ? .tabs : nil
    }

    /// True while the panel or the details are up as a sheet, as on an iPhone, from the moment something is
    /// selected. A question asked then is put up over the sheet: the screen under a sheet can put nothing up
    /// until the sheet has gone, and a question asked as the sheet comes has to wait for it, not go under it.
    var isSheetUp: Bool { sheet != nil }

    /// Something is being asked, or the flow's settings are up: each is put up over whatever is on the screen.
    private var isAskingOverCanvas: Bool {
        edit.asking != nil || settings.asking != nil || settings.showsFlowSettings || controls.asking != nil
    }

    /// The details go back to the page of the panel they came up over. Nothing is selected then.
    func closeDetails() {
        canvas.select(.none)
    }

    /// On an iPhone: the panel's tabs, as a sheet. The details' sheet goes first, and what was selected with it.
    func showTabs() {
        canvas.select(.none)
        panel.showsTabs = true
    }

    /// A sheet was put away, by its Close or by pulling it down.
    func closeSheet(_ sheet: PanelSheet) {
        switch sheet {
        case .details: closeDetails()
        case .tabs: panel.showsTabs = false
        }
    }

    /// What the details are about, as their page is named: a card's, a link's or a group's name, or how many cards.
    var detailsTitle: String {
        switch canvas.selection {
        case .none: return ""
        case .cards(let ids): return "\(ids.count) cards"
        case .card, .link, .group:
            guard let snapshot = mirror.snapshot else { return "" }
            let run = RunOnShow(snapshot, viewed: canvas.viewedRun)
            return Details(selection: canvas.selection, snapshot: snapshot, run: run, siblings: openFlow?.project.flows ?? [])?.title ?? ""
        }
    }
}
