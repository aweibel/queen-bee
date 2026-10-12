#if DEBUG
import Foundation
import QueenBeeCore
import UIKit

/// The steps a test uses to edit a flow, and what the app tells it back. A test can't put a finger on the
/// screen, so each step calls what a finger's recogniser calls, with the canvas point the finger would be
/// at: `beginDrag`, `continueDrag` and `endDrag`, `tap` and `showMenu` on the canvas, and `act` for a choice
/// from a menu or the bar. None of this is in a release build.
///
/// Steps of `-qbDo`, besides those in `DebugLaunch`. A card, a group and a kind go by name, a link by its
/// place in the flow, and a point is in the canvas's own points:
///   edit:on|off                       press Edit, or Done
///   select:on|off                     press Select
///   zoom:<n>                          set the canvas's zoom
///   down:title/<card>                 put a finger down on a card's title bar
///        grip/<card>                  on its corner
///        port/<card>[/<output>]       on one of its output dots: the first, or the one named
///        body/<card>                  inside it, under the title
///        group/<group>                on a group's name
///        at/<x>,<y>                   at a point
///   to:<dx>,<dy>[,<n>]                move it that far from where it came down, in n moves
///   over:<card>                       move it to the middle of a card
///   edge:<left|right|top|bottom>[:<card>]
///                                     hold it just inside an edge of the screen, until it is over that card
///   up                                lift it, and wait for the Mac's answer if the Mac is told anything
///   move:<card>:<dx>,<dy>             all of a move: down on the title bar, four moves, up
///   resize:<card>:<dx>,<dy>           and of a resize, by the corner
///   link:<card>[/<output>]:<card>     and of a link, from an output to another card
///   box:<x0>,<y0>,<x1>,<y1>           and of a box drawn round cards
///   tap:<card> | tap:at/<x>,<y>       tap
///   hold:<card> | hold:link/<n> | hold:group/<group> | hold:at/<x>,<y>
///                                     hold a finger there, which puts up a menu
///   choose:<title>                    choose from the menu that is up
///   addList                           press the bar's add button
///   add:<kind>[:<x>,<y>]              add a card of that kind, at a point or in the middle of the screen
///   delete:<card>,<card>… | delete:link/<n>
///   duplicate:<card>,… | group:<card>,… | ungroup:<group> | fold:<group>:on|off | rename:<group>:<name>
///   undo | redo | tidy                as their buttons do
///   voice:<card>:<action>             do one of the things VoiceOver offers on a card, by its name
///   mac:<what>                        have the made-up Mac do something by itself: see `DebugCannedRun.macDoes`
///   viewRun:<n>                       put the nth run the Mac has kept on show, where 0 is the oldest
///   openFlow:<name>                   open another flow, as a tap on it in the list does
/// A delete here is one already confirmed: `choose:Delete` is the way to see what is asked first.
enum DebugEditing {
    /// Whether the finger a test put down has moved since. One that hasn't is a tap, and begins no drag.
    private static var fingerMoved = false

    /// The work of one editing step, or nil for a step that isn't one of these.
    static func step(_ step: String, in client: RemoteClient) -> (() async -> String?)? {
        let parts = step.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let rest = parts.dropFirst().joined(separator: ":")
        func flow() -> Flow? { client.mirror.snapshot?.flow }
        func card(_ name: String) -> Card? { flow()?.cards.first { $0.name == name } }
        func cards(_ names: String) -> [String] { names.split(separator: ",").compactMap { card(String($0))?.id } }
        func group(_ name: String) -> CardGroup? { (flow()?.groups ?? []).first { $0.name == name } }
        func numbers(_ text: String) -> [Double] { text.split(separator: ",").compactMap { Double($0) } }
        /// The canvas, once the flow is on it.
        func canvas() async -> CanvasView? {
            for _ in 0..<50 {
                if let view = client.canvas.view, client.canvas.shownRevision > 0 { return view }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return client.canvas.view
        }
        /// Where a finger goes for something named as `down:` names it.
        func point(_ place: String, on view: CanvasView) -> CGPoint? {
            let named = place.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard named.count > 1 else { return card(place).map { CGPoint(x: $0.x + $0.width / 2, y: $0.y + CanvasGeometry.titleHeight / 2) } }
            switch named[0] {
            case "at":
                let at = numbers(named[1])
                return at.count == 2 ? CGPoint(x: at[0], y: at[1]) : nil
            case "group":
                return view.groupViews.values.first { $0.look.group.name == named[1] }.map { CGPoint(x: $0.handle.midX, y: $0.handle.midY) }
            case "link":
                guard let flow = flow(), let index = Int(named[1]), flow.links.indices.contains(index),
                      let route = CanvasGeometry.route(of: flow.links[index], in: flow) else { return nil }
                return LinkRouter.labelPoint(of: route)
            default:
                guard let card = card(named[1]) else { return nil }
                let frame = CanvasGeometry.frame(of: card)
                switch named[0] {
                case "title": return CGPoint(x: frame.midX, y: frame.minY + CanvasGeometry.titleHeight / 2)
                case "grip": return CGPoint(x: frame.maxX - CanvasGeometry.resizeHandle / 2, y: frame.maxY - CanvasGeometry.resizeHandle / 2)
                case "port": return CanvasGeometry.outputPoint(of: card, port: named.count > 2 ? named[2] : ports(of: card).first ?? "out")
                case "body": return CGPoint(x: frame.midX, y: frame.minY + CanvasGeometry.titleHeight + (frame.height - CanvasGeometry.titleHeight) / 2)
                default: return nil
                }
            }
        }
        /// Puts the finger over a canvas point. A finger is only ever on the screen, so if the point is off it,
        /// or in the strip along an edge where a drag pans, the canvas is brought round first.
        func put(fingerAt at: CGPoint, on view: CanvasView) {
            if !view.panBounds.insetBy(dx: 60, dy: 60).contains(view.document.convert(at, to: view)) { view.debugCentre(on: at) }
            view.finger = view.document.convert(at, to: view)
        }
        func down(_ place: String, on view: CanvasView) -> Bool {
            guard let at = point(place, on: view) else { return false }
            put(fingerAt: at, on: view)
            fingerMoved = false
            let meaning = view.down(at: at)
            let taken = view.beginDrag(at: at)
            client.edit.debugDowns.append((describe(meaning, in: client), taken))
            return taken
        }
        /// Moves the finger to a canvas point, in so many moves, a little apart as a finger's are.
        func drag(to end: CGPoint, moves: Int, on view: CanvasView) async {
            let start = view.finger.map { view.canvasPoint(at: $0) } ?? client.edit.grabbedAt
            fingerMoved = true
            for move in 1...max(moves, 1) {
                let part = CGFloat(move) / CGFloat(max(moves, 1))
                let now = CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part)
                put(fingerAt: now, on: view)
                view.continueDrag(to: now)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        func travelled(_ text: String) -> (to: CGPoint, moves: Int)? {
            let by = numbers(text), from = client.edit.grabbedAt
            return by.count >= 2 ? (CGPoint(x: from.x + by[0], y: from.y + by[1]), by.count > 2 ? Int(by[2]) : 1) : nil
        }
        func lift(on view: CanvasView) async -> String? {
            let point = fingerMoved ? view.finger.map { view.canvasPoint(at: $0) } : nil
            return await view.endDrag(at: point)?.value ?? nil
        }
        func act(_ action: EditAction?, confirmed: Bool = false) -> (() async -> String?) {
            { if let action { await client.act(action, confirmed: confirmed) } else { "Nothing here goes by that name." } }
        }

        switch parts[0] {
        case "edit":
            return {
                _ = await canvas()
                client.setEditing(rest == "on")
                // A moment, for the bar to come or go: the canvas moves over to keep clear of it.
                try? await Task.sleep(for: .milliseconds(700))
                return nil
            }
        case "select":
            return {
                client.edit.isSelecting = rest == "on"
                return nil
            }
        case "zoom":
            return {
                if let zoom = Double(rest) { await canvas()?.debugSetZoom(CGFloat(zoom)) }
                return nil
            }
        case "down":
            return {
                guard let view = await canvas() else { return nil }
                _ = down(rest, on: view)
                return nil
            }
        case "to":
            return {
                guard let view = await canvas(), let travel = travelled(rest) else { return nil }
                await drag(to: travel.to, moves: travel.moves, on: view)
                return nil
            }
        case "over":
            return {
                guard let view = await canvas(), let card = card(rest) else { return nil }
                let frame = CanvasGeometry.frame(of: card)
                await drag(to: CGPoint(x: frame.midX, y: frame.midY), moves: 3, on: view)
                return nil
            }
        case "edge":
            return {
                guard let view = await canvas(), view.finger != nil else { return nil }
                // A little inside the edge, level with where the finger came down: far enough in that the canvas
                // pans at a pace a test can follow.
                let finger = view.document.convert(client.edit.grabbedAt, to: view)
                let within = view.panBounds.insetBy(dx: 20, dy: 20)
                let held: CGPoint = switch parts.count > 1 ? parts[1] : "" {
                case "left": CGPoint(x: within.minX, y: finger.y)
                case "top": CGPoint(x: finger.x, y: within.minY)
                case "bottom": CGPoint(x: finger.x, y: within.maxY)
                default: CGPoint(x: within.maxX, y: finger.y)
                }
                view.finger = held
                fingerMoved = true
                view.continueDrag(to: view.canvasPoint(at: held))
                let target = parts.count > 2 ? card(parts[2])?.id : nil
                // The canvas pans by itself from here. The finger stays where it is.
                for _ in 0..<(target == nil ? 100 : 1500) where target == nil || client.edit.pendingLink?.over != target {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return nil
            }
        case "up":
            return {
                guard let view = await canvas() else { return nil }
                return await lift(on: view)
            }
        case "move", "resize":
            return {
                guard let view = await canvas(), parts.count > 2, down("\(parts[0] == "move" ? "title" : "grip")/\(parts[1])", on: view),
                      let travel = travelled(parts[2]) else { return "No drag began." }
                await drag(to: travel.to, moves: 4, on: view)
                return await lift(on: view)
            }
        case "link":
            return {
                guard let view = await canvas(), parts.count > 2, let target = card(parts[2]), down("port/\(parts[1])", on: view) else { return "No drag began." }
                let frame = CanvasGeometry.frame(of: target)
                await drag(to: CGPoint(x: frame.midX, y: frame.midY), moves: 3, on: view)
                return await lift(on: view)
            }
        case "box":
            return {
                let box = numbers(rest)
                guard let view = await canvas(), box.count == 4, down("at/\(box[0]),\(box[1])", on: view) else { return "No drag began." }
                await drag(to: CGPoint(x: box[2], y: box[3]), moves: 3, on: view)
                return await lift(on: view)
            }
        case "tap":
            return {
                guard let view = await canvas(), let at = point(rest, on: view) else { return nil }
                view.tap(at: at)
                return nil
            }
        case "hold":
            return {
                guard let view = await canvas(), let at = point(rest, on: view) else { return nil }
                view.showMenu(at: at)
                return nil
            }
        case "choose":
            return {
                guard let item = client.edit.menu?.items.first(where: { $0.title == rest }) else { return "The menu has nothing called \(rest)." }
                return await client.act(item.action)
            }
        case "addList":
            return act(.showAdd(at: nil))
        case "add":
            let at = parts.count > 2 ? numbers(parts[2]) : []
            return act(parts.count > 1 ? CardKind(rawValue: parts[1]).map { .add($0, at: at.count == 2 ? CGPoint(x: at[0], y: at[1]) : nil) } : nil)
        case "delete":
            return {
                if rest.hasPrefix("link/"), let index = Int(rest.dropFirst(5)), let flow = flow(), flow.links.indices.contains(index) {
                    return await client.act(.delete(cards: [], links: [flow.links[index].id]), confirmed: true)
                }
                return await client.act(.delete(cards: cards(rest), links: []), confirmed: true)
            }
        case "duplicate":
            return { await client.act(.duplicate(cards(rest))) }
        case "group":
            return { await client.act(.group(cards(rest))) }
        case "ungroup":
            return { await act(group(rest).map { .ungroup($0.id) })() }
        case "fold":
            return { await act(parts.count > 2 ? group(parts[1]).map { .fold($0.id, parts[2] == "on") } : nil)() }
        case "rename":
            return { await act(parts.count > 2 ? group(parts[1]).map { .renameGroup($0.id, to: parts[2]) } : nil)() }
        case "undo":
            return act(.undo)
        case "redo":
            return act(.redo)
        case "tidy":
            return act(.tidy)
        case "voice":
            return {
                guard let view = await canvas(), parts.count > 2, let card = card(parts[1]) else { return "No card is called that." }
                // The card is given its actions a moment after editing is turned on.
                var found: UIAccessibilityCustomAction?
                for _ in 0..<20 where found == nil {
                    found = view.cardViews[card.id]?.accessibilityCustomActions?.first { $0.name == parts[2] }
                    if found == nil { try? await Task.sleep(for: .milliseconds(100)) }
                }
                guard let action = found else { return "VoiceOver has nothing called that here." }
                let before = client.debugSent.count
                _ = action.actionHandler?(action)
                // What it asked for is sent a moment later, and answered a moment after that.
                for _ in 0..<20 where client.debugSent.count == before || !client.mirror.waiting.isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                // And the flow it changed a moment after that.
                try? await Task.sleep(for: .milliseconds(200))
                return client.controls.refusal?.text
            }
        case "viewRun":
            return {
                if let index = Int(rest), let runs = client.mirror.snapshot?.runs, runs.indices.contains(index) { client.show(run: runs[index].id) }
                try? await Task.sleep(for: .milliseconds(300))
                return nil
            }
        case "openFlow":
            return {
                if let found = client.mirror.library?.projects.flatMap(\.flows).first(where: { $0.name == rest }) { client.open(found.id) }
                try? await Task.sleep(for: .milliseconds(300))
                return nil
            }
        case "mac":
            return {
                DebugCannedRun.macDoes(rest, client)
                // A moment, for what it sent to be drawn.
                try? await Task.sleep(for: .milliseconds(150))
                return nil
            }
        default:
            return nil
        }
    }

    private static func describe(_ down: TouchEdit.Down, in client: RemoteClient) -> String {
        func name(_ id: String) -> String { client.mirror.snapshot?.flow.card(id)?.name ?? id }
        switch down {
        case .empty: return "empty"
        case .body(let id): return "body:\(name(id))"
        case .move(let id): return "move:\(name(id))"
        case .moveGroup(let id): return "moveGroup:\((client.mirror.snapshot?.flow.groups ?? []).first { $0.id == id }?.name ?? id)"
        case .resize(let id): return "resize:\(name(id))"
        case .link(let card, let port): return "link:\(name(card))/\(port)"
        }
    }

    /// A command that edits, in a few words: what kind, and for a drag's step whether it is the last.
    private static func summary(_ command: RemoteCommand) -> String? {
        guard let kind = command.editKind else { return nil }
        return command.dragStep.map { "\(kind):\($0.isLast ? "last" : "step")" } ?? kind
    }

    /// Whether editing is on and what is under the finger, worked out the way the views work it out.
    static func state(_ client: RemoteClient) -> [String: Any] {
        let edit = client.edit
        let flow = client.mirror.snapshot?.flow
        func name(_ id: String) -> String { flow?.card(id)?.name ?? id }
        func rect(_ r: CGRect) -> [String: Any] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        func titles(_ menu: EditMenu?) -> Any {
            menu.map { ["title": $0.title, "items": $0.items.map { ["title": $0.title, "enabled": $0.isEnabled] as [String: Any] }] as [String: Any] } ?? NSNull()
        }
        var state: [String: Any] = [
            "on": client.isEditing,
            "selecting": edit.isSelecting,
            "bar": client.editBar.map { ["id": $0.kind.rawValue, "title": $0.title, "enabled": $0.isEnabled, "on": $0.isOn] as [String: Any] },
            "handlesFromZoom": TouchEdit.handlesFromZoom,
            "selected": client.canvas.selection.cardIDs.map(name).sorted(),
            "guides": edit.guides.map { ["vertical": $0.isVertical, "position": $0.position, "start": $0.start, "end": $0.end] as [String: Any] },
            "box": edit.marquee.map(rect) ?? NSNull(),
            "menu": titles(edit.menu),
            "sent": client.debugSent.compactMap(summary),
        ]
        // Where the last step of a move asked for each card to be, to set against where the Mac then put it.
        state["lastMove"] = client.debugSent.reversed().lazy.compactMap { command -> [String: [Double]]? in
            guard case .moveCards(_, let moves, _) = command else { return nil }
            return Dictionary(uniqueKeysWithValues: moves.map { (name($0.key), [$0.value.x, $0.value.y]) })
        }.first ?? NSNull()
        state["dragging"] = switch edit.gesture {
        case nil: NSNull()
        case .move: "move"
        case .resize: "resize"
        case .link: "link"
        case .box: "box"
        }
        state["overlay"] = edit.carried.map { carried in
            ["cards": Dictionary(uniqueKeysWithValues: carried.overlay.frames.map { (name($0.key), rect($0.value)) }),
             "settling": carried.isSettling] as [String: Any]
        } ?? NSNull()
        state["link"] = edit.pendingLink.map { link in
            ["from": name(link.from), "port": link.port, "over": link.over.map(name) ?? NSNull(), "accepts": link.accepts,
             "points": link.points.map { [$0.x, $0.y] }] as [String: Any]
        } ?? NSNull()
        state["downs"] = edit.debugDowns.map { ["meaning": $0.meaning, "taken": $0.taken] as [String: Any] }
        state["asking"] = switch edit.asking {
        case nil: NSNull()
        case .delete(_, _, let title, let message): "\(title) \(message)"
        case .renameGroup(_, let name): "rename:\(name)"
        }
        // What a held finger would bring up on each thing, and on bare canvas.
        if client.isEditing, let flow {
            var menus: [String: Any] = ["canvas": (client.menu(for: .none)?.items ?? []).map(\.title)]
            for card in flow.cards { menus["card:\(card.name)"] = (client.menu(for: .card(card.id))?.items ?? []).map(\.title) }
            for (index, link) in flow.links.enumerated() { menus["link:\(index)"] = (client.menu(for: .link(link.id))?.items ?? []).map(\.title) }
            for group in flow.groups ?? [] { menus["group:\(group.name)"] = (client.menu(for: .group(group.id))?.items ?? []).map(\.title) }
            state["menus"] = menus
        }
        return state
    }
}
#endif
