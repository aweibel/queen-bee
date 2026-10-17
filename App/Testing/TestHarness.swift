import AppKit
import QueenBeeCore
import SwiftTerm

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

    /// Turns Remote on, pairs and unpairs, for a test copy only. Nil for anything else.
    #if DEBUG
    /// What one connected device has been sent of cards' pages, and how much is waiting for it.
    private static func browsersSeen(_ session: RemoteSession) -> JSONValue {
        ["frames": .number(Double(session.framesSent)), "dropped": .number(Double(session.picturesDropped)),
         "bytes": .number(Double(session.pictureBytes)), "queued": .number(Double(session.queuedNow)),
         "mostQueued": .number(Double(session.mostQueued)), "watching": .array(session.watchedBrowsers.map(JSONValue.string))]
    }
    #endif

    static func handleRemote(_ payload: JSONValue) async -> JSONValue? {
        guard isEnabled else { return nil }
        let host = RemoteHost.shared
        /// A listener's port is known a moment after it starts.
        func soon(_ read: () -> UInt16?) async -> UInt16? {
            for _ in 0..<50 {
                if let port = read() { return port }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        switch payload["op"]?.stringValue {
        case "remote-on":
            // Off and on again is what a device sees when the Mac goes away and comes back.
            host.setOn(payload["on"]?.boolValue ?? true)
            return ["on": .bool(host.isOn)]
        case "remote-pair":
            #if DEBUG
            // A test that drives the iPad app has to tell it the ports before either listener exists.
            host.testPorts = (payload["pairPort"]?.doubleValue.flatMap(UInt16.init(exactly:)), payload["devicePort"]?.doubleValue.flatMap(UInt16.init(exactly:)))
            #endif
            host.beginPairing()
            guard host.pairing != nil else { return ["error": "pairing didn't start"] }
            guard let port = await soon({ host.pairingPort }), let code = host.pairing?.code.text else { return ["error": "pairing didn't start"] }
            return ["code": .string(code), "port": .number(Double(port))]
        case "remote-port":
            let id = payload["device"]?.stringValue ?? ""
            guard let port = await soon({ host.ports[id] }) else { return ["error": "not listening for that device"] }
            return ["port": .number(Double(port))]
        case "remote-state":
            #if DEBUG
            let browsers = JSONValue.array(host.sessions.map(Self.browsersSeen))
            #else
            let browsers = JSONValue.null
            #endif
            return ["on": .bool(host.isOn), "devices": .number(Double(host.devices.devices.count)), "connected": .number(Double(host.sessions.count)),
                    "listening": .number(Double(host.ports.count)), "pairing": .bool(host.pairing != nil),
                    "open": .array(host.sessions.compactMap(\.openFlowName).map(JSONValue.string)),
                    "received": .number(Double(host.sessions.reduce(0) { $0 + $1.received })),
                    "controlling": .number(Double(host.devices.devices.filter(\.canControl).count)),
                    "selected": AppServices.shared.selectedFlowID.map(JSONValue.string) ?? .null,
                    "problem": host.problem.map(JSONValue.string) ?? .null,
                    "browsers": browsers]
        case "remote-reset-queued":
            // Starts counting the most ever queued afresh, from what is queued now.
            #if DEBUG
            host.sessions.forEach { $0.resetMostQueued() }
            #endif
            return [:]
        case "remote-vault":
            // Makes keeping a key fail, the way a locked or broken Keychain would.
            KeyVault.failsWrites = payload["fails"]?.boolValue ?? false
            return [:]
        case "remote-control":
            // The "Can control" switch in Settings.
            host.setCanControl(payload["on"]?.boolValue ?? true, for: payload["device"]?.stringValue ?? "")
            return [:]
        case "remote-remove":
            host.remove(payload["device"]?.stringValue ?? "")
            return [:]
        default:
            return nil
        }
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
            // Choosing the flow already chosen changes nothing, so one that was closed while on screen is opened here.
            controller.open()
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
            guard let cardID, let pid = controller.sessions[cardID]?.view.process.shellPid, pid > 0 else { return ["error": "no process"] }
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
            // A command put in this way is the person's and not typed: what pasting a card or reverting one does. It still has to be allowed.
            patch.command = payload["command"]?.stringValue
            patch.template = payload["template"]?.stringValue
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
        case "browserInput":
            // The same, as mouse and key events arriving at the card's view.
            guard let cardID else { return ["error": "browserInput needs card"] }
            // Without a point it only types, as a person does once they have clicked where they want to.
            let point = payload["x"]?.doubleValue.map { CGPoint(x: $0, y: payload["y"]?.doubleValue ?? 0) }
            let focused = controller.canvas?.testBrowserInput(cardID: cardID, at: point, typing: payload["text"]?.stringValue ?? "")
            return ["focused": focused.map(JSONValue.bool) ?? .null, "focusedCard": controller.focusedCardID.map(JSONValue.string) ?? .null]
        case "rename":
            controller.rename(to: payload["name"]?.stringValue ?? "")
            return [:]
        case "restartOrchestrator":
            // Quits the orchestrator's session and resumes it, as reopening the app does. With `forget`, every
            // session first looks as if an earlier version of the app had started it.
            if payload["forget"]?.boolValue == true { AppServices.shared.testForgetWhatSessionsWereTold() }
            controller.startOrchestrator()
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
        case "browserMakeData":
            // What a browser that has run once leaves behind, without one being started.
            controller.project.browser.testMakeData()
            return ["hasData": .bool(controller.project.browser.hasData)]
        case "macState":
            // What a paired device can change that lives outside any flow: the saved roles, the pinned flows,
            // and the project's browser.
            let services = AppServices.shared
            return [
                "roles": .array(services.roles.map {
                    ["id": .string($0.id), "name": .string($0.name), "instructions": .string($0.instructions), "model": .string($0.model),
                     "effort": .string($0.effort), "permissionMode": .string($0.permissionMode)]
                }),
                "pinned": .array(services.pinnedFlowIDs.sorted().map(JSONValue.string)),
                "browser": .string("\(controller.project.browser.state)"),
                "browserData": .bool(controller.project.browser.hasData),
            ]
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
        case "resize":
            // What a drag of a card's corner ends up doing.
            guard let cardID, let width = payload["width"]?.doubleValue, let height = payload["height"]?.doubleValue else { return ["error": "resize needs card, width and height"] }
            controller.resizeCard(cardID, width: width, height: height)
            return [:]
        case "terminal":
            // What a session's own terminal shows, to set against what a device shows for it.
            guard let cardID else { return ["error": "terminal needs card"] }
            return MirrorWindow.describe(controller.session(forCard: cardID).view)
        case "mirror":
            // A second terminal that sees only what a paired device would be sent.
            guard let cardID else { return ["error": "mirror needs card"] }
            MirrorWindow.show(controller.session(forCard: cardID), shown: payload["shown"]?.boolValue ?? true)
            return [:]
        case "mirror-limit":
            // Makes the kept output small, so a check can see what a long session's mirror starts from.
            guard let cardID, let bytes = payload["bytes"]?.doubleValue else { return ["error": "mirror-limit needs card and bytes"] }
            controller.session(forCard: cardID).view.output.setLimit(Int(bytes))
            return [:]
        case "mirror-close":
            MirrorWindow.close()
            return [:]
        case "mirror-compare":
            guard let cardID else { return ["error": "mirror-compare needs card"] }
            return MirrorWindow.compare(with: controller.session(forCard: cardID))
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
                    "host": .string("\(tab.hostState)"), "watchers": .number(Double(tab.watcherCount)),
                    "canGoBack": .bool(tab.canGoBack), "canGoForward": .bool(tab.canGoForward),
                    "pageWidth": .number(tab.pageSize.width), "pageHeight": .number(tab.pageSize.height),
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
            "holds": .array(controller.holds.map { ["card": .string(controller.flow.card($0.cardID)?.name ?? ""), "text": .string($0.text), "needsAllow": .bool($0.needsAllow), "allowOnMac": .bool($0.allowOnMac == true)] }),
            "selected": .array(controller.flow.cards.filter { controller.selection.cardIDs.contains($0.id) }.map { .string($0.name) }),
            "undo": .string(controller.undoManager.canUndo ? controller.undoManager.undoActionName : ""),
            "isRunning": .bool(controller.isRunning),
            "awaitingAnswer": .array(controller.flow.cards.filter { controller.awaitingAnswer.contains($0.id) }.map { .string($0.name) }),
            "log": .array(controller.log.map { .string($0.text) }),
            "results": .object(results),
            "sessions": .object(sessions),
            "orchestrator": describe(controller.sessions[FlowController.orchestratorKey]),
            "orchestratorNeedsRestart": .bool(controller.orchestratorNeedsRestart),
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

#if DEBUG
/// A second terminal fed only by a session's feed, to check a paired device would see what
/// the real one shows.
enum MirrorWindow {
    private static var window: NSWindow?
    private static var view: TerminalView?
    private static var held: (feed: TerminalFeed, token: UUID)?
    private static var counts = (chunks: 0, bytes: 0, resets: 0, largest: 0)

    /// Opens the mirror part-way through a session. With `shown` off nothing is drawn and the
    /// chunks are only counted, which is what the feed costs by itself.
    static func show(_ session: TerminalSession, shown: Bool) {
        close()
        counts = (0, 0, 0, 0)
        if shown {
            let made = TerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
            made.font = Theme.mono(12)
            let holder = NSView(frame: made.frame)
            holder.addSubview(made)
            let frame = NSWindow(contentRect: made.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            frame.title = "Mirror of \(session.key)"
            frame.contentView = holder
            frame.isReleasedWhenClosed = false
            frame.orderFront(nil)
            view = made
            window = frame
        }
        // The snapshot and the listener are taken in one go, so nothing printed between them is missed.
        take(session.feed.snapshot(), counted: false)
        held = (session.feed, session.feed.addListener { take($0, counted: true) })
    }

    static func close() {
        if let held { held.feed.removeListener(held.token) }
        held = nil
        window?.close()
        window = nil
        view = nil
    }

    /// Does with a chunk what a device does with it.
    private static func take(_ chunk: TerminalChunk, counted: Bool) {
        if counted {
            counts.chunks += 1
            counts.bytes += chunk.data.count
            counts.largest = max(counts.largest, chunk.data.count)
            if chunk.reset { counts.resets += 1 }
        }
        guard let view else { return }
        if chunk.reset {
            // A reset starts from nothing: no screen, no history, no modes left over, and the size the chunk names.
            view.resize(cols: chunk.cols, rows: chunk.rows)
            view.resetToInitialState()
            view.clearScrollback()
            // A point to spare, so rounding can't cost the view a row or a column.
            let fit = view.getOptimalFrameSize().size
            view.setFrameSize(NSSize(width: fit.width + 1, height: fit.height + 1))
            window?.setContentSize(view.frame.size)
        }
        view.feed(byteArray: [UInt8](chunk.data)[...])
    }

    static func compare(with session: TerminalSession) -> JSONValue {
        var result: [String: JSONValue] = [
            "chunks": .number(Double(counts.chunks)), "bytes": .number(Double(counts.bytes)),
            "resets": .number(Double(counts.resets)), "largest": .number(Double(counts.largest)),
            "snapshotBytes": .number(Double(session.view.output.count)),
        ]
        guard let view else { return .object(result) }
        let real = describe(session.view), mirror = describe(view)
        result["real"] = real
        result["mirror"] = mirror
        result["equal"] = .bool(real["screen"] == mirror["screen"] && real["cols"] == mirror["cols"] && real["rows"] == mirror["rows"]
            && real["cursor"] == mirror["cursor"])
        result["historyEqual"] = .bool(real["history"] == mirror["history"])
        return .object(result)
    }

    static func describe(_ view: TerminalView) -> JSONValue {
        let state = view.terminalStateSnapshot()
        let all = String(decoding: view.getBufferAsData(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        return [
            "cols": .number(Double(state.dimensions.cols)), "rows": .number(Double(state.dimensions.rows)),
            "cursor": .array([.number(Double(state.cursor.col)), .number(Double(state.cursor.row))]),
            "screen": .array(state.visibleRows.map { .string($0.text) }),
            "scrollback": .number(Double(max(0, all.count - state.dimensions.rows))),
            "history": .string(all.dropLast(state.dimensions.rows).joined(separator: "\n")),
        ]
    }
}
#endif

