#if DEBUG
import Foundation
import QueenBeeCore

/// The steps a test uses for stage 4's controls, and what the app tells it back. Each step calls what the control
/// calls: `act` for what a menu or the editing bar offers, and the functions in `CardTasks.swift` and `Library.swift`
/// for the rest. None of this is in a release build.
///
/// Steps of `-qbDo`, besides those in `DebugLaunch`, `DebugEditing` and `DebugSettings`. A card, a flow and a role
/// go by name, and a point is in the canvas's own points:
///   copy:<card>,<card>… | cut:<card>,…     Copy or Cut, as a card's menu does
///   paste[:<x>,<y>]                       Paste, at a point as on bare canvas, or round the middle of the screen
///   selectAll                             Select All
///   addRole:<role>[:<x>,<y>]              add an agent from a saved role, as the list of cards does
///   snap:on|off                           the editing bar's "Snap to Cards and Grid"
///   map:on|off                            "Show the Map" or "Hide the Map"
///   mapTap:<x>,<y>                        a tap on the map, at a point of the map's own
///   callout:hand | callout:start          "Build it by hand" or "Start the orchestrator" in an empty flow's note
///   closeBanner                           the close button on the message at the top of the flow
///   arm:<card>:on|off                     "Turn on" or "Turn off" for a Start card's schedule
///   role:<card>:<role>|none               pick a role for an agent, or None
///   askSaveRole:<card> | saveRole:<card>[:<name>]
///                                         "Save as a New Role…", asked, or with the name already given
///   updateRole:<card> | resetRole:<card>  "Update role" and Reset
///   askDeleteRole:<role> | deleteRole:<role>
///   askNewSubflow:<card> | newSubflow:<card>[:<name>]
///   openSub:<card>                        a Flow card's Open
///   backTo                                "Back to" the flow that runs the open one
///   clearLog                              the log's Clear, once its question is answered yes
///   pin:<flow>:on|off | askStopAgents:<flow> | stopAgents:<flow>
///   find:<text>                           write in Find over the list of flows
///   findGo:<flow>[/<card>]                tap what Find found
///   browser:clear|download|restart        the flow's settings' browser buttons
/// The presses `runStart:<card>`, `retry:<card>`, `revert:<card>` and `orchestrator` are in `DebugLaunch`.
enum DebugParity {
    /// The work of one step, or nil for a step that isn't one of these.
    static func step(_ step: String, in client: RemoteClient) -> (() async -> String?)? {
        let parts = step.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let rest = parts.dropFirst().joined(separator: ":")
        let noSuch = "Nothing here goes by that name."
        func flow() -> Flow? { client.mirror.snapshot?.flow }
        /// A card of the open flow, once the Mac has sent it: one made a moment ago comes with the next copy of the flow.
        func card(_ name: String) async -> Card? {
            for _ in 0..<20 {
                if let found = flow()?.cards.first(where: { $0.name == name }) { return found }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        func cards(_ names: String) async -> [String] {
            var ids: [String] = []
            for name in names.split(separator: ",") { if let found = await card(String(name)) { ids.append(found.id) } }
            return ids
        }
        /// A saved role, once the Mac's list has it: one saved a moment ago comes with the next list.
        func role(_ name: String) async -> RemoteRole? {
            for _ in 0..<20 {
                if let found = client.mirror.library?.roles.first(where: { $0.name == name }) { return found }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        func listed(_ name: String) -> RemoteFlowSummary? { client.mirror.library?.projects.flatMap(\.flows).first { $0.name == name } }
        func point(_ text: String) -> CGPoint? {
            let at = text.split(separator: ",").compactMap { Double($0) }
            return at.count == 2 ? CGPoint(x: at[0], y: at[1]) : nil
        }
        /// A moment, for what was sent to come back and be drawn.
        func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

        switch parts[0] {
        case "copy", "cut":
            return {
                let ids = await cards(rest)
                guard !ids.isEmpty else { return noSuch }
                return await client.act(parts[0] == "copy" ? .copy(ids) : .cut(ids))
            }
        case "paste":
            return { await client.act(.paste(at: point(rest))) }
        case "selectAll":
            return { await client.act(.selectAll) }
        case "addRole":
            return {
                guard parts.count > 1, let role = await role(parts[1]) else { return noSuch }
                return await client.act(.addRole(role.id, at: parts.count > 2 ? point(parts[2]) : nil))
            }
        case "snap":
            return {
                client.edit.snaps = rest == "on"
                return nil
            }
        case "map":
            return {
                client.canvas.setMap(rest == "on")
                await settle()
                return nil
            }
        case "mapTap":
            return {
                guard let snapshot = client.mirror.snapshot, let at = point(rest) else { return noSuch }
                // What the map does with a finger on it.
                let map = MapLayout(snapshot: snapshot, visible: client.canvas.visibleRect, selected: client.canvas.selection.cardIDs)
                client.canvas.look(at: map.point(at: at))
                await settle()
                return nil
            }
        case "callout":
            return {
                guard client.callout != nil else { return "There is no note to answer." }
                if rest == "hand" { client.buildByHand() } else { client.startOrchestratorFromCallout() }
                await settle()
                return client.controls.refusal?.text
            }
        case "closeBanner":
            return { await client.dismissBanner() }
        case "arm":
            return {
                guard parts.count > 2, let card = await card(parts[1]) else { return noSuch }
                return await client.armSchedule(card.id, on: parts[2] == "on")
            }
        case "role":
            return {
                guard parts.count > 2, let card = await card(parts[1]), let flow = flow() else { return noSuch }
                let id = parts[2] == "none" ? "" : await role(parts[2])?.id
                guard let id else { return noSuch }
                return await client.setField(FieldKey(flowID: flow.id, item: .card(card.id), name: .role), .text(id))
            }
        case "askSaveRole", "saveRole", "updateRole", "resetRole", "askNewSubflow", "newSubflow", "openSub":
            return {
                guard parts.count > 1, let card = await card(parts[1]) else { return noSuch }
                let name = parts.count > 2 ? parts.dropFirst(2).joined(separator: ":") : ""
                switch parts[0] {
                case "askSaveRole": client.askToSaveRole(from: card.id)
                case "saveRole": return await client.saveRole(from: card.id, name: name)
                case "updateRole": return await client.updateRole(from: card.id)
                case "resetRole": return await client.resetRole(card.id)
                case "askNewSubflow": client.askForNewSubflow(for: card.id)
                case "newSubflow":
                    let refusal = await client.newSubflow(for: card.id, name: name)
                    await settle()
                    return refusal
                default:
                    guard client.innerFlow(of: card.id) != nil else { return "This card runs no flow yet." }
                    client.openSubflow(of: card.id)
                    await settle()
                }
                return nil
            }
        case "askDeleteRole", "deleteRole":
            return {
                guard let role = await role(rest) else { return noSuch }
                if parts[0] == "askDeleteRole" {
                    client.askToDeleteRole(role.id)
                    return nil
                }
                return await client.deleteRole(role.id)
            }
        case "backTo":
            return {
                guard client.parentOfOpenFlow != nil else { return "This flow isn't a sub-flow of another." }
                client.goBackToParent()
                await settle()
                return nil
            }
        case "clearLog":
            return { await client.clearLog() }
        case "pin":
            return {
                guard parts.count > 2, let found = listed(parts[1]) else { return noSuch }
                return await client.pin(found.id, on: parts[2] == "on")
            }
        case "askStopAgents":
            return {
                guard let found = listed(rest) else { return noSuch }
                client.choose(.stopAgents, for: found)
                return nil
            }
        case "stopAgents":
            return {
                guard let found = listed(rest) else { return noSuch }
                return await client.stopAgents(found.id)
            }
        case "find":
            return {
                client.settings.search = rest
                return nil
            }
        case "findGo":
            return {
                let named = rest.split(separator: "/", maxSplits: 1).map(String.init)
                guard let found = client.found else { return "Find has nothing written in it." }
                let hits = named.count > 1 ? found.cards.filter { $0.flowName == named[0] && $0.card == named[1] } : found.flows.filter { $0.flowName == named[0] }
                guard let hit = hits.first else { return "Find didn't find that." }
                client.go(to: hit)
                // The flow has to come from the Mac and be put on the canvas before the card is.
                try? await Task.sleep(for: .milliseconds(900))
                return nil
            }
        case "browser":
            return {
                guard let action = BrowserStatus.Action(rawValue: rest) else { return noSuch }
                return await client.browser(action)
            }
        default:
            return nil
        }
    }

    /// What stage 4's controls offer and show, worked out the way the views work it out.
    static func state(_ client: RemoteClient) -> [String: Any] {
        let abilities = client.abilities, edit = client.edit, canvas = client.canvas
        let snapshot = client.mirror.snapshot, flow = snapshot?.flow
        func name(_ id: String) -> String { flow?.card(id)?.name ?? id }
        func rect(_ r: CGRect?) -> Any { r.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] as [String: Any] } ?? NSNull() }
        func button(_ b: PressButton) -> [String: Any] { ["title": b.title, "enabled": b.isEnabled] }
        var state: [String: Any] = [
            "clipboard": edit.clipboard?.cards.map(\.name) ?? NSNull(),
            "snaps": edit.snaps,
            "map": canvas.showsMap,
            "visible": rect(canvas.view?.visible),
            "runMenu": abilities.runMenu.map(button),
            "starts": Dictionary(abilities.starts.map { (name($0.key), button($0.value)) }) { first, _ in first },
            "retry": abilities.retry.keys.map(name).sorted(),
            "orchestrator": abilities.orchestrator.map(button) ?? NSNull(),
            "back": client.parentOfOpenFlow?.name ?? NSNull(),
            "banner": snapshot?.run.banner ?? NSNull(),
            "bannerClose": snapshot?.run.banner != nil && abilities.canAct,
            "canClearLog": client.canClearLog,
            "pinned": client.pinnedFlows.map(\.name),
            "roles": (client.mirror.library?.roles ?? []).map { ["name": $0.name, "instructions": $0.instructions, "model": $0.model] },
        ]
        if let snapshot {
            let map = MapLayout(snapshot: snapshot, visible: canvas.visibleRect, selected: canvas.selection.cardIDs)
            state["mapView"] = rect(map.view)
            state["restart"] = Dictionary(snapshot.run.awaitingRestart.map { (name($0.key), $0.value) }) { first, _ in first }
            let cost = CostSheet(snapshot, run: RunOnShow(snapshot, viewed: canvas.viewedRun), flows: client.openFlow?.project.flows ?? [])
            state["cost"] = [
                "subflows": cost.subflows.map { [$0.name, $0.depth, $0.usage.price] as [Any] },
                "withSubflows": cost.withSubflows?.price ?? NSNull(),
                "outer": cost.outer.map { "\($0.name) \($0.usage.price)" } ?? NSNull(),
                "runSoFar": cost.runSoFar,
                "runTotal": cost.runTotal?.price ?? NSNull(),
            ]
            // What the details show for the selected card besides its settings: the role's drift line and the pending line.
            if let id = canvas.selection.cardID,
               let details = Details(selection: .card(id), snapshot: snapshot, run: RunOnShow(snapshot, viewed: canvas.viewedRun),
                                     siblings: client.openFlow?.project.flows ?? [], roles: client.mirror.library?.roles ?? []) {
                state["pending"] = details.items.first { $0.style == .pending }?.label ?? NSNull()
                state["drift"] = details.items.contains { $0.label == EditForm.roleDrift }
                state["detailRows"] = details.items.filter { $0.style == .row }.map { [$0.label, $0.value] }
                state["scheduleNote"] = details.items.last { $0.style == .note && $0.label.contains("schedule") }?.label ?? NSNull()
            }
        }
        state["callout"] = client.callout.map { ["text": $0.text, "start": $0.start == nil ? NSNull() : "Start the orchestrator", "build": $0.canBuild ? "Build it by hand" : "Close"] as [String: Any] }
            ?? NSNull()
        state["more"] = ["paste": edit.clipboard == nil ? NSNull() : (edit.clipboard?.pasteTitle ?? "Paste"), "selectAll": client.isEditing,
                         "selectAllOnBar": client.isEditing && edit.isSelecting] as [String: Any]
        // The list of flows: each project's rows, with how far down each sub-flow is.
        state["list"] = (client.mirror.library?.projects ?? []).map { project in
            ["project": project.name, "rows": FlowNesting.rows(project.flows).map { [$0.flow.name, $0.depth] as [Any] }] as [String: Any]
        }
        state["find"] = client.found.map { ["flows": $0.flows.map(\.flowName), "cards": $0.cards.map { "\($0.card ?? "") in \($0.flowName)" }] as [String: Any] } ?? NSNull()
        state["browser"] = client.browserStatus.map {
            ["words": $0.words, "offer": $0.offer?.title ?? NSNull(), "canClear": $0.canClear, "refusal": client.settings.browserRefusal ?? NSNull()] as [String: Any]
        } ?? NSNull()
        return state
    }
}
#endif
