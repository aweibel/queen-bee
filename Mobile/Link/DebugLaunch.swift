#if DEBUG
import Foundation
import Network
import Observation
import QueenBeeCore
import QueenBeeLink
import UIKit

/// What a test tells the app as it launches it, and what the app tells the test back. None of this is in
/// a release build. `scripts/e2e.py` is the test.
///
///   -qbPairCode <code>                  start from nothing and pair with this code, with the first Mac found
///   -qbHost <address> -qbPairPort <n> -qbDevicePort <n>
///                                       with the code: pair and connect at these, without looking on the network
///   -qbShow macs|code                   open the pairing screens at the list of Macs, or at entering the code
///   -qbShow settings                    once connected, open the settings
///   -qbShow flows                       once connected, bring out the list of flows on an iPad held upright
///   -qbShow update|pairAgain|localNetwork
///                                       show that full-screen message and nothing else
///   -qbOpen <flow name>                 once connected, open the flow with this name
///   -qbSelect <card name>|link:<n>      once that flow is on the canvas, select the card, or its nth link
///   -qbZoom <n>                         and set the canvas's zoom, where 1 is the Mac's own size
///   -qbZoomCard <card name>             or zoom so that card fills the canvas; with -qbZoom too, the zoom
///                                       is then set from there
///   -qbShow details|log|output|runs|cost|orchestrator
///                                       turn the panel beside the canvas to that page
///   -qbViewRun <n>                      once that flow has runs and none is going, put the nth on show, where
///                                       0 is the oldest the Mac has kept
///   -qbExpand <card name>|orchestrator  once that session has a terminal, open it full screen
///   -qbScrollBack <n>                   and scroll it back n lines, as a finger would
///   -qbCanned <n>                       no Mac at all: play the first n steps of a made-up flow and its
///                                       terminals, as if a Mac had sent them. See `DebugCanned`.
///   -qbGoToWaiting <n>                  once the flow is on the canvas, go to the nth card that is waiting on
///                                       the person, as a tap on its line in the banner does
///   -qbCannedRun <n>                    no Mac at all: play the first n stages of a made-up run, for the
///                                       panels. See `DebugCannedRun`.
///
/// Arguments written this way are read as settings, which is how they get here.
enum DebugLaunch {
    /// Where the Mac listens for this device, when a test said so. Kept so that the app finds the Mac again
    /// when it is launched without arguments. Only a pairing made with arguments sets it.
    struct Direct: Equatable {
        var host: String
        var port: UInt16
        var endpoint: NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any) }
    }

    private static var defaults: UserDefaults { .standard }
    private static func port(_ key: String) -> UInt16? {
        UInt16(exactly: defaults.integer(forKey: key)).flatMap { $0 == 0 ? nil : $0 }
    }

    static var pairCode: PairingCode? { defaults.string(forKey: "qbPairCode").flatMap(PairingCode.init(text:)) }

    static var pairing: NWEndpoint? {
        guard let host = defaults.string(forKey: "qbHost"), let port = port("qbPairPort") else { return nil }
        return Direct(host: host, port: port).endpoint
    }

    static var direct: Direct? {
        guard let host = defaults.string(forKey: "qbHost"), let port = port("qbDevicePort") else { return nil }
        return Direct(host: host, port: port)
    }

    static var show: String? { defaults.string(forKey: "qbShow") }

    /// A full-screen message a test wants to look at, with the words the Mac would send.
    static var stoppedScreen: StoppedScreen.Reason? {
        switch show {
        case "update": .update("Update Queen Bee on this device, so both are on the same version.")
        case "pairAgain": .pairAgain(Remote.unpairedRefusal)
        case "localNetwork": .localNetwork("Example Mac")
        default: nil
        }
    }

    private static var hasOpenedNamedFlow = false

    /// Opens the flow a test named, once, as soon as the Mac has listed it.
    static func openNamedFlow(_ client: RemoteClient) {
        guard !hasOpenedNamedFlow, let name = defaults.string(forKey: "qbOpen") else { return }
        let flow = withObservationTracking {
            client.state == .connected ? client.mirror.library?.projects.flatMap(\.flows).first { $0.name == name } : nil
        } onChange: {
            Task { @MainActor in openNamedFlow(client) }
        }
        if let flow {
            hasOpenedNamedFlow = true
            client.open(flow.id)
        }
    }

    /// Turns the panel beside the canvas to the page a test named.
    static func showNamedPage(_ client: RemoteClient) {
        if let page = show.flatMap(PanelPage.init(rawValue:)) { client.panel.show(page) }
    }

    private static var hasViewedRun = false

    /// Puts an earlier run on show, once, as soon as the Mac has sent the flow's runs and none is going.
    static func viewNamedRun(_ client: RemoteClient) {
        guard !hasViewedRun, defaults.object(forKey: "qbViewRun") != nil else { return }
        let index = defaults.integer(forKey: "qbViewRun")
        let run: RunRecord? = withObservationTracking {
            guard let snapshot = client.mirror.snapshot, !snapshot.run.isRunning, snapshot.runs.indices.contains(index) else { return nil }
            return snapshot.runs[index]
        } onChange: {
            Task { @MainActor in viewNamedRun(client) }
        }
        guard let run else { return }
        hasViewedRun = true
        client.show(run: run.id)
    }

    private static var hasGoneToWaiting = false

    /// Goes to a card that is waiting on the person, once, when the flow has been put on the canvas.
    static func goToNamedWaiting(_ client: RemoteClient) {
        guard !hasGoneToWaiting, defaults.object(forKey: "qbGoToWaiting") != nil else { return }
        let index = defaults.integer(forKey: "qbGoToWaiting")
        let card: WaitingCard? = withObservationTracking {
            guard client.canvas.shownRevision > 0, let snapshot = client.mirror.snapshot else { return nil }
            let waiting = WaitingCard.all(in: snapshot)
            return waiting.indices.contains(index) ? waiting[index] : nil
        } onChange: {
            Task { @MainActor in goToNamedWaiting(client) }
        }
        guard let card else { return }
        hasGoneToWaiting = true
        Task {
            // A moment, so the flow has been fitted to the screen before the canvas is asked to move.
            try? await Task.sleep(for: .milliseconds(800))
            client.go(to: card)
        }
    }

    /// What each page of the panel shows and what floats over the canvas, worked out the way the views work it out.
    static func panelState(_ client: RemoteClient) -> [String: Any] {
        var state: [String: Any] = ["page": client.panel.page.rawValue, "tab": client.panel.page.tab.rawValue]
        guard let snapshot = client.mirror.snapshot else { return state }
        let viewed = client.canvas.viewedRun
        let run = RunOnShow(snapshot, viewed: viewed)
        if let details = Details(selection: client.canvas.selection, snapshot: snapshot, run: run, siblings: client.openFlow?.project.flows ?? []) {
            state["details"] = [
                "title": details.title,
                "kind": details.kind,
                "state": details.state?.rawValue ?? NSNull(),
                "items": details.items.map { ["style": $0.style.rawValue, "label": $0.label, "value": $0.value] },
                "answerLine": details.answerLine,
                "messages": details.messages.map { $0.map { ["from": $0.from, "text": $0.text] } } ?? NSNull(),
                "footer": Details.changes,
            ]
        }
        state["log"] = run.log.map(\.text)
        let names = Dictionary(snapshot.flow.cards.map { ($0.id, $0.name) }) { first, _ in first }
        state["results"] = Dictionary(run.results.map { (names[$0.key] ?? $0.key, $0.value) }) { first, _ in first }
        state["runs"] = RunRow.all(in: snapshot, viewed: viewed).map {
            ["id": $0.id, "started": $0.started, "outcome": $0.outcome.rawValue, "length": $0.length, "command": $0.command,
             "cost": $0.cost ?? NSNull(), "onShow": $0.isOnShow] as [String: Any]
        }
        state["viewedRun"] = viewed?.id ?? NSNull()
        state["lastViewedRun"] = client.canvas.debugLastViewed ?? NSNull()
        let cost = CostSheet(snapshot, run: run)
        func lines(_ all: [CostSheet.Line]) -> [[String]] { all.map { [$0.name, $0.usage.price, $0.usage.tokenCount] } }
        state["cost"] = [
            "total": cost.total.price,
            "sessions": lines(cost.sessions),
            "runTitle": cost.runTitle,
            "runTotal": cost.runTotal?.price ?? NSNull(),
            "runLines": cost.runLines.map(lines) ?? NSNull(),
            "runPending": cost.runPending ?? NSNull(),
        ]
        state["needsYou"] = WaitingCard.all(in: snapshot).map { ["name": $0.name, "reason": $0.reason] }
        return state
    }

    private static var hasExpanded = false

    /// Opens a session's terminal full screen, once, as soon as it has one.
    static func expandNamedTerminal(_ client: RemoteClient) {
        guard !hasExpanded, let name = defaults.string(forKey: "qbExpand") else { return }
        let key: String? = withObservationTracking {
            let key = name == TerminalRegistry.orchestratorKey ? name : client.mirror.snapshot?.flow.cards.first { $0.name == name }?.id
            // The flow has to be on screen first: a cover can't come up over nothing.
            return key.flatMap { client.terminals.sizes[$0] != nil && client.canvas.shownRevision > 0 ? $0 : nil }
        } onChange: {
            Task { @MainActor in expandNamedTerminal(client) }
        }
        guard let key else { return }
        hasExpanded = true
        Task {
            // A moment, so the terminal has been seen in its card before it leaves it.
            try? await Task.sleep(for: .milliseconds(600))
            client.terminals.expand(key)
            let lines = defaults.integer(forKey: "qbScrollBack")
            if lines > 0 {
                try? await Task.sleep(for: .milliseconds(900))
                client.terminals.debugScrollBack(key, lines: lines)
            }
        }
    }

    private static var hasArranged = false

    /// Sets up the canvas the way a test asked, once, when the first flow has been put on it.
    static func arrange(_ canvas: CanvasView, model: CanvasModel, flow: Flow?) {
        guard !hasArranged, let flow else { return }
        hasArranged = true
        if let name = defaults.string(forKey: "qbZoomCard"), let card = flow.cards.first(where: { $0.name == name }) {
            canvas.zoom(toCard: card.id, animated: false)
        }
        // With a card named too, the zoom is set from where that left the canvas.
        if defaults.object(forKey: "qbZoom") != nil {
            canvas.debugSetZoom(CGFloat(defaults.double(forKey: "qbZoom")))
        }
        guard let wanted = defaults.string(forKey: "qbSelect") else { return }
        if wanted.hasPrefix("link:"), let n = Int(wanted.dropFirst(5)), flow.links.indices.contains(n) {
            model.select(.link(flow.links[n].id))
        } else if let card = flow.cards.first(where: { $0.name == wanted }) {
            model.select(.card(card.id))
        }
    }

    static var savedDirect: Direct? {
        get {
            guard let host = defaults.string(forKey: "debugDirectHost"), let port = port("debugDirectPort") else { return nil }
            return Direct(host: host, port: port)
        }
        set {
            defaults.set(newValue?.host, forKey: "debugDirectHost")
            defaults.set(newValue.map { Int($0.port) }, forKey: "debugDirectPort")
        }
    }

    /// Where the app says what state it is in, for a script that can't see the screen:
    /// Library/Caches/qb-state.json in the app's own folder.
    private static var stateFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("qb-state.json")
    }

    /// Writes the state now and again every time any of it changes.
    static func report(_ client: RemoteClient) {
        var fields: [String: Any] = [:]
        withObservationTracking {
            let (name, text): (String, String?) = switch client.state {
            case .unpaired: ("unpaired", nil)
            case .pairing: ("pairing", nil)
            case .lookingForMac: ("lookingForMac", nil)
            case .connecting: ("connecting", nil)
            case .connected: ("connected", nil)
            case .needsUpdate(let text): ("needsUpdate", text)
            case .mustPairAgain(let text): ("mustPairAgain", text)
            }
            fields = [
                "state": name,
                "text": text ?? NSNull(),
                "mac": client.mac?.macName ?? NSNull(),
                "macID": client.mac?.macID ?? NSNull(),
                "device": DeviceIdentity.deviceID,
                "macNotFound": client.macNotFound,
                "localNetworkBlocked": client.localNetworkBlocked,
                "openFlow": client.openFlow?.flow.name ?? NSNull(),
                // The number of cards in the open flow once the Mac has sent it, which is how a test knows it arrived.
                "openFlowCards": client.mirror.snapshot.map { $0.flow.cards.count } ?? NSNull(),
                "pairingProblem": client.pairingProblem ?? NSNull(),
                "flows": client.mirror.library?.projects.flatMap(\.flows).map(\.name) ?? [],
                "hasKey": DeviceIdentity.key != nil,
            ]
            // What the canvas is drawing, written again whenever it changes.
            _ = client.canvas.shownRevision
            fields["canvas"] = client.canvas.view?.debugState ?? NSNull()
            // What each terminal shows, and which is open full screen.
            _ = client.terminals.debugRevision
            fields["terminals"] = client.terminals.debugState
            fields["expanded"] = client.terminals.expandedKey ?? NSNull()
            fields["cannedStep"] = DebugCanned.step
            fields["cannedStage"] = DebugCannedRun.stage
            fields["panel"] = panelState(client)
        } onChange: {
            Task { @MainActor in report(client) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }
}
#endif
