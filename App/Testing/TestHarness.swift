import AppKit
import QueenBeeCore

/// A back door for automated checks, open only when the app is launched with `--testing`.
/// A script asks what the app is showing and does what a person would do with the mouse
/// and keyboard, over the same socket the helper uses. `scripts/e2e.py` is that script.
enum TestHarness {
    /// Always off in a release build, so a copy people download has no back door.
    static var isEnabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--testing")
        #else
        false
        #endif
    }

    /// Questions about the app as a whole, for when no flow is involved.
    static func handleApp(_ payload: JSONValue) -> JSONValue {
        let services = AppServices.shared
        return [
            "problem": services.problem.map(JSONValue.string) ?? .null,
            "environmentReady": .bool(services.environment != nil),
            "claude": services.environment?.claude.map(JSONValue.string) ?? .null,
            "windows": .number(Double(NSApp.windows.filter(\.isVisible).count)),
            "allWindows": .array(NSApp.windows.map { .string("\(type(of: $0)) visible=\($0.isVisible) title=\($0.title)") }),
            "projects": .array(services.openProjectPaths.map(JSONValue.string)),
            "arguments": .array(CommandLine.arguments.dropFirst().map(JSONValue.string)),
        ]
    }

    #if !DEBUG
    /// A release build has no back door: there is nothing here to drive.
    static func handle(_ payload: JSONValue, controller: FlowController) async -> JSONValue { ["error": "not a test build"] }
    #else
    static func handle(_ payload: JSONValue, controller: FlowController) async -> JSONValue {
        let cardRef = payload["card"]?.stringValue
        let cardID = cardRef == FlowController.orchestratorKey ? cardRef : cardRef.flatMap { controller.flow.resolveCard($0)?.id }

        switch payload["op"]?.stringValue {
        case "state":
            return state(of: controller)
        case "select":
            AppServices.shared.selectedFlowID = controller.flow.id
            return [:]
        case "close":
            controller.shutDown()
            return [:]
        case "run":
            return ["status": .string(await controller.run(command: payload["command"]?.stringValue))]
        case "stop":
            await controller.stop()
            return [:]
        case "type":
            guard let cardID, let text = payload["text"]?.stringValue else { return ["error": "type needs card and text"] }
            controller.session(forCard: cardID).send(text)
            return [:]
        case "kill":
            // What a crash looks like from outside: the process is gone without a goodbye.
            guard let cardID, let pid = controller.sessions[cardID]?.view.process?.shellPid, pid > 0 else { return ["error": "no process"] }
            kill(pid, SIGKILL)
            return ["pid": .number(Double(pid))]
        case "restart":
            guard let cardID else { return ["error": "restart needs card"] }
            controller.startSession(forCard: cardID)
            return [:]
        case "edit":
            // Changes a card's settings the way the settings panel does.
            guard let cardID else { return ["error": "edit needs card"] }
            var patch = CardPatch()
            patch.instructions = payload["instructions"]?.stringValue
            patch.model = payload["model"]?.stringValue
            patch.effort = payload["effort"]?.stringValue
            patch.browser = payload["browser"]?.boolValue
            controller.update(cardID, patch)
            return [:]
        case "browserTool":
            // Calls one of the browser tools on a card's tab, as its agent would.
            guard let cardID, let name = payload["name"]?.stringValue else { return ["error": "browserTool needs card and name"] }
            guard let tab = controller.browserTab(forCard: cardID) else { return ["error": "that card has no browser"] }
            let result = await BrowserTools.call(name: name, arguments: payload["arguments"] ?? [:], host: tab)
            return ["text": .string(result.text), "isError": .bool(result.isError), "image": result.image.map(JSONValue.string) ?? .null]
        case "browserDoor":
            // Sends a browser tool-server message through the app's door with a card's own secret, as its helper would.
            guard let cardID else { return ["error": "browserDoor needs card"] }
            let secret = AppServices.shared.credential(for: "\(controller.flow.id)/\(cardID)")
            return await AppServices.shared.handle(WireRequest(kind: "browser-mcp", session: secret, payload: payload["message"] ?? [:]))
        case "browserClick":
            // A click by the person in a card's browser half.
            guard let cardID, let tab = controller.browserTab(forCard: cardID) else { return ["error": "that card has no browser"] }
            let point = CGPoint(x: payload["x"]?.doubleValue ?? 0, y: payload["y"]?.doubleValue ?? 0)
            tab.mouse("mousePressed", at: point, button: "left", buttons: 1, clicks: 1)
            tab.mouse("mouseReleased", at: point, button: "left", clicks: 1)
            return [:]
        case "browserKill":
            // What a browser crash looks like from outside.
            guard let pid = controller.project.browser.testProcessID else { return ["error": "no browser is running"] }
            kill(pid, SIGKILL)
            return ["pid": .number(Double(pid))]
        case "browserRestart":
            controller.project.browser.restart()
            return [:]
        case "browserClear":
            await controller.project.browser.clearData()
            return ["hasData": .bool(controller.project.browser.hasData)]
        case "launchArguments":
            // The command line a card's session would be started with.
            guard let cardID, let card = controller.flow.card(cardID), let environment = AppServices.shared.environment,
                  let spec = ClaudeLauncher.agent(flow: controller.flow, card: card, sessionID: "test", projectRoot: controller.project.root,
                                                  services: AppServices.shared, environment: environment) else { return ["error": "no launch"] }
            return ["arguments": .array(spec.arguments.map(JSONValue.string))]
        case "revert":
            guard let cardID else { return ["error": "revert needs card"] }
            controller.revertSettings(forCard: cardID)
            return [:]
        case "focus":
            controller.canvas?.testFocus(cardID: cardID)
            return [:]
        case "scroll":
            let how = controller.canvas?.testScroll(cardID: cardID, dy: payload["dy"]?.doubleValue ?? -120,
                                                    mode: payload["mode"]?.stringValue ?? "direct", withCommand: payload["command"]?.boolValue ?? false)
            return ["posted": how.map(JSONValue.string) ?? .null]
        case "edgeLink":
            // A link dragged from a card to the canvas's edge, and held there until the card
            // it is for pans into reach.
            guard let cardID, let target = payload["to"]?.stringValue.flatMap({ controller.flow.resolveCard($0)?.id }) else { return ["error": "edgeLink needs card and to"] }
            await controller.canvas?.testEdgeLink(from: cardID, port: payload["port"]?.stringValue ?? "out", to: target,
                                                  edge: payload["edge"]?.stringValue ?? "right")
            return [:]
        case "zoom":
            if let to = payload["to"]?.doubleValue { controller.canvas?.testSetMagnification(to) }
            return [:]
        case "fit":
            // The zoom control's fit button, or a double-click on a card's title.
            if let cardID { controller.canvas?.zoom(toCard: cardID) } else { controller.canvas?.zoomToFit() }
            return [:]
        case "pick":
            // A click on a card's title, or on bare canvas when no card is named.
            controller.select(cardID.map { .card($0) } ?? .none)
            return [:]
        case "add":
            guard let kind = payload["kind"]?.stringValue.flatMap(CardKind.init(rawValue:)) else { return ["error": "add needs kind"] }
            controller.addCard(kind)
            return [:]
        case "hold":
            // Answers the first held message the way the settings panel's buttons do.
            guard let hold = controller.holds.first(where: { cardID == nil || $0.cardID == cardID }) else { return ["error": "nothing is held"] }
            switch payload["answer"]?.stringValue {
            case "approve": controller.approve(hold.id, text: payload["text"]?.stringValue ?? hold.text)
            case "reject": controller.reject(hold.id, note: payload["text"]?.stringValue ?? "")
            case "allow": controller.allowScript(hold.id)
            case "refuse": controller.refuseScript(hold.id)
            default: return ["error": "hold needs answer"]
            }
            return [:]
        case "script":
            guard let cardID, let command = payload["command"]?.stringValue else { return ["error": "script needs card and command"] }
            controller.setScriptCommand(cardID, command)
            return [:]
        case "runFrom":
            guard let cardID, let message = payload["message"]?.stringValue else { return ["error": "runFrom needs card and message"] }
            return ["status": .string(await controller.run(from: cardID, message: message))]
        case "viewRun":
            controller.view(run: payload["run"]?.stringValue)
            return [:]
        case "trigger":
            // Sets what starts runs from a Start card, the way the settings panel does.
            guard let cardID else { return ["error": "trigger needs card"] }
            var trigger: Trigger?
            if let minutes = payload["minutes"]?.doubleValue { trigger = Trigger(kind: .interval, minutes: Int(minutes)) }
            if let path = payload["path"]?.stringValue { trigger = Trigger(kind: .file, path: path) }
            if let hour = payload["hour"]?.doubleValue, let minute = payload["minute"]?.doubleValue {
                let days = (payload["weekdays"]?.arrayValue ?? []).compactMap { $0.doubleValue.map(Int.init) }
                trigger = Trigger(kind: days.isEmpty ? .daily : .weekly, hour: Int(hour), minute: Int(minute), weekdays: days)
            }
            controller.setTrigger(trigger, onCard: cardID)
            return ["next": .array(controller.nextFires.values.map { .number($0.timeIntervalSinceNow) })]
        case "pickMany":
            let ids = (payload["cards"]?.arrayValue ?? []).compactMap { $0.stringValue }.compactMap { controller.flow.resolveCard($0)?.id }
            controller.select(.of(Set(ids)))
            return [:]
        case "openSub":
            guard let cardID else { return ["error": "openSub needs card"] }
            controller.openSubflow(forCard: cardID)
            return ["now": .string(AppServices.shared.current?.flow.name ?? ""), "trail": .number(Double(AppServices.shared.flowTrail.count))]
        case "limit":
            controller.setSubflowLimit(Int(payload["levels"]?.doubleValue ?? 3))
            return [:]
        case "drag":
            // The calls a drag of a card's title bar makes, in order.
            guard let cardID else { return ["error": "drag needs card"] }
            controller.beginGesture()
            let origins = controller.dragOrigins(for: cardID)
            controller.moveCards(from: origins, by: CGSize(width: payload["dx"]?.doubleValue ?? 0, height: payload["dy"]?.doubleValue ?? 0))
            controller.endGesture("Move")
            return ["moved": .number(Double(origins.count))]
        case "tool":
            // Calls one of the orchestrator's tools, as its session would.
            guard let name = payload["name"]?.stringValue else { return ["error": "tool needs name"] }
            let result = await Tools.call(name: name, arguments: payload["arguments"] ?? [:], host: controller)
            return ["text": .string(result.text), "isError": .bool(result.isError)]
        case "retry":
            guard let cardID else { return ["error": "retry needs card"] }
            controller.retry(cardID)
            return [:]
        case "back":
            if let outer = AppServices.shared.flowTrail.dropLast().last { AppServices.shared.goBack(to: outer) }
            return ["now": .string(AppServices.shared.current?.flow.name ?? "")]
        case "tidy":
            controller.tidy()
            return [:]
        case "group":
            controller.groupSelection()
            return [:]
        case "fold":
            guard let group = controller.selectedGroup else { return ["error": "no group is selected"] }
            controller.setFolded(payload["folded"]?.boolValue ?? true, group: group.id)
            return [:]
        case "delete":
            controller.deleteSelection()
            return [:]
        case "undo":
            controller.undo()
            return [:]
        default:
            return ["error": "unknown op"]
        }
    }

    private static func state(of controller: FlowController) -> JSONValue {
        var sessions: [String: JSONValue] = [:]
        for card in controller.flow.cards where card.kind == .agent {
            var described = describe(controller.sessions[card.id]).objectValue ?? [:]
            described["awaitingRestart"] = .array(controller.settingsAwaitingRestart(forCard: card.id).map(JSONValue.string))
            described["instructions"] = .string(card.instructions ?? "")
            described["model"] = card.model.map(JSONValue.string) ?? .null
            described["effort"] = card.effort.map(JSONValue.string) ?? .null
            described["width"] = .number(card.width)
            if let tab = controller.browserTab(forCard: card.id) {
                described["browser"] = [
                    "url": .string(tab.url), "title": .string(tab.title), "attached": .bool(tab.isAttached),
                    "hasPicture": .bool(tab.lastFrame != nil), "pictureWidth": .number(Double(tab.lastFrame?.width ?? 0)),
                    "host": .string("\(tab.hostState)"),
                ]
            } else {
                described["browser"] = .null
            }
            sessions[card.name] = .object(described)
        }
        var results: [String: JSONValue] = [:]
        for (id, text) in controller.results { results[controller.flow.card(id)?.name ?? id] = .string(text) }
        var marks: [String: JSONValue] = [:]
        for (id, mark) in controller.marks {
            var ports: [String: JSONValue] = [:]
            for (port, count) in mark.ports { ports[port] = .number(Double(count)) }
            marks[controller.flow.card(id)?.name ?? id] = [
                "arrivals": .number(Double(mark.arrivals)), "passes": .number(Double(mark.passes)), "ports": .object(ports),
                "lastPort": mark.lastPort.map(JSONValue.string) ?? .null, "holding": .number(Double(mark.holding)), "failed": .bool(mark.failed),
            ]
        }
        return [
            "name": .string(controller.flow.name),
            "cards": .array(controller.flow.cards.map { ["name": .string($0.name), "x": .number($0.x), "y": .number($0.y)] }),
            "links": .number(Double(controller.flow.links.count)),
            "groups": .array((controller.flow.groups ?? []).map { ["name": .string($0.name), "cards": .number(Double($0.cardIDs.count)), "folded": .bool($0.isFolded)] }),
            "armed": .array(controller.flow.cards.filter { controller.isArmed($0) }.map { .string($0.name) }),
            "scheduled": .number(Double(controller.nextFires.count)),
            "flows": .array(controller.project.controllers.map { .string($0.flow.name) }),
            "trail": .number(Double(AppServices.shared.flowTrail.count)),
            "canRun": .bool(controller.canRun),
            "levelsLeft": .number(Double(controller.levelsLeft)),
            "blank": .bool(controller.isBlank),
            "warnings": .object(Dictionary(uniqueKeysWithValues: controller.warnings.map { (controller.flow.card($0.key)?.name ?? $0.key, JSONValue.string($0.value)) })),
            "viewport": .number(Double(controller.viewport.width)),
            "cost": .number(controller.totalUsage.cost),
            "runs": .array(controller.runs.map { ["id": .string($0.id), "outcome": .string($0.outcome.rawValue), "command": .string($0.command)] }),
            "viewedRun": controller.viewedRunID.map(JSONValue.string) ?? .null,
            "messages": .number(Double(controller.messages.values.reduce(0) { $0 + $1.count })),
            "holds": .array(controller.holds.map { ["card": .string(controller.flow.card($0.cardID)?.name ?? ""), "text": .string($0.text), "needsAllow": .bool($0.needsAllow)] }),
            "selected": .array(controller.flow.cards.filter { controller.selection.cardIDs.contains($0.id) }.map { .string($0.name) }),
            "undo": .string(controller.undoManager.canUndo ? controller.undoManager.undoActionName : ""),
            "isRunning": .bool(controller.isRunning),
            "awaitingAnswer": .array(controller.flow.cards.filter { controller.awaitingAnswer.contains($0.id) }.map { .string($0.name) }),
            "log": .array(controller.log.map { .string($0.text) }),
            "results": .object(results),
            "sessions": .object(sessions),
            "orchestrator": describe(controller.sessions[FlowController.orchestratorKey]),
            "banner": controller.banner.map(JSONValue.string) ?? .null,
            "problem": AppServices.shared.problem.map(JSONValue.string) ?? .null,
            "marks": .object(marks),
            "linkPasses": .array(controller.flow.links.map { .number(Double(controller.linkPasses[$0.id] ?? 0)) }),
            "liveLinks": .number(Double(controller.liveLinkIDs.count)),
            "handOffs": .number(Double(controller.handOffs)),
            "activity": .string("\(controller.activity)"),
            "focusedCard": controller.focusedCardID.flatMap { controller.flow.card($0)?.name }.map(JSONValue.string) ?? .null,
            "canvas": controller.canvas?.testViewState ?? .null,
        ]
    }

    private static func describe(_ session: TerminalSession?) -> JSONValue {
        guard let session else { return ["state": "notStarted", "lastReply": .null] }
        return [
            "state": .string(session.state.rawValue),
            "lastReply": session.lastReply.map(JSONValue.string) ?? .null,
            "scrollPosition": .number(session.view.scrollPosition),
            "canScroll": .bool(session.view.canScroll),
        ]
    }
    #endif
}
