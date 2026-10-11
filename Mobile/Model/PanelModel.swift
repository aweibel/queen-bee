import Observation

/// One page of the panel beside the canvas.
enum PanelPage: String, CaseIterable, Identifiable {
    case details, log, output, runs, cost, orchestrator

    var id: String { rawValue }

    /// Its name, where it shares a tab with another page. The Mac's names for the same things.
    var title: String {
        switch self {
        case .details: "Details"
        case .log: "Log"
        case .output: "Output"
        case .runs: "Runs"
        case .cost: "Cost"
        case .orchestrator: "Orchestrator"
        }
    }

    var tab: PanelTab {
        switch self {
        case .details: .details
        case .log, .output: .run
        case .runs, .cost: .history
        case .orchestrator: .orchestrator
        }
    }
}

/// The panel's tabs. Six names don't fit across a column this narrow at a size a finger can hit, so the two
/// pages about the run on show share a tab, and so do the two about every run so far.
enum PanelTab: String, CaseIterable, Identifiable {
    case details, run, history, orchestrator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: "Details"
        case .run: "Run"
        case .history: "History"
        case .orchestrator: "Orchestrator"
        }
    }

    var pages: [PanelPage] { PanelPage.allCases.filter { $0.tab == self } }
}

/// Which page of the panel is on show. Kept outside the panel's view, so it is the same page when the panel
/// is hidden and brought back, and so the canvas can turn the panel to a card's details.
@Observable
final class PanelModel {
    private(set) var page = PanelPage.details
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
