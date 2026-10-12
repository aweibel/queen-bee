import Foundation
import QueenBeeCore

/// Does what a paired device asks, if that device may control this Mac.
///
/// Every command becomes one call the Mac's own buttons, keyboard or canvas already make, checked the way
/// those are. There is nothing here that adds or removes a project, opens a folder, changes Settings or a
/// saved role, or pairs or removes a device, so no message from a device can do any of those.
///
/// A command that edits a flow is held to more than the Mac's own canvas is, because the Mac did not see the
/// person make it. It goes through `FlowController.edit(from:)`, which treats it as it treats a change the
/// orchestrator's tools made: a Script card's command written that way is asked about before it runs, and
/// a change to what a scheduled flow does turns its schedules off. No edit here can name an agent's folder
/// or turn a schedule on, and none changes what this Mac's own window is showing or has selected.
///
/// A device is also held to a pace. It may send a burst of commands, which is what a drag comes to, and then
/// so many a second; past that they are refused. And each kind of edit is put in a flow's log once, with
/// one more line half a minute later saying how many more there were, so no number of edits pushes what
/// else happened out of the log.
enum RemoteCommands {
    /// Nil when it was done. Otherwise why not, in words the device shows the person.
    static func obey(_ sent: RemoteCommand, from deviceID: String) async -> String? {
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
        // Keys are not counted: a held key repeats faster than this, and typing is not an edit.
        if case .keys = sent {} else if !buckets[deviceID, default: TokenBucket()].take() {
            // A step of a drag that isn't the last is never answered, so this goes nowhere and the step is dropped.
            return Remote.tooFastRefusal
        }
        // Text from a device is entered into terminals as a paste. Nothing in it may end the paste.
        let command = sent.cleaned
        // The size is checked here whatever the device's own app would have let through.
        if let problem = command.problem { return problem }
        let services = AppServices.shared
        // In the log a name is one line and short, whatever the device calls itself.
        let name = Remote.logName(device.name)
        if case .newFlow(let projectID, let flowName) = command { return newFlow(named: flowName, inProject: projectID, by: name) }
        guard let controller = services.allFlows.first(where: { $0.flow.id == command.flowID }) else { return flowGone }
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
                // A schedule set here is only what the card says. Turning it on is done at this Mac and nowhere else.
                if let trigger = patch.trigger { flow.cards[index].trigger = trigger }
                if patch.removesTrigger == true { flow.cards[index].trigger = nil }
                // By id: the card may be given a name another card had a moment ago.
                try flow.updateCard(cardID, patch: patch.cardPatch)
            }

        case .setFlowOption(_, let option):
            switch option {
            case .subflowLimit(let levels):
                // One place to set it: the flow at the top of every chain that leads here.
                let top = controller.topFlows
                guard top.count == 1, top[0] === controller else {
                    return "The limit is set on \(top.first(where: { $0 !== controller })?.flow.name ?? "the flow above this one")."
                }
                guard Nesting.clamped(levels) != controller.ownSubflowLimit else { return nil }
                controller.setSubflowLimit(levels)
                say(.flowSettings, "changed how deep sub-flows can go")
            case .notifyOrchestrator(let on):
                guard controller.flow.notifyOrchestrator != on else { return nil }
                controller.setNotifiesOrchestrator(on)
                say(.flowSettings, "turned \(on ? "on" : "off") telling the orchestrator when a run ends")
            }
            return nil

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
        }
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

    /// How fast each device may send commands, by device id.
    private static var buckets: [String: TokenBucket] = [:]

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
        AppServices.shared.allFlows.first { $0.flow.id == open.flowID }?.endDrag(from: deviceID, name)
    }

    // MARK: The log

    /// The kinds of edit a device makes, each of which is put in a flow's log once in a while.
    private enum Kind: String {
        case addCard, move, resize, delete, link, linkLimit, duplicate, tidy, group, ungroup, renameGroup, foldGroup
        case settings, flowSettings, renameFlow, deleteFlow, undo, redo

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
            AppServices.shared.allFlows.first { $0.flow.id == flowID }?.noteFromDevice("\(name) \(kind.phrase) \(EditTally.more(extra))")
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
