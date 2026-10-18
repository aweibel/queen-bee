#if DEBUG
import Foundation
import QueenBeeCore

/// The steps a test uses to change settings and flows, and what the app tells it back. A test can't type in
/// a box or pick from a menu, so each step calls what the control calls: `focusMoved`, `writeField` and
/// `commitField` for a box, `setField` for a choice, and `newFlow`, `renameFlow` and `deleteFlow` for the
/// list of flows. None of this is in a release build.
///
/// Steps of `-qbDo`, besides those in `DebugLaunch` and `DebugEditing`. A setting is named by what it is a
/// setting of and its name in `FieldKey.Name`: <of> is a card's name, link/<n>, group/<name> or flow.
///   pick:<card>[,<card>…] | pick:link/<n> | pick:group/<name> | pick:none
///                                     select, as taps on the canvas do
///   set:<of>:<setting>:<value>        write it and send it at once, as a choice does, and as a box does
///                                     when it is written in and left
///   write:<of>:<setting>:<value>      put the keyboard in its box and write, and send nothing
///   leave:<of>:<setting>              take the keyboard out of its box, which sends it
///   again:<of>:<setting>              press Try Again or Send Again under it
///   putBack:<of>:<setting>            press Put Back under it
///   list                              go back to the list of flows, as Back does on an iPhone: no flow is open then
///   flowMenu:<flow>                   hold a finger on a flow's row in the list
///   askFlow:new/<project> | askFlow:rename/<flow> | askFlow:delete/<flow>
///                                     press + beside a project, or choose from a flow's menu, which asks first
///   newFlow:<project>[:<name>] | renameFlow:<flow>:<name> | deleteFlow:<flow>
///                                     the same, with what is asked first already answered. With no
///                                     project named, the open flow's
///   flowSettings                      put up the flow's own settings
///   back                              with a made-up run: the Mac is found again, after `away`
/// A value is text, where \n is a new line and @<n> is n letters; a number; on or off; branches with commas
/// between; or a schedule: none, interval/<minutes>, daily/<hour>/<minute>, weekly/<day>,<day>/<hour>/<minute>
/// or file/<path>.
enum DebugSettings {
    /// The setting a step names. What it is a setting of may have been made or renamed a moment ago, and the
    /// Mac's copy of the flow comes a moment after its answer, so it is looked for a few times.
    private static func key(_ of: String, _ name: String, in client: RemoteClient) async -> FieldKey? {
        for _ in 0..<20 {
            if let found = keyNow(of, name, in: client) { return found }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func keyNow(_ of: String, _ name: String, in client: RemoteClient) -> FieldKey? {
        guard let flow = client.mirror.snapshot?.flow, let name = FieldKey.Name(rawValue: name) else { return nil }
        let item: FieldKey.Item?
        if of == "flow" {
            item = .flow
        } else if of.hasPrefix("link/"), let index = Int(of.dropFirst(5)), flow.links.indices.contains(index) {
            item = .link(flow.links[index].id)
        } else if of.hasPrefix("group/") {
            item = (flow.groups ?? []).first { $0.name == of.dropFirst(6) }.map { .group($0.id) }
        } else {
            item = flow.cards.first { $0.name == of }.map { .card($0.id) }
        }
        return item.map { FieldKey(flowID: flow.id, item: $0, name: name) }
    }

    private static func value(_ written: String, for name: FieldKey.Name) -> FieldValue {
        switch name {
        case .maxTries, .limit, .subflowLimit:
            return .number(Int(written) ?? 0)
        case .notify, .browser:
            return .flag(written == "on")
        case .branches:
            return .list(written.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
        case .trigger:
            let parts = written.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            func number(_ index: Int) -> Int { parts.count > index ? Int(parts[index]) ?? 0 : 0 }
            switch parts[0] {
            case "interval": return .schedule(Trigger(kind: .interval, minutes: number(1)))
            case "daily": return .schedule(Trigger(kind: .daily, hour: number(1), minute: number(2)))
            case "weekly":
                let days = (parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { Int($0) }
                return .schedule(Trigger(kind: .weekly, hour: number(2), minute: number(3), weekdays: days))
            case "file": return .schedule(Trigger(kind: .file, path: parts.dropFirst().joined(separator: "/")))
            default: return .schedule(nil)
            }
        default:
            if written.hasPrefix("@"), let count = Int(written.dropFirst()) { return .text(String(repeating: "a", count: count)) }
            return .text(written.replacingOccurrences(of: "\\n", with: "\n"))
        }
    }

    /// Waits until a setting is no longer on its way to the Mac, and says what the Mac made of it.
    private static func settled(_ key: FieldKey, in client: RemoteClient) async -> String? {
        for _ in 0..<100 {
            // A moment first, for the send that leaving a box starts to have begun.
            try? await Task.sleep(for: .milliseconds(50))
            if client.fieldState(key) != .sending { break }
        }
        switch client.fieldState(key) {
        case .refused(let words): return words
        case .unsaved: return RemoteClient.notConnected
        case .untouched, .edited, .sending: return nil
        }
    }

    private static func flow(_ name: String, in client: RemoteClient) -> RemoteFlowSummary? {
        client.mirror.library?.projects.flatMap(\.flows).first { $0.name == name }
    }

    /// The project of that name, or with no name the open flow's.
    private static func project(_ name: String, in client: RemoteClient) -> RemoteProject? {
        name.isEmpty ? client.openFlow?.project : client.mirror.library?.projects.first { $0.name == name }
    }

    /// The work of one step, or nil for a step that isn't one of these.
    static func step(_ step: String, in client: RemoteClient) -> (() async -> String?)? {
        let parts = step.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        let rest = step.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        let noSuch = "Nothing here goes by that name."
        switch parts[0] {
        case "pick":
            return {
                let wanted = rest.split(separator: ",").map(String.init)
                // A card made or renamed a moment ago comes with the Mac's next copy of the flow.
                for _ in 0..<20 where rest != "none" && !rest.contains("/") && !wanted.allSatisfy({ name in client.mirror.snapshot?.flow.cards.contains { $0.name == name } == true }) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let flow = client.mirror.snapshot?.flow else { return noSuch }
                if rest == "none" {
                    client.canvas.select(.none)
                } else if rest.hasPrefix("link/"), let index = Int(rest.dropFirst(5)), flow.links.indices.contains(index) {
                    client.canvas.select(.link(flow.links[index].id))
                } else if rest.hasPrefix("group/"), let group = (flow.groups ?? []).first(where: { $0.name == rest.dropFirst(6) }) {
                    client.canvas.select(.group(group.id))
                } else {
                    client.canvas.select(.of(Set(wanted.compactMap { name in flow.cards.first { $0.name == name }?.id })))
                }
                // A moment, for the details to change and send what the last thing selected was left with.
                try? await Task.sleep(for: .milliseconds(300))
                return nil
            }
        case "set", "write":
            guard parts.count > 2 else { return nil }
            let written = parts.count > 3 ? parts[3] : ""
            return {
                guard let key = await key(parts[1], parts[2], in: client) else { return noSuch }
                let value = value(written, for: key.name)
                if parts[0] == "write" {
                    client.focusMoved(from: nil, to: key)
                    return client.writeField(key, value) ? nil : RemoteClient.notEditing
                }
                // A box is written in and left. A choice is made. Either way it is written and sent.
                switch key.name {
                case .name, .instructions, .command, .value, .template, .saveTo, .text, .groupName, .flowName:
                    client.focusMoved(from: nil, to: key)
                    guard client.writeField(key, value) else { return RemoteClient.notEditing }
                    client.focusMoved(from: key, to: nil)
                    return await settled(key, in: client)
                default:
                    return await client.setField(key, value)
                }
            }
        case "leave", "again", "putBack":
            guard parts.count > 2 else { return nil }
            return {
                guard let key = await key(parts[1], parts[2], in: client) else { return noSuch }
                switch parts[0] {
                case "leave": client.focusMoved(from: key, to: nil)
                case "again": client.sendAgain(key)
                default:
                    client.discardField(key)
                    return nil
                }
                return await settled(key, in: client)
            }
        case "list":
            return {
                client.open(nil)
                // A moment, for the list to be the screen that is on show.
                try? await Task.sleep(for: .milliseconds(700))
                return nil
            }
        case "flowMenu":
            return {
                guard let flow = flow(rest, in: client) else { return noSuch }
                client.settings.flowMenu = flow.id
                return nil
            }
        case "askFlow":
            return {
                let named = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard named.count == 2 else { return noSuch }
                if named[0] == "new" {
                    guard let project = project(named[1], in: client) else { return noSuch }
                    client.askForNewFlow(in: project)
                } else {
                    guard let flow = flow(named[1], in: client), let kind = FlowMenuItem.Kind(rawValue: named[0]),
                          client.flowMenu(for: flow).contains(where: { $0.kind == kind }) else { return noSuch }
                    client.choose(kind, for: flow)
                }
                return nil
            }
        case "newFlow":
            return {
                guard let project = project(parts.count > 1 ? parts[1] : "", in: client) else { return noSuch }
                let refusal = await client.newFlow(in: project.id, name: parts.count > 2 ? parts.dropFirst(2).joined(separator: ":") : "")
                // A moment, for the Mac's list to come with the new flow in it.
                try? await Task.sleep(for: .milliseconds(300))
                return refusal
            }
        case "renameFlow":
            return {
                guard let flow = flow(parts.count > 1 ? parts[1] : "", in: client) else { return noSuch }
                return await client.renameFlow(flow.id, to: parts.count > 2 ? parts.dropFirst(2).joined(separator: ":") : "")
            }
        case "deleteFlow":
            return {
                guard let flow = flow(rest, in: client) else { return noSuch }
                return await client.deleteFlow(flow.id)
            }
        case "flowSettings":
            return {
                client.showFlowSettings()
                return nil
            }
        case "back":
            return {
                client.debugTake(.welcome(RemoteWelcome(version: Remote.version, macName: "Example Mac", canControl: UserDefaults.standard.bool(forKey: "qbControl"))))
                // A moment, for the canvas to see that this device may act again.
                try? await Task.sleep(for: .milliseconds(300))
                return nil
            }
        default:
            return nil
        }
    }

    /// A command that changes a setting or a flow, in a few words: what kind, and which settings.
    private static func summary(_ command: RemoteCommand) -> String? {
        switch command {
        case .patchCard(_, _, let patch):
            let named: [(Bool, String)] = [
                (patch.name != nil, "name"), (patch.instructions != nil, "instructions"), (patch.model != nil, "model"), (patch.effort != nil, "effort"),
                (patch.permissionMode != nil, "permissionMode"), (patch.role != nil, "role"), (patch.browser != nil, "browser"), (patch.command != nil, "command"),
                (patch.trigger != nil, "trigger"), (patch.removesTrigger == true, "removesTrigger"), (patch.check != nil, "check"), (patch.value != nil, "value"),
                (patch.maxTries != nil, "maxTries"), (patch.branches != nil, "branches"), (patch.template != nil, "template"),
                (patch.saveTo != nil, "saveTo"), (patch.text != nil, "text"), (patch.flowRef != nil, "flowRef"),
            ]
            return "patchCard:" + named.filter(\.0).map(\.1).joined(separator: ",")
        case .setLinkLimit(_, _, let passes): return "setLinkLimit:\(passes)"
        case .renameGroup(_, _, let name): return "renameGroup:\(name)"
        case .setFlowOption(_, .subflowLimit(let levels)): return "subflowLimit:\(levels)"
        case .setFlowOption(_, .notifyOrchestrator(let on)): return "notify:\(on ? "on" : "off")"
        case .newFlow(_, let name): return "newFlow:\(name)"
        case .renameFlow(_, let name): return "renameFlow:\(name)"
        case .deleteFlow: return "deleteFlow"
        default: return nil
        }
    }

    private static func state(_ state: FieldEdit<FieldValue>.State) -> (name: String, refusal: Any) {
        switch state {
        case .untouched: ("untouched", NSNull())
        case .edited: ("edited", NSNull())
        case .sending: ("sending", NSNull())
        case .refused(let words): ("refused", words)
        case .unsaved: ("unsaved", NSNull())
        }
    }

    private static func row(_ field: EditField, label: String, in client: RemoteClient) -> [String: Any] {
        let shown = client.shown(field), state = state(client.fieldState(field.key))
        var row: [String: Any] = [
            "name": field.key.name.rawValue, "label": label, "value": shown.words, "shown": field.words(for: shown), "mac": field.mac.words,
            "state": state.name, "refusal": state.refusal, "says": FieldStatus.words(client.fieldState(field.key)) ?? NSNull(),
            "focus": client.settings.fields[field.key]?.hasFocus ?? false,
        ]
        if let limit = field.key.limit, FieldStatus.isNearLimit(shown.count, limit) { row["count"] = "\(shown.count) of \(limit) characters" }
        switch field.control {
        case .line: row["control"] = "line"
        case .text: row["control"] = "text"
        case .choice(let choices):
            row["control"] = "choice"
            row["choices"] = choices.map(\.label)
        case .stepper(let range, _, _):
            row["control"] = "stepper"
            row["range"] = [range.lowerBound, range.upperBound]
        case .branches: row["control"] = "branches"
        case .schedule:
            row["control"] = "schedule"
            row["choices"] = ["When you press Run", "Every so often", "Every day", "On chosen days", "When a file changes"]
        case .toggle: row["control"] = "toggle"
        }
        return row
    }

    /// The settings the details offer for what is selected, and what the list of flows offers, worked out
    /// the way the views work them out.
    static func state(_ client: RemoteClient) -> [String: Any] {
        let settings = client.settings
        var state: [String: Any] = ["editing": client.isEditing, "sent": client.debugSent.compactMap(summary)]
        if let form = client.editForm {
            let check = form.fields.first { $0.key.name == .check }.flatMap { CheckKind(rawValue: client.shown($0).text) }
            state["title"] = form.title
            state["kind"] = form.kind
            state["rows"] = form.rows.map { row -> [String: Any] in
                switch row {
                case .field(let field): self.row(field, label: field.key.name == .value ? check.map(EditForm.valueLabel) ?? field.label : field.label, in: client)
                case .item(let item): ["item": item.style.rawValue, "label": item.label, "value": item.value]
                case .folder(let folder): ["folder": folder, "label": EditForm.folderLine]
                case .open(_, let name): ["open": name]
                case .newSubflow: ["newSubflow": "New sub-flow"]
                case .roleDrift: ["roleDrift": EditForm.roleDrift]
                case .arm(_, let isOn): ["arm": isOn ? "Turn off" : "Turn on"]
                }
            }
            state["actions"] = form.actions.map(\.title)
        }
        // What the foot of the details says, and the button beside it.
        state["foot"] = client.editFoot?.text ?? NSNull()
        state["footButton"] = client.editFoot?.button ?? NSNull()
        // Everything written here that the Mac doesn't have, whatever is selected.
        let flow = client.mirror.snapshot?.flow
        state["kept"] = settings.fields.map { key, field -> [String: Any] in
            let of: String = switch key.item {
            case .card(let id): flow?.card(id)?.name ?? id
            case .link(let id): "link/\(flow?.links.firstIndex { $0.id == id } ?? -1)"
            case .group(let id): "group/\((flow?.groups ?? []).first { $0.id == id }?.name ?? id)"
            case .flow: "flow"
            }
            return ["of": of, "name": key.name.rawValue, "value": field.shown.words, "state": self.state(field.state).name, "focus": field.hasFocus]
        }.sorted { "\($0["of"] ?? "")\($0["name"] ?? "")" < "\($1["of"] ?? "")\($1["name"] ?? "")" }

        // What the Mac has in every card's settings, by the card's name, for a test to read a change back.
        let siblings = client.openFlow?.project.flows ?? []
        let names: [FieldKey.Name] = [.instructions, .model, .effort, .permissionMode, .role, .browser, .command, .trigger, .check, .value, .maxTries, .branches,
                                      .template, .saveTo, .text, .flowRef]
        state["cards"] = Dictionary((flow?.cards ?? []).map { card in
            (card.name, Dictionary(uniqueKeysWithValues: names.compactMap { name -> (String, String)? in
                guard let flow, let value = FieldKey(flowID: flow.id, item: .card(card.id), name: name).macValue(in: flow, siblings: siblings) else { return nil }
                return (name.rawValue, value.words)
            }))
        }) { first, _ in first }
        state["links"] = (flow?.links ?? []).map(\.maxPasses)
        state["flowOptions"] = ["limit": Nesting.clamped(flow?.subflowLimit), "notify": flow?.notifyOrchestrator ?? true] as [String: Any]

        let projects = client.mirror.library?.projects ?? []
        var flows: [String: Any] = [
            "canChange": client.canChangeFlows,
            "add": client.canChangeFlows ? projects.map(\.name) : [],
            "menus": Dictionary(projects.flatMap(\.flows).map { ($0.name, client.flowMenu(for: $0).map(\.title)) }) { first, _ in first },
            "menu": projects.flatMap(\.flows).first { $0.id == settings.flowMenu }?.name ?? NSNull(),
            "refusal": settings.refusal ?? NSNull(),
            "sheet": settings.showsFlowSettings,
            "roles": client.mirror.library?.roles.map(\.name) ?? [],
        ]
        flows["asking"] = settings.asking.map { ["title": FlowAsk.title($0), "message": FlowAsk.message($0), "answer": FlowAsk.answer($0)] } ?? NSNull()
        flows["settings"] = client.flowFields.map { field -> [String: Any] in
            var row = self.row(field, label: field.label, in: client)
            row["help"] = FlowSettingsSheet.help(for: field.key.name) ?? NSNull()
            return row
        }
        state["flows"] = flows
        return state
    }
}
#endif
