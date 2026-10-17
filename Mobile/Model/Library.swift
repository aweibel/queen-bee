import Foundation
import QueenBeeCore
import UIKit

/// The Mac's list of flows as this device lays it out, and what is done to a flow or a project from it: pins,
/// sub-flows under the flows that run them, Find over every flow and card, "Stop Its Agents", and a project's
/// browser. Reading is for every device. What changes the Mac is for one that may control it, and the Mac checks.
extension RemoteClient {
    // MARK: The list

    /// The flows pinned to the top of the Mac's sidebar, from every project, in the Mac's order.
    var pinnedFlows: [RemoteFlowSummary] {
        (mirror.library?.projects ?? []).flatMap(\.flows).filter(\.pinned)
    }

    /// The flow whose Flow card runs the open one, when it is a sub-flow with one such flow: where "Back to" goes.
    var parentOfOpenFlow: RemoteFlowSummary? {
        guard let open = openFlow, let parent = open.flow.parentID else { return nil }
        return open.project.flows.first { $0.id == parent }
    }

    /// "Back to <parent>": the flow that runs this sub-flow takes the canvas's place.
    func goBackToParent() {
        guard let parent = parentOfOpenFlow else { return }
        open(parent.id)
    }

    // MARK: Pins and agents

    func pinCommand(_ flow: RemoteFlowSummary) -> RemoteCommand { .pin(flowID: flow.id, on: !flow.pinned) }

    /// Pin or Unpin, from a flow's menu. The Mac's sidebar changes, and so does every device's list.
    @discardableResult
    func pin(_ flowID: String, on: Bool) async -> String? {
        guard canChangeFlows else { return Self.notConnected }
        return await flowCommand(.pin(flowID: flowID, on: on))
    }

    /// "Stop Its Agents": every session of the flow ends on the Mac, the orchestrator's included, and so does a run.
    /// Asked first, from the flow's menu.
    @discardableResult
    func stopAgents(_ flowID: String) async -> String? {
        guard canChangeFlows else { return Self.notConnected }
        return await flowCommand(.stopAgents(flowID: flowID))
    }

    // MARK: Find

    /// What Find has found for what is written in it, among every flow's name and card names. Nil while nothing is written.
    var found: FindResults? {
        FindResults(settings.search, in: mirror.library)
    }

    /// Goes to something Find found: its flow is opened, and a card in it is selected and put in the middle of the
    /// canvas once the flow is on it.
    func go(to hit: FindResults.Hit) {
        settings.search = ""
        settings.flowMenu = nil
        if let name = hit.card {
            canvas.wantedCard = (hit.flowID, name)
        }
        if mirror.openFlowID != hit.flowID || mirror.openFlowWentAway {
            open(hit.flowID)
        } else {
            showWantedCard()
        }
    }

    /// Called once a flow is on the canvas. A card that Find went to in it is selected, centred, and its details shown.
    func showWantedCard() {
        guard let wanted = canvas.wantedCard, let flow = mirror.snapshot?.flow, flow.id == wanted.flowID else { return }
        canvas.wantedCard = nil
        guard let card = flow.cards.first(where: { $0.name == wanted.name }) else { return }
        canvas.select(.card(card.id))
        canvas.centre(onCard: card.id)
        panel.show(PanelPage.details)
    }

    // MARK: A project's browser

    /// The open flow's project's browser, as the flow's settings show it.
    var browserStatus: BrowserStatus? {
        guard let project = openFlow?.project else { return nil }
        return BrowserStatus(project.browser, project: project.name, canAct: abilities.canAct)
    }

    func browserCommand(_ action: BrowserStatus.Action) -> RemoteCommand? {
        guard let id = openFlow?.project.id else { return nil }
        return switch action {
        case .clear: .clearBrowserData(projectID: id)
        case .download: .installBrowser(projectID: id)
        case .restart: .restartBrowser(projectID: id)
        }
    }

    /// Clear browser data, Download, Restart or Try again, from the flow's settings. What the Mac turns down is said there.
    @discardableResult
    func browser(_ action: BrowserStatus.Action) async -> String? {
        guard abilities.canAct, let command = browserCommand(action) else { return Self.notConnected }
        let refusal = await send(command)
        settings.browserRefusal = refusal
        if let refusal { UIAccessibility.post(notification: .announcement, argument: refusal) }
        return refusal
    }
}

/// A project's flows in order, with each sub-flow under the flow whose Flow card runs it, as the Mac's sidebar has
/// them. A sub-flow that nothing runs, or that more than one flow runs, is listed with the rest, so it isn't lost.
nonisolated enum FlowNesting {
    struct Row: Equatable, Identifiable {
        var flow: RemoteFlowSummary
        var depth: Int
        var id: String { flow.id }
    }

    static func rows(_ flows: [RemoteFlowSummary]) -> [Row] {
        let ids = Set(flows.map(\.id))
        var listed: Set<String> = []
        var rows: [Row] = []
        func add(_ flow: RemoteFlowSummary, _ depth: Int) {
            guard listed.insert(flow.id).inserted else { return }
            rows.append(Row(flow: flow, depth: depth))
            for child in flows where child.parentID == flow.id { add(child, depth + 1) }
        }
        for flow in flows where flow.parentID.map({ !ids.contains($0) }) ?? true { add(flow, 0) }
        // A parent that is itself somebody's child round in a ring would leave its flows out. They are listed at the top.
        for flow in flows { add(flow, 0) }
        return rows
    }
}

/// What Find found: flows whose name has what was written in it, and cards whose name has it, in every project.
nonisolated struct FindResults: Equatable {
    struct Hit: Equatable, Identifiable {
        var flowID: String
        var flowName: String
        var project: String
        /// The card's name, for a card. Nil for a flow.
        var card: String?
        var id: String { "\(flowID)/\(card ?? "")" }
    }

    var flows: [Hit] = []
    var cards: [Hit] = []
    /// Fewer than this many cards are shown, so a word every card has doesn't fill the screen.
    static let most = 60

    var isEmpty: Bool { flows.isEmpty && cards.isEmpty }

    init?(_ query: String, in library: RemoteLibrary?) {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        for project in library?.projects ?? [] {
            for flow in project.flows {
                if flow.name.localizedCaseInsensitiveContains(wanted) {
                    flows.append(Hit(flowID: flow.id, flowName: flow.name, project: project.name))
                }
                for name in flow.cardNames where name.localizedCaseInsensitiveContains(wanted) && cards.count < Self.most {
                    cards.append(Hit(flowID: flow.id, flowName: flow.name, project: project.name, card: name))
                }
            }
        }
    }
}

/// A project's browser, as the Mac's card and flow settings say what it is doing, with the button the Mac offers.
nonisolated struct BrowserStatus: Equatable {
    enum Action: String, Sendable { case clear, download, restart }

    /// What it is doing, in the Mac's words where the Mac has them.
    var words: String
    /// The browser on the Mac it uses, such as "Google Chrome".
    var browser: String?
    /// Download, Try again or Restart, when the Mac offers one and this device may press it.
    var offer: (title: String, action: Action)?
    /// Whether "Clear browser data" is on offer: the browser has kept something, and this device may clear it.
    var canClear: Bool
    var project: String

    static func == (a: BrowserStatus, b: BrowserStatus) -> Bool {
        a.words == b.words && a.browser == b.browser && a.offer?.title == b.offer?.title && a.canClear == b.canClear && a.project == b.project
    }

    static let clearText = "Agent cards with a browser share one set of sign-ins across this project, kept apart from your own browser. "
        + "Clearing signs them out of every site and forgets the pages they kept, for every flow in this project."

    init(_ state: RemoteBrowserState, project: String, canAct: Bool) {
        self.project = project
        browser = state.browser
        canClear = canAct && state.hasData
        switch state.status {
        case .idle: words = state.browser == nil ? "Not running. It starts when an agent with a browser needs it." : "Not running. It starts when an agent with a browser needs it, using \(state.browser ?? "")."
        case .starting: words = "Starting the browser…"
        case .running: words = state.browser.map { "Running, using \($0)." } ?? "Running."
        case .missing:
            words = "Agents' browsers need Chrome, and there isn't one on your Mac. Queen Bee can download a copy for its own use, about 150 MB."
            if canAct { offer = ("Download", .download) }
        case .downloading: words = "Downloading the browser… \(Int(((state.progress ?? 0) * 100).rounded()))%"
        case .stopped:
            words = "Browser stopped"
            if canAct { offer = ("Restart", .restart) }
        case .failed:
            words = state.problem ?? "The browser couldn't start."
            if canAct { offer = ("Try again", .restart) }
        }
    }
}
