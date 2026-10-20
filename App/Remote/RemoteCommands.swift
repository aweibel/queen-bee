import Foundation
import QueenBeeCore

/// Does what a paired device asks, if that device may control this Mac.
///
/// Every command becomes one call the Mac's own buttons, keyboard or canvas already make, checked the way
/// those are. There is nothing here that adds or removes a project, opens a folder, answers "trust this
/// folder", changes Settings, or pairs or removes a device, so no message from a device can do any of those.
///
/// A command that edits a flow is held to more than the Mac's own canvas is, because the Mac did not see the
/// person make it. It goes through `FlowController.edit(from:)`, which treats it as it treats a change the
/// orchestrator's tools made: a Script card's command written that way is asked about before it runs, and
/// a change to what a scheduled flow does turns its schedules off. No edit here can name an agent's folder,
/// pasting included, and none changes what this Mac's own window is showing or has selected. A schedule is
/// only turned on by `armSchedule`, as by the Mac's own "Turn on", and never by an edit.
///
/// A role saved or updated from a device can't hold a permission mode that skips checks, and changing a role
/// changes no card that has it. The Mac marks it as the device's, keeps what it held before, and asks the person
/// there before first using it; one a device deletes is kept for 30 days to be put back. Downloading a browser is
/// only ever the Mac's own offer taken up. A card's browser is only used, and only seen, from a device with control.
///
/// A device is also held to a pace. It may send a burst of commands, which is what a drag comes to, and then
/// so many a second; past that they are refused. And each kind of edit is put in a flow's log once, with
/// one more line half a minute later saying how many more there were, so no number of edits pushes what
/// else happened out of the log.
enum RemoteCommands {
    /// What a card's browser commands need of the connection they came on: the flow the device has open, whether
    /// it has that card on its screen, which is the only browser it may use, and a way to send Copy's text back.
    struct BrowserDoor {
        let flowID: String?
        let isWatching: (String) -> Bool
        let send: (HostMessage) -> Void
    }

    /// Nil when it was done. Otherwise why not, in words the device shows the person. `paced` is what `pace` said
    /// when the command arrived, for one that waited its turn: it is held to the pace it came at, not to how many
    /// were let go at once when the run in front of them began. Nil to ask now.
    static func obey(_ sent: RemoteCommand, from deviceID: String, browser door: BrowserDoor? = nil, paced: Bool? = nil) async -> String? {
        let host = RemoteHost.shared
        // Asked of the list as it is now, for every command: "Can control" turned off a moment ago is off.
        let device = host.isOn ? host.devices.devices.first(where: { $0.id == deviceID && $0.canControl }) : nil
        // A drag is over the moment the device sends anything but its next step, or may no longer send one.
        if let open = drags[deviceID], device == nil || sent.flowID != open.flowID || sent.dragStep?.drag != open.drag {
            endDrag(of: deviceID)
        }
        guard let device else { return Remote.watchOnlyRefusal }
        // The last step of a drag ends it whatever becomes of the step: refused for its size, for coming too
        // fast, or for a flow or a card that has gone.
        defer { if sent.dragStep?.isLast == true { endDrag(of: deviceID) } }
        // A step of a drag that isn't the last is never answered, so this goes nowhere and the step is dropped.
        guard paced ?? pace(sent, from: deviceID) else { return Remote.tooFastRefusal }
        // Text from a device is entered into terminals as a paste. Nothing in it may end the paste.
        let command = sent.cleaned
        // The size is checked here whatever the device's own app would have let through.
        if let problem = command.problem { return problem }
        let services = AppServices.shared
        // In the log a name is one line and short, whatever the device calls itself.
        let name = Remote.logName(device.name)
        switch command {
        case .newFlow(let projectID, let flowName): return newFlow(named: flowName, inProject: projectID, by: name)
        case .deleteRole(let roleID): return deleteRole(roleID, by: name, deviceID: deviceID)
        case .clearBrowserData(let projectID), .installBrowser(let projectID), .restartBrowser(let projectID):
            return browser(command, inProject: projectID, by: name, deviceID: deviceID)
        default: break
        }
        if let flowID = command.flowID, services.isSharedFlowID(flowID) { return Remote.sharedFlowIDRefusal }
        guard let controller = command.flowID.flatMap(services.deviceFlow) else { return flowGone }
        /// What a card is called in a line of the log.
        func called(_ cardID: String) -> String { controller.flow.card(cardID).map { Remote.logName($0.name, or: "a card") } ?? "a card" }
        /// Says in the flow's log that the device made an edit of this kind, the first time in a while.
        func say(_ kind: Kind, _ line: String, in other: FlowController? = nil) { note(kind, line, in: other ?? controller, by: deviceID, called: name) }
        /// Makes an edit and, if it was made, says so in the log.
        func edit(_ undo: String, key: String? = nil, _ kind: Kind, say line: String, _ body: (inout Flow) throws -> Void) -> String? {
            if let refusal = controller.edit(from: name, undo, key: key, body) { return refusal }
            say(kind, line)
            return nil
        }

        switch command {
        case .openOnMac:
            guard services.environment != nil else { return notReady }
            // What choosing the flow in the sidebar does to its sessions, without choosing it: the Mac's
            // window goes on showing what it showed.
            if !controller.isOpen || controller.hasAgentsHeldBack { controller.noteFromDevice("\(name) started this flow's agents") }
            controller.startAgents()
            return nil

        case .run(_, let command):
            // No button on the Mac gives a run words of its own, so no device may either.
            guard isBlank(command) else {
                return "A run from a device starts with what its Start card says. To run something else, change the Start card on your Mac."
            }
            guard !controller.isRunning else { return alreadyRunning }
            // The Run button is greyed out when the Start card has nothing to start with.
            guard controller.canRun else {
                return "Nothing to run yet: give the Start card something to start with and link it to a card."
            }
            let start = await controller.start(note: "Run started from \(name)")
            return start.began ? nil : start.status

        case .runFrom(_, let cardID, let text):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard !controller.isRunning else { return alreadyRunning }
            guard acceptsInput(card) else { return "Nothing to run: that card takes no input." }
            guard !isBlank(text) else { return "Nothing to run: there is no message to give \(card.name)." }
            let start = await controller.start(from: cardID, message: text, note: "Run started from \(name)")
            return start.began ? nil : start.status

        case .stop:
            guard controller.isRunning else { return "No run is going." }
            controller.noteFromDevice("Stopped from \(name)")
            await controller.stop()
            return nil

        case .approve(_, let holdID, let text):
            guard let hold = controller.holds.first(where: { $0.id == holdID }), hold.kind == .approval else { return holdGone }
            controller.noteFromDevice("\(name) approved the message held at \(called(hold.cardID))")
            controller.approve(holdID, text: text)
            return nil

        case .reject(_, let holdID, let note):
            guard let hold = controller.holds.first(where: { $0.id == holdID }), hold.kind == .approval else { return holdGone }
            // That it was rejected, and by which device. What the note says goes on with the message.
            controller.noteFromDevice("\(name) rejected the message held at \(called(hold.cardID))")
            controller.reject(holdID, note: note)
            return nil

        case .allowScript(_, let holdID):
            // A command a device wrote is allowed at the Mac and nowhere else, whichever device asks.
            return controller.allowScript(holdID, fromDevice: name)

        case .refuseScript(_, let holdID):
            guard let hold = controller.holds.first(where: { $0.id == holdID }), hold.kind == .script else { return holdGone }
            // The Mac only offers "Don't run" while the command is waiting to be allowed.
            guard hold.needsAllow else { return "That command has already been allowed." }
            controller.noteFromDevice("\(name) chose not to run \(called(hold.cardID))'s command")
            controller.refuseScript(holdID)
            return nil

        case .startSession(_, let cardID) where cardID == Remote.orchestratorKey:
            guard services.environment != nil else { return notReady }
            // The orchestrator panel's Start, Restart and "Restart to apply" all start it afresh.
            let state = controller.sessions[cardID]?.state ?? .notStarted
            let did = state == .notStarted ? "started the orchestrator"
                : controller.orchestratorNeedsRestart ? "restarted the orchestrator, so it has the flow's new details" : "restarted the orchestrator"
            controller.noteFromDevice("\(name) \(did)")
            controller.startOrchestrator()
            return nil

        case .startSession(_, let cardID):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard card.kind == .agent else { return "Only an agent card has a session to start." }
            guard services.environment != nil else { return notReady }
            let wasStarted = (controller.sessions[cardID]?.state ?? .notStarted) != .notStarted
            controller.noteFromDevice("\(name) \(wasStarted ? "restarted" : "started") \(called(cardID))'s agent")
            controller.startSession(forCard: cardID)
            return nil

        case .prompt(_, let key, let text):
            guard let session = running(key, in: controller) else { return notRunning }
            session.send(text)
            controller.noteFromDevice("\(name) sent a message to \(key == FlowController.orchestratorKey ? "the orchestrator" : called(key))")
            return nil

        case .keys(_, let key, let data):
            guard let session = running(key, in: controller) else { return notRunning }
            session.type(data)
            // Said once for a burst of typing, and never what was typed.
            if isFirst("\(controller.flow.id)/typing/\(key)", by: deviceID) {
                controller.noteFromDevice("\(name) typed into \(key == FlowController.orchestratorKey ? "the orchestrator" : called(key))")
            }
            return nil

        // MARK: Editing the graph

        case .addCard(_, let kind, let x, let y):
            let spot = FlowController.dropSpot(for: kind, at: CGPoint(x: x, y: y))
            return edit("Add \(kind.label)", .addCard, say: "added \(article(kind.label)) \(kind.label) card") {
                try $0.addCard(kind: kind, x: spot.x, y: spot.y, patch: FlowController.newCardPatch(for: kind))
            }

        case .moveCards(_, let moves, _):
            // Said once for the drag, however many steps it has.
            let isFirstStep = beginDrag(.move, in: controller, by: deviceID)
            let refusal = controller.move(to: moves.mapValues { CGPoint(x: $0.x, y: $0.y) }, by: deviceID)
            if refusal == nil, isFirstStep { say(.move, "moved \(moves.count == 1 ? called(moves.keys.first ?? "") : "\(moves.count) cards")") }
            return refusal

        case .resizeCard(_, let cardID, let frame, _):
            let isFirstStep = beginDrag(.resize(cardID: cardID), in: controller, by: deviceID)
            let refusal = controller.resize(cardID, to: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), by: deviceID)
            if refusal == nil, isFirstStep { say(.resize, "resized \(called(cardID))") }
            return refusal

        case .deleteItems(_, let cardIDs, let linkIDs):
            let cards = Set(cardIDs), links = Set(linkIDs)
            guard cards.allSatisfy({ controller.flow.card($0) != nil }) else { return cardGone }
            guard links.allSatisfy({ id in controller.flow.links.contains { $0.id == id } }) else { return linkGone }
            let what = [cards.isEmpty ? nil : counted(cards.count, "card"), links.isEmpty ? nil : counted(links.count, "link")].compactMap { $0 }
            // What the Mac's Edit menu calls it.
            let undo = cards.count > 1 ? "Delete Cards" : cards.count == 1 ? "Delete Card" : links.count == 1 ? "Delete Link" : "Delete Links"
            let line = cards.count == 1 && links.isEmpty ? "deleted \(called(cardIDs[0]))" : "deleted \(what.joined(separator: " and "))"
            return edit(undo, .delete, say: line) { flow in
                for id in cards { try flow.removeCard(id) }
                // A link at either end of a card that went has gone with it.
                for id in links where flow.links.contains(where: { $0.id == id }) { try flow.removeLink(id) }
            }

        case .addLink(_, let from, let port, let to):
            guard controller.flow.card(from) != nil, controller.flow.card(to) != nil else { return cardGone }
            // When the two can't be linked, the refusal is the Mac's own reason. With no output named, the card's first is meant.
            return edit("Link", .link, say: "linked \(called(from)) to \(called(to))") { try $0.addLink(from: from, port: port, to: to) }

        case .setLinkLimit(_, let linkID, let maxPasses):
            guard let link = controller.flow.links.first(where: { $0.id == linkID }) else { return linkGone }
            return edit("Change Link", key: "link:\(linkID)", .linkLimit, say: "changed the limit of the link from \(called(link.from)) to \(called(link.to))") {
                try $0.updateLink(linkID, maxPasses: maxPasses)
            }

        case .duplicate(_, let cardIDs):
            let ids = Set(cardIDs)
            guard ids.allSatisfy({ controller.flow.card($0) != nil }) else { return cardGone }
            return edit(ids.count == 1 ? "Duplicate Card" : "Duplicate Cards", .duplicate, say: "duplicated \(ids.count == 1 ? called(cardIDs[0]) : counted(ids.count, "card"))") {
                $0.insert($0.fragment(of: ids), dx: 48, dy: 48)
            }

        case .tidy:
            return edit("Tidy Up", .tidy, say: "tidied the flow up") { flow in
                for (id, point) in Tidy.layout(flow) {
                    guard let index = flow.cards.firstIndex(where: { $0.id == id }) else { continue }
                    flow.cards[index].x = point.x
                    flow.cards[index].y = point.y
                }
            }

        // MARK: Groups

        case .group(_, let cardIDs, let groupName):
            guard cardIDs.allSatisfy({ controller.flow.card($0) != nil }) else { return cardGone }
            return edit("Group", .group, say: "grouped \(counted(Set(cardIDs).count, "card"))") { try $0.addGroup(name: groupName, cardIDs: cardIDs) }

        case .ungroup(_, let groupID):
            guard let group = group(groupID, in: controller) else { return groupGone }
            return edit("Ungroup", .ungroup, say: "ungrouped \(Remote.logName(group.name, or: "a group"))") { $0.removeGroup(groupID) }

        case .renameGroup(_, let groupID, let groupName):
            guard let group = group(groupID, in: controller) else { return groupGone }
            return edit("Rename Group", key: "group:\(groupID)", .renameGroup, say: "renamed the group \(Remote.logName(group.name, or: "with no name"))") {
                try $0.updateGroup(groupID, name: groupName)
            }

        case .foldGroup(_, let groupID, let folded):
            guard let group = group(groupID, in: controller) else { return groupGone }
            return edit(folded ? "Fold Group" : "Unfold Group", .foldGroup, say: "\(folded ? "folded" : "unfolded") the group \(Remote.logName(group.name, or: "with no name"))") {
                try $0.updateGroup(groupID, isFolded: folded)
            }

        // MARK: Settings

        case .patchCard(_, let cardID, let patch):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            if patch.trigger != nil || patch.removesTrigger == true, card.kind != .start { return "Only a Start card has a schedule." }
            var role: AgentRole?
            if let roleID = patch.role {
                guard card.kind == .agent else { return "Only an agent card has a role." }
                if !roleID.isEmpty {
                    guard let found = services.roles.first(where: { $0.id == roleID }) else { return "That role is no longer on your Mac." }
                    role = found
                }
            }
            if card.kind == .flow, let ref = patch.flowRef, !ref.isEmpty, ref != card.flowRef {
                // Only a flow of the same project, by its id, and only one that fits: the Mac's own list offers no other.
                guard let inner = controller.project.controller(ref), inner !== controller else { return flowGone }
                if let problem = controller.nestingProblem(placing: inner) { return problem }
            }
            let changes = changed(by: patch)
            return edit("Change \(card.name)", key: "edit:\(cardID)", .settings, say: "changed \(called(cardID))'s \(list(changes))") { flow in
                guard let index = flow.cards.firstIndex(where: { $0.id == cardID }) else { throw FlowError.notFound(cardGone) }
                if let role { try flow.updateCard(cardID, patch: role.patch) }
                if patch.role != nil { flow.cards[index].role = role?.id }
                // A schedule set here is only what the card says. Turning it on is a command of its own, `armSchedule`.
                if let trigger = patch.trigger { flow.cards[index].trigger = trigger }
                if patch.removesTrigger == true { flow.cards[index].trigger = nil }
                // By id: the card may be given a name another card had a moment ago.
                try flow.updateCard(cardID, patch: patch.cardPatch)
            }

        // Made as any other edit from a device is, so a limit that changes what a scheduled flow does turns its
        // schedules off, and those of the flows above it. The Mac's own Flow Settings set these directly.
        case .setFlowOption(_, let option):
            switch option {
            case .subflowLimit(let levels):
                // One place to set it: the flow at the top of every chain that leads here.
                let top = controller.topFlows
                guard top.count == 1, top[0] === controller else {
                    return "The limit is set on \(top.first(where: { $0 !== controller })?.flow.name ?? "the flow above this one")."
                }
                let wanted = Nesting.clamped(levels)
                guard wanted != controller.ownSubflowLimit else { return nil }
                return edit("Change Sub-flow Limit", key: "limit", .flowSettings, say: "changed how deep sub-flows can go") {
                    $0.subflowLimit = wanted == Nesting.usualLimit ? nil : wanted
                }
            case .notifyOrchestrator(let on):
                guard controller.flow.notifyOrchestrator != on else { return nil }
                return edit(on ? "Tell Orchestrator of Runs" : "Stop Telling Orchestrator of Runs", .flowSettings,
                            say: "turned \(on ? "on" : "off") telling the orchestrator when a run ends") { $0.notifyOrchestrator = on }
            case .spendingLimit(let dollars):
                let wanted = SpendingLimit.clamped(dollars)
                guard wanted != controller.flow.spendingLimit else { return nil }
                return edit(wanted == nil ? "Remove Spending Limit" : "Change Spending Limit", key: "spending", .flowSettings,
                            say: wanted.map { "set the spending limit to \(Usage(cost: $0).price) a run" } ?? "removed the spending limit") { $0.spendingLimit = wanted }
            }

        // MARK: Flows

        case .newFlow:
            // Done above: a new flow has no flow to be found.
            return nil

        case .renameFlow(_, let flowName):
            guard flowName != controller.flow.name else { return nil }
            if let taken = nameTaken(flowName, in: controller.project, besides: controller) { return taken }
            let was = Remote.logName(controller.flow.name, or: "a flow with no name")
            controller.rename(to: flowName)
            say(.renameFlow, "renamed this flow from \(was)")
            return nil

        case .deleteFlow:
            let project = controller.project, flowName = controller.flow.name
            // What the person at the Mac is looking at is not taken from under them.
            guard services.current !== controller else { return "That flow is open on your Mac." }
            // A run that has been asked for and not begun yet is a run going.
            guard !controller.isRunning, !controller.isStartingRun else { return "\(flowName) is running. Stop the run before deleting the flow." }
            // A run of a flow above this one could be inside it, or about to be.
            let above = controller.flowsAbove
            if let running = above.first(where: { $0.isRunning || $0.isStartingRun }) {
                return "\(running.flow.name) is running, and \(flowName) is one of its sub-flows. Stop the run before deleting the flow."
            }
            // To the Trash, never gone for good: a mistake on a device, or a device in the wrong hands, destroys no work.
            guard project.delete(controller, toTrash: true) else { return "\(flowName) couldn't be moved to the Trash on your Mac, so it was not deleted." }
            // A flow that ran it now runs nothing there, with nobody having looked.
            let gone = Remote.logName(flowName, or: "a flow")
            for outer in above { outer.turnSchedulesOff(becauseOf: name, changing: gone) }
            // The flow's own log went with it, so it is said where the person at the Mac will see it.
            if let shown = services.current ?? project.controllers.first ?? services.allFlows.first {
                say(.deleteFlow, "deleted the flow \(gone). It is in the Trash", in: shown)
            }
            return nil

        // MARK: Undo

        case .undo:
            let title = controller.undoTitle
            if let refusal = controller.undo(from: name) { return refusal }
            say(.undo, "chose \(Remote.logName(title))")
            return nil

        case .redo:
            let title = controller.redoTitle
            if let refusal = controller.undo(from: name, redo: true) { return refusal }
            say(.redo, "chose \(Remote.logName(title))")
            return nil

        // MARK: Runs and sessions, stage 4

        case .runFromStart(_, let cardID):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard card.kind == .start else { return "Only a Start card starts a run." }
            guard !controller.isRunning else { return alreadyRunning }
            // The Start card's Run button is greyed out when it has nothing to start with, or nothing to give it to.
            guard !isBlank(card.command), !controller.flow.links(from: cardID).isEmpty else {
                return "Nothing to run yet: give \(called(cardID)) something to start with and link it to a card."
            }
            let start = await controller.start(startCardID: cardID, note: "Run started from \(name)")
            return start.began ? nil : start.status

        case .retry(_, let cardID):
            guard controller.flow.card(cardID) != nil else { return cardGone }
            guard !controller.isRunning else { return alreadyRunning }
            // Retry is only offered on a card the last run stopped at: see `FlowController.canRetry`.
            guard controller.marks[cardID]?.failed == true else { return "The last run didn't stop at \(called(cardID)), so there is nothing to retry." }
            guard let last = controller.lastMessage(into: cardID) else { return "There is no message to give this card again." }
            let start = await controller.start(from: cardID, message: last.text, sender: last.from, note: "\(name) retried \(called(cardID))")
            return start.began ? nil : start.status

        case .clearLog:
            // The log's Clear is only there when the log has something in it.
            guard !controller.log.isEmpty else { return "The log is already empty." }
            // What devices did, and every schedule going on or off, stays, and a line says which device cleared the rest.
            controller.clearLog(fromDevice: name)
            return nil

        case .dismissBanner:
            guard let banner = controller.banner else { return "There is no message to close." }
            controller.banner = nil
            // Each time, with what the message said: the person at the Mac didn't see it go.
            let said = Remote.plainLine(banner)
            controller.noteFromDevice("\(name) closed the message: \(said.count > 80 ? String(said.prefix(80)) + "…" : said)")
            return nil

        case .stopAgents:
            guard controller.isRunning || controller.sessions.values.contains(where: { $0.state != .notStarted }) else {
                return "None of this flow's agents is running."
            }
            controller.noteFromDevice("\(name) stopped this flow's agents")
            controller.shutDown()
            return nil

        case .revertSettings(_, let cardID):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard card.kind == .agent else { return "Only an agent card has settings to put back." }
            let pending = controller.settingsAwaitingRestart(forCard: cardID)
            guard !pending.isEmpty, var patch = controller.revertPatch(forCard: cardID) else {
                return "There is nothing to undo: the agent is using these settings."
            }
            // An agent's folder is only ever changed at this Mac, putting it back included.
            patch.cwd = nil
            guard pending != ["folder"] else { return "Only the folder is different, and that can only be put back on your Mac." }
            return edit("Change \(card.name)", key: "edit:\(cardID)", .revert, say: "put \(called(cardID))'s settings back to what its agent is using") {
                try $0.updateCard(cardID, patch: patch)
            }

        case .armSchedule(_, let cardID, let on):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard card.kind == .start else { return "Only a Start card has a schedule." }
            guard let trigger = card.trigger else {
                return "\(called(cardID)) has no schedule to turn \(on ? "on" : "off"). Choose when it runs first."
            }
            guard on != controller.isArmed(card) else { return nil }
            // The Mac's own "Turn on": agreed to for what the card starts with now. A change from a device to what
            // the flow does turns it off again.
            if on { controller.setTrigger(trigger, onCard: cardID) } else { controller.turnScheduleOff(onCard: cardID) }
            // Each time, never counted together with others: it is rare, and it is what lets a flow run unwatched.
            controller.noteFromDevice("\(name) turned the schedule \(on ? "on" : "off") for \(called(cardID))")
            return nil

        // MARK: Editing, stage 4

        case .paste(_, var fragment, let at):
            // A role or a flow is kept by its id, and only one this Mac has, in this project for a flow. By name it
            // could be made to match something else.
            let roles = Set(services.roles.map(\.id))
            let flows = Set(controller.project.controllers.filter { $0 !== controller }.map(\.flow.id))
            for index in fragment.cards.indices {
                if let role = fragment.cards[index].role, !roles.contains(role) { fragment.cards[index].role = nil }
                if let ref = fragment.cards[index].flowRef, !flows.contains(ref) { fragment.cards[index].flowRef = nil }
            }
            // Every card it makes lands on the canvas.
            let asked = FlowController.pasteOffset(of: fragment, at: at.map { CGPoint(x: $0.x, y: $0.y) })
            let offset = fragment.offsetOnCanvas(dx: asked.dx, dy: asked.dy)
            // New ids, names nothing else has, and no session or schedule: see `Flow.insert`. The folder was left
            // behind when the command was cleaned. All or nothing: a link or group that can't be made pastes nothing.
            return edit("Paste", .paste, say: "pasted \(counted(fragment.cards.count, "card"))") {
                try $0.insertWhole(fragment, dx: offset.dx, dy: offset.dy)
            }

        case .addRoleCard(_, let roleID, let x, let y):
            guard let role = services.roles.first(where: { $0.id == roleID }) else { return roleGone }
            let spot = FlowController.dropSpot(for: .agent, at: CGPoint(x: x, y: y))
            return edit("Add \(role.name)", .addCard, say: "added an agent with the role \(Remote.logName(role.name, or: "with no name"))") {
                try FlowController.addAgent(from: role, to: &$0, x: spot.x, y: spot.y)
            }

        case .newSubflow(_, let cardID, let wanted):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard card.kind == .flow else { return "Only a Flow card runs a sub-flow." }
            if let inner = controller.innerFlow(of: card) { return "\(called(cardID)) already runs \(Remote.logName(inner.flow.name, or: "a flow"))." }
            if let problem = controller.newSubflowProblem { return problem }
            guard controller.project.controllers.count < flowLimit else {
                return "This project already has \(flowLimit) flows. Make more on your Mac."
            }
            guard let made = controller.project.newSubflow(named: wanted.isEmpty ? card.name : wanted) else { return "The sub-flow couldn't be saved." }
            var patch = CardPatch()
            patch.flowRef = made.flow.id
            if let refusal = controller.edit(from: name, "Change \(card.name)", key: "edit:\(cardID)", { try $0.updateCard(cardID, patch: patch) }) {
                // Nothing runs the new flow, so it would only be clutter.
                controller.project.delete(made)
                return refusal
            }
            made.noteFromDevice("\(name) made this flow, for \(called(cardID)) in \(Remote.logName(controller.flow.name, or: "a flow"))")
            say(.subflow, "made the sub-flow \(Remote.logName(made.flow.name, or: "with no name")) for \(called(cardID))")
            return nil

        case .pin(_, let on):
            let id = controller.flow.id
            guard services.pinnedFlowIDs.contains(id) != on else { return nil }
            services.togglePin(id)
            say(.pin, on ? "pinned this flow" : "unpinned this flow")
            return nil

        // MARK: Roles

        case .saveRole(_, let cardID, let wanted):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard card.kind == .agent else { return "Only an agent card can be saved as a role." }
            // The Mac offers Update in place of "Save as a New Role" on a card that has one.
            if let current = controller.role(of: card) {
                return "\(called(cardID)) already has the role \(Remote.logName(current.name)). Update that role instead."
            }
            if let problem = roleProblem(card) { return problem }
            let roleName = wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.name : wanted
            // The Mac's own Save replaces a role of the same name. One from a device never does: it could be one
            // the person relies on.
            if services.roles.contains(where: { $0.name.caseInsensitiveCompare(roleName) == .orderedSame }) {
                return "Your Mac already has a role called \(Remote.logName(roleName)). Give this one another name."
            }
            guard services.roles.count < Remote.roleLimit else { return "Your Mac already has \(Remote.roleLimit) roles. Save more on your Mac." }
            var role = AgentRole(from: card)
            role.name = roleName
            // Marked on the Mac as saved from this device, and asked about before the person there first uses it.
            let saved = services.save(role, fromDevice: name)
            if let refusal = controller.edit(from: name, "Save Role", {
                guard let index = $0.cards.firstIndex(where: { $0.id == cardID }) else { throw FlowError.notFound(cardGone) }
                $0.cards[index].role = saved.id
            }) {
                services.deleteRole(saved.id)
                return refusal
            }
            say(.saveRole, "saved \(called(cardID)) as the role \(Remote.logName(saved.name))")
            return nil

        case .updateRole(let roleID, _, let cardID):
            guard let role = services.roles.first(where: { $0.id == roleID }) else { return roleGone }
            guard let card = controller.flow.card(cardID) else { return cardGone }
            // The Mac offers "Update role" on a card that has the role, and nowhere else.
            guard card.kind == .agent, card.role == roleID else {
                return "\(called(cardID)) doesn't have the role \(Remote.logName(role.name)), so it can't update it."
            }
            if let problem = roleProblem(card) { return problem }
            var updated = role
            updated.settings = AgentRole(from: card).settings
            guard updated.settings != role.settings else { return nil }
            // Only the role changes. A card that has it keeps what it has until somebody chooses Reset on it. The Mac
            // marks it as changed from this device, keeps what it held before, and asks before the person there uses it.
            services.save(updated, fromDevice: name)
            say(.updateRole, "updated the role \(Remote.logName(role.name)) from \(called(cardID))")
            return nil

        case .browser(_, let cardID, let action):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard card.kind == .agent, card.browser == true, let tab = controller.browserTab(forCard: cardID) else {
                return "\(called(cardID)) has no browser."
            }
            // What isn't on the device's screen, in the flow it has open, isn't used from it.
            guard let door, door.flowID == controller.flow.id, door.isWatching(cardID) else { return "\(called(cardID))'s browser isn't on this device's screen." }
            // Said once in a while for each card, and never what was typed or where.
            if isFirst("\(controller.flow.id)/browser/\(cardID)", by: deviceID) { controller.noteFromDevice("\(name) used \(called(cardID))'s browser") }
            return await use(tab, action, flowID: controller.flow.id, cardID: cardID, door: door, deviceID: deviceID)

        case .newFlow, .deleteRole, .clearBrowserData, .installBrowser, .restartBrowser:
            // Done above: none of them is for a flow.
            return nil
        }
    }

    /// One thing done in a card's browser, with the calls the Mac's own browser half makes for the person's
    /// mouse, keys and bar.
    private static func use(_ tab: BrowserTab, _ action: RemoteBrowserAction, flowID: String, cardID: String, door: BrowserDoor,
                            deviceID: String) async -> String? {
        let notOpen = "The browser isn't open in that card yet."
        switch action {
        case .mouse(let mouse):
            guard tab.isAttached else { return notOpen }
            let type = switch mouse.kind {
            case .pressed: "mousePressed"
            case .released: "mouseReleased"
            case .moved: "mouseMoved"
            }
            // As the Mac's page view sends them: a move with no button held names none.
            tab.mouse(type, at: CGPoint(x: mouse.x, y: mouse.y), button: mouse.kind == .moved && !mouse.isDown ? "none" : "left",
                      buttons: mouse.isDown ? 1 : 0, clicks: mouse.kind == .moved ? 0 : mouse.clicks, modifiers: mouse.modifiers)
        case .wheel(let x, let y, let dx, let dy):
            guard tab.isAttached else { return notOpen }
            tab.wheel(at: CGPoint(x: x, y: y), dx: dx, dy: dy)
        case .key(let name, let modifiers):
            guard tab.isAttached else { return notOpen }
            guard let key = BrowserKey.named(name) else { return "There is no key called that." }
            tab.press(key, modifiers: modifiers)
        case .text(let text):
            guard tab.isAttached else { return notOpen }
            tab.insert(text: text)
        case .navigate(let typed):
            tab.openTypedFromDevice(typed)
        case .back:
            guard tab.canGoBack else { return "There is no earlier page to go back to." }
            Task { _ = await tab.goBack() }
        case .forward:
            guard tab.canGoForward else { return "There is no later page to go forward to." }
            Task { await tab.goForward() }
        case .reload:
            tab.reload()
        case .copy(let cut):
            guard tab.isAttached else { return notOpen }
            // Asked of the page in a world of the Mac's own, where nothing the page did to itself can answer, and
            // given up on after a few seconds: see `BrowserTab.selectedText(within:)`. The connection goes on
            // reading what else the device sends meanwhile.
            guard let text = await tab.selectedText(within: Remote.browserCopyWait) else {
                return "The page didn't say what is selected in time. Try again in a moment."
            }
            guard !text.isEmpty else { return "Nothing is selected on the page." }
            // "Can control" may have been turned off, or the card taken off the device's screen, while the page was asked.
            let host = RemoteHost.shared
            guard host.isOn, host.devices.canControl(deviceID) else { return Remote.watchOnlyRefusal }
            guard door.isWatching(cardID) else { return "That browser isn't on this device's screen." }
            door.send(.browserCopied(id: flowID, card: cardID, text: String(text.prefix(Remote.browserCopyLimit))))
            if cut { tab.deleteSelection() }
        case .shortcut(let shortcut):
            guard tab.isAttached else { return notOpen }
            tab.shortcut(shortcut)
        }
        return nil
    }

    /// Why a card's settings can't be saved into a role from a device. A mode that skips permission checks
    /// can't be set on a card from anywhere, but a flow's file can hold one, and a role would carry it into
    /// every card that is given it.
    private static func roleProblem(_ card: Card) -> String? {
        // A card's instructions can be longer, typed on the Mac. A role saved from a device is held to what a device may send.
        if !Remote.fitsText(card.instructions ?? "") {
            return "\(Remote.logName(card.name, or: "This card"))'s instructions are too long to save as a role from a device. The most is \(Remote.textLimit) characters. Save it on your Mac."
        }
        guard let mode = card.permissionMode, !mode.isEmpty, !Card.permissionModes.contains(mode) else { return nil }
        return "A role can't skip permission checks. Give \(Remote.logName(card.name, or: "the card")) one of these permissions first: \(Card.permissionModes.joined(separator: ", "))."
    }

    /// Deletes a saved role. Cards made from it keep what it gave them.
    private static func deleteRole(_ roleID: String, by name: String, deviceID: String) -> String? {
        let services = AppServices.shared
        guard let role = services.roles.first(where: { $0.id == roleID }) else { return roleGone }
        // Kept on the Mac for 30 days, where the role menu can put it back.
        services.deleteRole(roleID, fromDevice: name)
        // A role belongs to no flow, so it is said where the person at the Mac will see it.
        if let shown = services.current ?? services.allFlows.first {
            note(.deleteRole, "deleted the role \(Remote.logName(role.name, or: "with no name"))", in: shown, by: deviceID, called: name)
        }
        return nil
    }

    /// Clear browser data, and the Download and Restart the Mac offers, for a project in the sidebar.
    private static func browser(_ command: RemoteCommand, inProject projectID: String, by name: String, deviceID: String) -> String? {
        let services = AppServices.shared
        guard let project = services.projects.first(where: { $0.root.path == projectID }) else {
            return "That project is no longer in your Mac's sidebar."
        }
        let host = project.browser
        let said: (kind: Kind, line: String)
        switch command {
        case .clearBrowserData:
            // The Mac's button is greyed out when there is nothing to clear.
            guard host.hasData else { return "There is no browser data to clear in \(project.name)." }
            Task { await host.clearData() }
            said = (.clearBrowser, "cleared the browser data of \(project.name)")
        case .installBrowser:
            // The card's Download is only there when the Mac has no browser it can use, and it fetches what the
            // Mac decides from where the Mac decides. A device takes up that offer and nothing else.
            if case .downloading = host.state { return "The browser is already downloading." }
            guard host.state == .missing else { return "Your Mac isn't offering to download a browser: it has one it can use, or none has been needed yet." }
            host.download()
            said = (.installBrowser, "started downloading a browser for \(project.name)")
        case .restartBrowser:
            switch host.state {
            case .stopped, .failed: break
            default: return "The browser isn't stopped, so there is nothing to restart."
            }
            host.restart()
            said = (.restartBrowser, "restarted the browser of \(project.name)")
        default:
            return nil
        }
        let shown = services.current.flatMap { $0.project === project ? $0 : nil } ?? project.controllers.first
        if let shown { note(said.kind, said.line, in: shown, by: deviceID, called: name) }
        return nil
    }

    /// A new flow, in a project that is already in the sidebar and nowhere else. The Mac's own window goes
    /// on showing what it showed.
    private static func newFlow(named flowName: String, inProject projectID: String, by name: String) -> String? {
        guard let project = AppServices.shared.projects.first(where: { $0.root.path == projectID }) else {
            return "That project is no longer in your Mac's sidebar."
        }
        guard project.controllers.count < flowLimit else {
            return "This project already has \(flowLimit) flows. Make more on your Mac."
        }
        if let taken = nameTaken(flowName, in: project, besides: nil) { return taken }
        guard let made = project.newFlow(named: flowName, select: false) else { return "The flow couldn't be saved." }
        made.noteFromDevice("\(name) made this flow")
        return nil
    }

    /// A project is not filled with flows from a device without end.
    private static let flowLimit = 200

    /// Why a flow can't be given this name from a device: another flow of the project has it. Nil when it can.
    /// With no name the Mac picks one nothing else has.
    private static func nameTaken(_ wanted: String, in project: ProjectModel, besides own: FlowController?) -> String? {
        let wanted = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, project.controllers.contains(where: { $0 !== own && $0.flow.name.caseInsensitiveCompare(wanted) == .orderedSame }) else { return nil }
        return "This project already has a flow called \(Remote.logName(wanted)). Give this one another name."
    }

    // MARK: Pace

    /// Whether a command is within the pace its device may send at, and counts it. Keys are not counted: a held key
    /// repeats faster than this, and typing is not an edit. The pointer moving and scrolling in a card's page have a
    /// pace of their own, so a drag in it can't use up what the click that ends it needs. Every other use of a card's
    /// browser is counted like any command.
    static func pace(_ sent: RemoteCommand, from deviceID: String) -> Bool {
        if case .keys = sent { return true }
        if case .browser(_, _, let action) = sent, action.isPointer {
            return pointerBuckets[deviceID, default: TokenBucket(capacity: Remote.pointerBurst, refill: Remote.pointersASecond)].take()
        }
        return buckets[deviceID, default: TokenBucket()].take()
    }

    /// How fast each device may send commands, by device id.
    private static var buckets: [String: TokenBucket] = [:]
    /// And how fast it may move the pointer and scroll in cards' pages.
    private static var pointerBuckets: [String: TokenBucket] = [:]

    // MARK: Drags

    /// The drag each device has going, by device id: one at a time, in one flow, and when its last step came.
    private static var drags: [String: (flowID: String, drag: RemoteDrag, heard: Date, watch: Task<Void, Never>)] = [:]
    /// A drag the Mac has heard nothing of for this long is over: the device went quiet without lifting its finger.
    static let dragTimeout: TimeInterval = 2

    /// Called for every step of a drag. Only the first begins anything, and that is what comes back.
    @discardableResult
    private static func beginDrag(_ drag: RemoteDrag, in controller: FlowController, by deviceID: String) -> Bool {
        if drags[deviceID] != nil {
            drags[deviceID]?.heard = Date()
            return false
        }
        let watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let open = drags[deviceID] else { return }
                if Date().timeIntervalSince(open.heard) >= dragTimeout { return endDrag(of: deviceID) }
            }
        }
        drags[deviceID] = (controller.flow.id, drag, Date(), watch)
        controller.beginDrag(from: deviceID)
        return true
    }

    /// Ends the drag a device has going, if it has one: what it moved so far becomes one step of the Mac's
    /// Undo, under the name the Mac gives that kind of drag. Called on the drag's last step, and whenever the
    /// device stops dragging without saying so: it sent something else, opened another flow, lost "Can
    /// control", went, or went quiet.
    static func endDrag(of deviceID: String) {
        guard let open = drags.removeValue(forKey: deviceID) else { return }
        open.watch.cancel()
        let name = switch open.drag {
        case .move: "Move"
        case .resize: "Resize"
        }
        AppServices.shared.deviceFlow(open.flowID)?.endDrag(from: deviceID, name)
    }

    // MARK: The log

    /// The kinds of edit a device makes, each of which is put in a flow's log once in a while.
    private enum Kind: String {
        case addCard, move, resize, delete, link, linkLimit, duplicate, tidy, group, ungroup, renameGroup, foldGroup
        case settings, flowSettings, renameFlow, deleteFlow, undo, redo
        case revert, paste, subflow, pin, saveRole, updateRole, deleteRole
        case clearBrowser, installBrowser, restartBrowser

        /// What the device did, said of any number of them.
        var phrase: String {
            switch self {
            case .addCard: "added a card"
            case .move: "moved cards"
            case .resize: "resized a card"
            case .delete: "deleted cards or links"
            case .link: "linked cards"
            case .linkLimit: "changed a link's limit"
            case .duplicate: "duplicated cards"
            case .tidy: "tidied the flow up"
            case .group: "grouped cards"
            case .ungroup: "ungrouped cards"
            case .renameGroup: "renamed a group"
            case .foldGroup: "folded or unfolded a group"
            case .settings: "changed a card's settings"
            case .flowSettings: "changed the flow's settings"
            case .renameFlow: "renamed this flow"
            case .deleteFlow: "deleted a flow"
            case .undo: "chose Undo"
            case .redo: "chose Redo"
            case .revert: "put an agent's settings back"
            case .paste: "pasted cards"
            case .subflow: "made a sub-flow"
            case .pin: "pinned or unpinned this flow"
            case .saveRole: "saved a role"
            case .updateRole: "updated a role"
            case .deleteRole: "deleted a role"
            case .clearBrowser: "cleared the browser data"
            case .installBrowser: "started downloading a browser"
            case .restartBrowser: "restarted the browser"
            }
        }
    }

    /// How many of each kind of edit each device has made in each flow since the log was last told.
    private static var tally = EditTally()

    /// Puts a line in a flow's log about an edit a device made, if it is the first of its kind there from that
    /// device in a while. The ones after it are counted, and when the while is up one more line says how many
    /// there were. So the log gets two lines at most for each kind of edit in half a minute, whatever a device sends.
    private static func note(_ kind: Kind, _ line: String, in controller: FlowController, by deviceID: String, called name: String) {
        let flowID = controller.flow.id, key = "\(deviceID)/\(flowID)/\(kind.rawValue)"
        guard tally.count(key) else { return }
        controller.noteFromDevice("\(name) \(line)")
        Task {
            try? await Task.sleep(for: .seconds(EditTally.window))
            let extra = tally.close(key)
            guard extra > 0 else { return }
            AppServices.shared.deviceFlow(flowID)?.noteFromDevice("\(name) \(kind.phrase) \(EditTally.more(extra))")
        }
    }

    // MARK: Words

    /// "a Script", "an Agent".
    private static func article(_ word: String) -> String { "aeiou".contains(word.lowercased().prefix(1)) ? "an" : "a" }

    /// "1 card", "3 links".
    private static func counted(_ n: Int, _ thing: String) -> String { "\(n) \(thing)\(n == 1 ? "" : "s")" }

    /// "name", "name and model", "name, model and effort".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "settings" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// What a patch changes, as the Mac's settings panel names them. Never what it changes them to.
    private static func changed(by patch: RemoteCardPatch) -> [String] {
        let named: [(Bool, String)] = [
            (patch.name != nil, "name"), (patch.instructions != nil, "instructions"), (patch.role != nil, "role"), (patch.model != nil, "model"),
            (patch.effort != nil, "effort"), (patch.permissionMode != nil, "permissions"), (patch.command != nil, "command"),
            (patch.trigger != nil || patch.removesTrigger == true, "schedule"), (patch.check != nil || patch.value != nil, "check"),
            (patch.maxTries != nil, "number of tries"), (patch.branches != nil, "branches"), (patch.template != nil, "template"),
            (patch.saveTo != nil, "file to save to"), (patch.text != nil, "text"), (patch.flowRef != nil, "flow"),
            (patch.browser != nil, "browser"),
        ]
        return named.filter(\.0).map(\.1)
    }

    private static func group(_ id: String, in controller: FlowController) -> CardGroup? {
        (controller.flow.groups ?? []).first { $0.id == id }
    }

    private static let alreadyRunning = "A run is already going. Stop it before starting another."
    private static let flowGone = "That flow is no longer on your Mac."
    private static let cardGone = "That card is no longer in the flow."
    private static let linkGone = "That link is no longer in the flow."
    private static let groupGone = "That group is no longer in the flow."
    private static let holdGone = "That is no longer waiting for an answer."
    private static let roleGone = "That role is no longer on your Mac."
    private static let notRunning = "That session isn't running."
    private static var notReady: String { AppServices.shared.problem ?? "Claude Code isn't ready yet." }

    /// When each device last had each kind of thing it does over and over put in the log.
    private static var noted: [String: Date] = [:]
    /// Typing, moving, resizing and changing one setting are each logged at most this often for one device
    /// and one session, flow or card, so keys and the steps of a drag don't flood the log.
    private static let noteEvery: TimeInterval = 30

    /// True when this device doing this hasn't been logged in the last while, and counts it as logged now.
    private static func isFirst(_ what: String, by deviceID: String, now: Date = Date()) -> Bool {
        noted = noted.filter { now.timeIntervalSince($0.value) < noteEvery }
        let id = "\(deviceID)/\(what)"
        guard noted[id] == nil else { return false }
        noted[id] = now
        return true
    }

    private static func isBlank(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A session that is there and running. Looked up without making one: asking the flow for a card's
    /// session makes it, and a device naming a card that has none must not.
    private static func running(_ key: String, in controller: FlowController) -> TerminalSession? {
        guard let session = controller.sessions[key], session.isLive else { return nil }
        return session
    }
}
