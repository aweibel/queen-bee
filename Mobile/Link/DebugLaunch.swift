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
///   -qbShow list                        once a made-up run has played, go back to the list of flows, as the
///                                       back arrow does on an iPhone
///   -qbAway 1                           once a made-up run has played, lose the Mac and fail to find it again
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
///   -qbKeys 1                           and with the keys out in place of the message box
///   -qbScrollBack <n>                   and scroll it back n lines, as a finger would
///   -qbCanned <n>                       no Mac at all: play the first n steps of a made-up flow and its
///                                       terminals, as if a Mac had sent them. See `DebugCanned`.
///   -qbGoToWaiting <n>                  once the flow is on the canvas, go to the nth card that is waiting on
///                                       the person, as a tap on its line in the banner does
///   -qbCannedRun <n>                    no Mac at all: play the first n stages of a made-up run, for the
///                                       panels. See `DebugCannedRun`.
///   -qbControl 1                        with a made-up run: the made-up Mac lets this device control it
///   -qbDo <step>;<step>…                once the flow is open, do each step in turn, as its button does once
///                                       any question it asks has been answered yes, and wait for the Mac's
///                                       answer. A step is one of:
///                                         run | stop | startAgents
///                                         approve:<card>[:<text>] | reject:<card>[:<note>]
///                                         allow:<card> | dontRun:<card> | start:<card>
///                                         runFrom:<card>:<text>
///                                       and, with a made-up run, control:on | control:off | away | pause.
///                                       A step that names a card waits until that card has something to
///                                       answer. One that starts with ~ isn't waited for.
///                                       Typing, where <session> is a card's name or orchestrator:
///                                         draft:<session>:<text>     write in its message box, and send nothing
///                                         say:<session>:<text>       write that and press Send
///                                         type:<session>:<text>      type it on the keyboard, in keys mode
///                                         burst:<session>:<text>     the same, a letter at a time, quickly
///                                         key:<session>:<key>        press esc | tab | backtab | up | down | left |
///                                                                    right | enter | backspace, the Ctrl button
///                                                                    as ctrl, or Ctrl held with a letter as ctrl-u
///                                         open:<session>:keys|message   open its terminal full screen
///                                         openWaiting:<card>         press "Open its terminal" for a waiting agent
///                                         close                      close the full-screen terminal
///                                       In <text>, \n is a new line and @<n> is n letters.
///                                         wait:<name>                wait until the test makes the file
///                                                                    Library/Caches/qb-wait-<name>
///   -qbSilent 1                         with a made-up run: the made-up Mac answers no command
///   -qbAnswerWait <n>                   give the Mac n seconds to answer a command, in place of 30
///   -qbStale 1                          with a made-up run: its sessions have ended and the made-up Mac
///                                       hasn't said so yet, so what is typed is refused

///   -qbWriteNote 1                      when a rejection asks for its note, start writing in the box
///   -qbPress <step>                     press one button as a finger does, so that what it asks first is on screen
///   -qbEdit 1                           once the flow is on the canvas, press Edit. The steps that edit a flow
///                                       by touch are in `DebugEditing`, and those that change settings and
///                                       flows are in `DebugSettings`.
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
    /// Whether the box for a rejection's note takes the keyboard as soon as it is on screen.
    static var writesNote: Bool { defaults.bool(forKey: "qbWriteNote") }
    /// How many seconds the Mac is given to answer a command, when a test wants less than the real wait.
    static var answerWait: Int? { defaults.object(forKey: "qbAnswerWait") == nil ? nil : max(1, defaults.integer(forKey: "qbAnswerWait")) }

    /// A full-screen message a test wants to look at, with the words the Mac would send.
    static var stoppedScreen: StoppedScreen.Reason? {
        switch show {
        case "update": .update("Update Queen Bee on this device, so both are on the same version.")
        case "pairAgain": .pairAgain(Remote.unpairedRefusal)
        case "localNetwork": .localNetwork("Example Mac")
        default: nil
        }
    }

    /// What a test asked for once the made-up run has played as far as it was told to.
    static func afterCanned(_ client: RemoteClient) {
        if show == "list" { client.open(nil) }
        if defaults.bool(forKey: "qbAway") { client.debugLoseMac() }
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

    // MARK: Controls

    /// The press a test named, once the open flow has what it is about. Nil until then, or for a step that isn't a press.
    private static func press(named step: String, in client: RemoteClient) -> (press: Press, note: String)? {
        guard client.state == .connected, let snapshot = client.mirror.snapshot else { return nil }
        let parts = step.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let card = parts.count > 1 ? snapshot.flow.cards.first { $0.name == parts[1] } : nil
        let said = parts.count > 2 ? parts[2] : nil
        func hold(_ kind: CardKind) -> PendingHold? {
            snapshot.run.holds.first { $0.cardID == card?.id && $0.kind == kind && (kind == .approval || $0.needsAllow) }
        }
        switch parts[0] {
        case "run": return (.run, "")
        case "stop": return (.stop, "")
        case "startAgents": return (.startAgents, "")
        case "approve": return hold(.approval).map { (.approve(holdID: $0.id, text: said ?? $0.text), "") }
        case "reject": return hold(.approval).map { (.reject(holdID: $0.id), said ?? "") }
        case "allow": return hold(.script).map { (.allow(holdID: $0.id), "") }
        case "dontRun": return hold(.script).map { (.dontRun(holdID: $0.id), "") }
        case "start": return card.map { (.startAgent(cardID: $0.id), "") }
        default: return nil
        }
    }

    private static var hasDone = false

    /// Does what a test asked, a step at a time. Each press goes through `perform`, as its button's does.
    static func doNamedSteps(_ client: RemoteClient) {
        guard !hasDone, let steps = defaults.string(forKey: "qbDo") else { return }
        hasDone = true
        Task {
            while client.state != .connected || client.mirror.snapshot == nil || (DebugCannedRun.isWanted && !DebugCannedRun.isPlayed) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            for step in steps.split(separator: ";").map(String.init) {
                let isWaitedFor = !step.hasPrefix("~"), step = step.hasPrefix("~") ? String(step.dropFirst()) : step
                switch step {
                case "control:on", "control:off": client.debugTake(.control(canControl: step == "control:on"))
                case "away": client.debugLoseMac()
                case "pause": try? await Task.sleep(for: .seconds(3))
                case _ where typing(step, in: client) != nil:
                    guard let work = typing(step, in: client) else { continue }
                    client.controls.debugNote(step, await work())
                case _ where DebugSettings.step(step, in: client) != nil:
                    guard let work = DebugSettings.step(step, in: client) else { continue }
                    if isWaitedFor {
                        client.controls.debugNote(step, await work())
                    } else {
                        Task { client.controls.debugNote(step, await work()) }
                    }
                case _ where DebugEditing.step(step, in: client) != nil:
                    guard let work = DebugEditing.step(step, in: client) else { continue }
                    if isWaitedFor {
                        client.controls.debugNote(step, await work())
                    } else {
                        Task { client.controls.debugNote(step, await work()) }
                    }
                default:
                    let parts = step.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    let work: () async -> String?
                    if parts[0] == "runFrom", parts.count == 3 {
                        var cardID: String?
                        while cardID == nil {
                            cardID = client.mirror.snapshot?.flow.cards.first { $0.name == parts[1] }?.id
                            if cardID == nil { try? await Task.sleep(for: .milliseconds(200)) }
                        }
                        let id = cardID ?? ""
                        work = { await client.run(from: id, text: parts[2]) }
                    } else {
                        var found = press(named: step, in: client)
                        while found == nil {
                            try? await Task.sleep(for: .milliseconds(200))
                            found = press(named: step, in: client)
                        }
                        guard let found else { continue }
                        work = { await client.perform(found.press, note: found.note) }
                    }
                    if isWaitedFor {
                        client.controls.debugNote(step, await work())
                    } else {
                        Task { client.controls.debugNote(step, await work()) }
                    }
                }
            }
        }
    }

    // MARK: Typing

    /// A typing step a test named, as the work its button or key does. Nil for a step that isn't one of these.
    private static func typing(_ step: String, in client: RemoteClient) -> (() async -> String?)? {
        let parts = step.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let said = parts.count > 2 ? text(parts[2]) : ""
        /// The session's key, once the open flow has it.
        func key() async -> String {
            guard parts.count > 1, parts[1] != TerminalRegistry.orchestratorKey else { return TerminalRegistry.orchestratorKey }
            while true {
                if let card = client.mirror.snapshot?.flow.cards.first(where: { $0.name == parts[1] }) { return card.id }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        switch parts[0] {
        case "draft":
            return {
                client.composer.write(said, for: client.composerID(await key()))
                return nil
            }
        case "say":
            return {
                let key = await key()
                client.composer.write(said, for: client.composerID(key))
                return await client.sendMessage(to: key)
            }
        case "type":
            return {
                let key = await key()
                client.type(said, into: key)
                return await client.debugKeysSent(for: key)
            }
        case "burst":
            return {
                let key = await key()
                for letter in said { client.type(String(letter), into: key) }
                return await client.debugKeysSent(for: key)
            }
        case "key":
            return {
                let key = await key()
                let named: [String: TerminalKey] = ["esc": .escape, "tab": .tab, "backtab": .backTab, "up": .up, "down": .down,
                                                    "left": .left, "right": .right, "enter": .enter, "backspace": .backspace]
                if let named = named[said] {
                    client.press(named, in: key)
                } else if said == "ctrl" {
                    client.composer.toggleControl()
                } else if said.hasPrefix("ctrl-"), let letter = said.last {
                    client.control(letter, in: key)
                }
                return await client.debugKeysSent(for: key)
            }
        case "open", "openWaiting":
            return {
                let key = await key()
                while client.terminals.sizes[key] == nil || client.canvas.shownRevision == 0 { try? await Task.sleep(for: .milliseconds(200)) }
                client.openTerminal(key, keys: parts[0] == "openWaiting" || said == "keys")
                // A moment, so the terminal is on screen before the next step.
                try? await Task.sleep(for: .milliseconds(900))
                return nil
            }
        case "close":
            return {
                client.terminals.expand(nil)
                try? await Task.sleep(for: .milliseconds(900))
                return nil
            }
        case "wait":
            return {
                let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("qb-wait-\(parts.count > 1 ? parts[1] : "")")
                while !FileManager.default.fileExists(atPath: file.path) { try? await Task.sleep(for: .milliseconds(200)) }
                return nil
            }
        default:
            return nil
        }
    }

    /// The text of a typing step: \n for a new line, and @<n> for n letters.
    private static func text(_ written: String) -> String {
        if written.hasPrefix("@"), let count = Int(written.dropFirst()) { return String(repeating: "a", count: count) }
        return written.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// A command that left for the Mac, in a few words: what kind, who for, and how much.
    private static func summary(_ command: RemoteCommand, in client: RemoteClient) -> String? {
        func name(_ key: String) -> String { client.mirror.snapshot?.flow.card(key)?.name ?? key }
        switch command {
        case .prompt(_, let key, let text): return "prompt:\(name(key)):\(text.count)"
        case .keys(_, let key, let data):
            return "keys:\(name(key)):" + (data.count > 16 ? "\(data.count) bytes" : data.map { String(format: "%02x", $0) }.joined())
        default: return nil
        }
    }

    /// Where the keyboard on screen is, when it is up.
    private static var keyboard: CGRect?
    private static var isWatchingKeyboard = false

    private static func watchKeyboard(_ client: RemoteClient) {
        guard !isWatchingKeyboard else { return }
        isWatchingKeyboard = true
        let centre = NotificationCenter.default
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidHideNotification] {
            centre.addObserver(forName: name, object: nil, queue: .main) { note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let isHidden = note.name == UIResponder.keyboardDidHideNotification
                Task { @MainActor in
                    keyboard = isHidden ? nil : frame
                    client.canvas.didChangeWhatIsShown()
                }
            }
        }
    }

    /// The bar under a terminal and what has been typed into it, worked out the way the views work it out.
    static func composerState(_ client: RemoteClient) -> [String: Any] {
        let composer = client.composer, abilities = client.abilities
        let cards = client.mirror.snapshot?.flow.cards ?? []
        var names = Dictionary(cards.map { ($0.id, $0.name) }) { first, _ in first }
        names[TerminalRegistry.orchestratorKey] = TerminalRegistry.orchestratorKey
        /// By session name, for the open flow's sessions.
        func bySession<T>(_ all: [String: T]) -> [String: T] {
            var named: [String: T] = [:]
            for (key, name) in names {
                if let id = client.composerID(key), let value = all[id] { named[name] = value }
            }
            return named
        }
        func rect(_ r: CGRect) -> [String: Any] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds ?? .zero
        return [
            "mode": composer.mode.rawValue,
            "wantsKeyboard": composer.wantsKeyboard,
            // The app's own key catcher has the keyboard. No terminal ever does: see `terminals`.
            "catching": composer.isCatching,
            "controlHeld": composer.typer.isControlHeld,
            "drafts": bySession(composer.drafts).mapValues(\.count),
            "waiting": names.filter { key, _ in client.composerID(key).map(composer.sending.contains) ?? false }.values.sorted(),
            "refusals": bySession(composer.refusals),
            "sent": client.debugSent.compactMap { summary($0, in: client) },
            // Everything that left for the Mac, typing or not.
            "commands": client.debugSent.count,
            "typing": Dictionary(abilities.typing.compactMap { key, typing in
                names[key].map { ($0, ["bar": typing.hasBar, "away": typing.isAway, "note": typing.note ?? NSNull(), "line": typing.line ?? NSNull(),
                                       "action": typing.action?.title ?? NSNull(), "wantsKeys": typing.wantsKeys] as [String: Any]) }
            }) { first, _ in first },
            "openTerminal": cards.filter { abilities.inTerminal.contains($0.id) && client.terminals.sizes[$0.id] != nil }.map(\.name),
            "bars": composer.debugFrames.mapValues(rect),
            "keyboard": keyboard.map(rect) ?? NSNull(),
            "screen": ["width": screen.width, "height": screen.height],
        ]
    }

    private static var hasPressed = false

    /// Presses one button as a finger does, once what it is about is there.
    static func pressNamed(_ client: RemoteClient) {
        guard !hasPressed, let step = defaults.string(forKey: "qbPress") else { return }
        hasPressed = true
        Task {
            var found = press(named: step, in: client)
            while found == nil || (DebugCannedRun.isWanted && !DebugCannedRun.isPlayed) || client.canvas.shownRevision == 0 {
                try? await Task.sleep(for: .milliseconds(200))
                found = press(named: step, in: client)
            }
            // A moment, so the flow is on screen before something is put up over it.
            try? await Task.sleep(for: .milliseconds(800))
            if let found { client.press(found.press) }
        }
    }

    /// What controls are on offer and what has become of what was pressed, worked out the way the views work it out.
    static func controlsState(_ client: RemoteClient) -> [String: Any] {
        let abilities = client.abilities
        let cards = client.mirror.snapshot?.flow.cards ?? []
        func titles(_ buttons: [PressButton]) -> [String] { buttons.map(\.title) }
        func byName(_ all: [String: [PressButton]]) -> [String: [String]] {
            Dictionary(cards.compactMap { card in all[card.id].map { (card.name, titles($0)) } }) { first, _ in first }
        }
        var details: [String] = []
        if abilities.canAct, let id = client.canvas.selection.cardID, let card = client.mirror.snapshot?.flow.card(id) {
            if abilities.runFrom.contains(id) { details.append("Run from here…") }
            details += titles(card.kind == .agent || abilities.cards[id] != nil ? abilities.details[id] ?? [] : [])
        }
        let waitingCards = client.mirror.snapshot.map(WaitingCard.all) ?? []
        let asking: Any = switch client.controls.asking {
        case nil: NSNull()
        case .stop: "stop"
        case .restart(_, let name, _): "restart:\(name)"
        case .allow(_, let name, let command): "allow:\(name):\(command)"
        case .reject(_, let name, _, _): "reject:\(name)"
        }
        let all = abilities.bar + abilities.cards.values.joined() + abilities.details.values.joined()
        return [
            "canControl": client.mirror.canControl,
            "canAct": abilities.canAct,
            "hint": abilities.hint ?? NSNull(),
            "bar": titles(abilities.bar),
            "barNote": abilities.barNote ?? NSNull(),
            "cards": byName(abilities.cards),
            // The banner shows a waiting card's own buttons under its line.
            "banner": Dictionary(waitingCards.compactMap { card in abilities.cards[card.id].map { (card.name, titles($0)) } }) { first, _ in first },
            "details": details,
            "answerLine": abilities.answerLine ?? NSNull(),
            "disabled": Array(Set(all.filter { !$0.isEnabled }.map(\.title))).sorted(),
            "waiting": client.mirror.waiting.keys.sorted().compactMap { client.mirror.waiting[$0] }.map { String(describing: $0).prefix(while: { $0 != "(" }) }.map(String.init),
            "refusal": client.controls.refusal?.text ?? NSNull(),
            "asking": asking,
            "done": client.controls.debugDone.map { ["step": $0.step, "refusal": $0.refusal ?? NSNull()] as [String: Any] },
        ]
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
            client.openTerminal(key, keys: defaults.bool(forKey: "qbKeys"))
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
        if defaults.bool(forKey: "qbEdit") { canvas.client.setEditing(true) }
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

    /// Writes the state now and again every time any of it changes. Only in the Simulator, where the test
    /// is: a build run on a real device from Xcode has DEBUG set too, and what the Mac sent stays off its disk.
    static func report(_ client: RemoteClient) {
        #if targetEnvironment(simulator)
        watchKeyboard(client)
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
            fields["controls"] = controlsState(client)
            fields["composer"] = composerState(client)
            fields["edit"] = DebugEditing.state(client)
            fields["settings"] = DebugSettings.state(client)
        } onChange: {
            Task { @MainActor in report(client) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            try? data.write(to: stateFile, options: .atomic)
        }
        #endif
    }
}
#endif
