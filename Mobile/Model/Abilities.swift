import Foundation
import Observation
import QueenBeeCore

/// Something a person can ask of the Mac by pressing a control on this device. Each is one of the Mac's
/// own buttons, and becomes one command.
nonisolated enum Press: Hashable, Sendable {
    case run
    case stop
    /// Starts the sessions the flow hasn't started yet, as choosing the flow on the Mac does.
    case startAgents
    /// Sends a held message on, as it was or edited.
    case approve(holdID: String, text: String)
    case reject(holdID: String)
    /// Lets a script's command run.
    case allow(holdID: String)
    case dontRun(holdID: String)
    /// An agent card's "Start agent" or "Restart agent".
    case startAgent(cardID: String)

    /// The command this press sends. `note` is what the person said when rejecting.
    func command(flowID: String, note: String = "") -> RemoteCommand {
        switch self {
        case .run: .run(flowID: flowID, command: nil)
        case .stop: .stop(flowID: flowID)
        case .startAgents: .openOnMac(flowID: flowID)
        case .approve(let holdID, let text): .approve(flowID: flowID, holdID: holdID, text: text)
        case .reject(let holdID): .reject(flowID: flowID, holdID: holdID, note: note)
        case .allow(let holdID): .allowScript(flowID: flowID, holdID: holdID)
        case .dontRun(let holdID): .refuseScript(flowID: flowID, holdID: holdID)
        case .startAgent(let cardID): .startSession(flowID: flowID, cardID: cardID)
        }
    }

    /// Whether a command that was sent and hasn't been answered is this press's, or the other answer to the
    /// same held message. Its buttons wait for the Mac before they can be pressed again.
    func isBusy(among waiting: [RemoteCommand]) -> Bool {
        waiting.contains { sent in
            switch (self, sent) {
            case (.run, .run), (.run, .runFrom), (.stop, .stop), (.startAgents, .openOnMac): true
            case (.approve(let id, _), .approve(_, let other, _)), (.approve(let id, _), .reject(_, let other, _)),
                 (.reject(let id), .approve(_, let other, _)), (.reject(let id), .reject(_, let other, _)),
                 (.allow(let id), .allowScript(_, let other)), (.allow(let id), .refuseScript(_, let other)),
                 (.dontRun(let id), .allowScript(_, let other)), (.dontRun(let id), .refuseScript(_, let other)): id == other
            case (.startAgent(let id), .startSession(_, let other)): id == other
            default: false
            }
        }
    }
}

/// One button: its name, which is the Mac's name for it, and what pressing it asks for.
nonisolated struct PressButton: Equatable, Identifiable, Sendable {
    var title: String
    var press: Press
    /// The answer a card is mostly waiting for, drawn in the colour of what is live.
    var isMain = false
    /// False while its command is on its way to the Mac and hasn't been answered.
    var isEnabled = true
    /// What it does, for VoiceOver.
    var hint = ""

    var id: String { title }
}

/// What a person may do from this device right now, and what they are told when they may not. This is the
/// one place that decides it. Every control asks here whether to show: the run bar, the buttons on cards,
/// the banner and the details. It is a courtesy and no more: the Mac checks every command itself.
///
/// Nothing is on offer while the Mac can't be reached, while an earlier run is on show, or until "Can
/// control" has been turned on for this device on the Mac.
nonisolated struct Abilities: Equatable {
    /// Controls are on show.
    var canAct = false
    /// Said once, where the run bar would be, when this device may only watch.
    var hint: String?
    /// The run bar's buttons, left to right. Empty when there is no bar.
    var bar: [PressButton] = []
    /// Why Run can't be pressed, when it can't.
    var barNote: String?
    /// The buttons drawn on each card, by card id. The banner shows the same ones.
    var cards: [String: [PressButton]] = [:]
    /// The buttons a card's details offer: those on the card, and "Restart agent" for a session that is running.
    var details: [String: [PressButton]] = [:]
    /// The cards a run can be started at with a message, as the Mac's "Run from here…" does.
    var runFrom: Set<String> = []
    /// Said under what is waiting, when some of it can't be answered from here.
    var answerLine: String?

    static let howToTurnOn = "This device can only watch. To run and answer from here, turn on “Can control” for it on your Mac: Settings, then Remote."
    static let nothingToRun = "Nothing to run yet. On your Mac, give the Start card something to start with and link it to a card."

    init() {}

    /// - Parameter viewed: the earlier run on show, or nil for the latest.
    /// - Parameter waiting: the commands sent and not yet answered.
    init(canControl: Bool, isConnected: Bool, snapshot: RemoteFlowSnapshot?, viewed: RunRecord?, waiting: [RemoteCommand]) {
        guard let snapshot else { return }
        let flow = snapshot.flow, run = snapshot.run
        let held = run.holds.filter { $0.kind == .approval || $0.needsAllow }
        let inTerminal = flow.cards.contains { $0.kind == .agent && run.sessions[$0.id] == .needsYou }
        guard isConnected, canControl, viewed == nil else {
            // The Mac's words for it are kept for the device that can't answer at all.
            answerLine = isConnected && canControl ? "Go back to the latest run to answer." : WaitingCard.answer
            if isConnected, viewed == nil { hint = Self.howToTurnOn }
            return
        }
        canAct = true
        // Typing into a session's terminal comes later.
        answerLine = inTerminal ? "An agent that is waiting in its terminal is answered on your Mac for now." : nil
        func button(_ title: String, _ press: Press, main: Bool = false, hint: String) -> PressButton {
            PressButton(title: title, press: press, isMain: main, isEnabled: !press.isBusy(among: waiting), hint: hint)
        }

        if run.isRunning {
            bar = [button("Stop", .stop, hint: "Stops the run on your Mac.")]
        } else {
            // The Mac's `canRun`: a Start card with something to start with and something linked from it.
            let canRun = flow.cards.contains { card in
                card.kind == .start && !(card.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !flow.links(from: card.id).isEmpty
            }
            var runButton = button("Run", .run, main: true, hint: "Runs the flow on your Mac from its Start card.")
            if !canRun {
                runButton.isEnabled = false
                barNote = Self.nothingToRun
            }
            bar = [runButton]
        }
        // The sessions a flow has are its orchestrator's and each agent card's.
        let keys = [Remote.orchestratorKey] + flow.cards.filter { $0.kind == .agent }.map(\.id)
        if keys.contains(where: { (run.sessions[$0] ?? .notStarted) == .notStarted }) {
            bar.insert(button("Start its agents", .startAgents, hint: "Starts this flow's sessions on your Mac."), at: 0)
        }

        for card in flow.cards {
            if let hold = held.first(where: { $0.cardID == card.id }) {
                cards[card.id] = hold.kind == .approval
                    ? [button("Reject", .reject(holdID: hold.id), hint: "Asks why, then sends the message on along the Rejected link."),
                       button("Approve", .approve(holdID: hold.id, text: hold.text), main: true, hint: "Sends the message on along the Approved link.")]
                    : [button("Don't run", .dontRun(holdID: hold.id), hint: "Skips the command without running it."),
                       button("Allow and run", .allow(holdID: hold.id), main: true, hint: "Shows the command in full, then lets it run on your Mac.")]
                details[card.id] = cards[card.id]
            } else if card.kind == .agent {
                let state = run.sessions[card.id] ?? .notStarted
                let isLive = state != .notStarted && state != .exited
                let start = button(state == .notStarted ? "Start agent" : "Restart agent", .startAgent(cardID: card.id),
                                   hint: isLive ? "Restarts the agent on your Mac. It keeps its conversation so far." : "Starts the agent on your Mac.")
                // The Mac's card has the button only while no session is running. A running one is restarted from its details.
                if !isLive { cards[card.id] = [start] }
                details[card.id] = [start]
            }
            if !run.isRunning, acceptsInput(card) { runFrom.insert(card.id) }
        }
    }
}

/// Something that is checked with the person before it is sent: it stops work, or runs a command, or wants a few words.
nonisolated enum Ask: Hashable, Identifiable, Sendable {
    case stop
    /// Restarting an agent whose session is running. `isWorking` is whether it would be interrupted.
    case restart(cardID: String, name: String, isWorking: Bool)
    /// A script's command, to be read in full before it is let run.
    case allow(holdID: String, name: String, command: String)
    /// A held message, to be turned down with a note saying why.
    case reject(holdID: String, name: String, from: String, text: String)

    var id: Self { self }

    /// Whether it is asked in a sheet. The others are asked in an alert.
    var isSheet: Bool {
        switch self {
        case .allow, .reject: true
        case .stop, .restart: false
        }
    }
}

/// A command that wasn't done, and why: in the Mac's words, or that the Mac couldn't be reached.
nonisolated struct ControlRefusal: Equatable, Sendable {
    var command: RemoteCommand
    var text: String
}

/// What the controls are in the middle of: a question put to the person, and the last thing that was turned down.
@Observable
final class ControlsModel {
    /// What is being asked before a press is sent. One at a time.
    var asking: Ask?
    /// Shown near the run bar until it is dismissed or the next command is done.
    var refusal: ControlRefusal?
    #if DEBUG
    /// What a test's presses came to, in order: what was pressed, and the refusal or nil.
    private(set) var debugDone: [(step: String, refusal: String?)] = []
    func debugNote(_ step: String, _ refusal: String?) { debugDone.append((step, refusal)) }
    #endif

    func clear() {
        asking = nil
        refusal = nil
    }
}

extension RemoteClient {
    /// What may be done from here now. See `Abilities`.
    var abilities: Abilities {
        Abilities(canControl: mirror.canControl, isConnected: state == .connected, snapshot: mirror.snapshot,
                  viewed: canvas.viewedRun, waiting: Array(mirror.waiting.values))
    }

    /// A control was pressed. What stops work, runs a command or wants a note is asked about first, and
    /// everything else is sent at once.
    func press(_ press: Press) {
        guard let snapshot = mirror.snapshot else { return }
        func name(_ cardID: String) -> String { snapshot.flow.card(cardID)?.name ?? "this card" }
        switch press {
        case .stop:
            controls.asking = .stop
        case .allow(let holdID):
            guard let hold = snapshot.run.holds.first(where: { $0.id == holdID }) else { return }
            controls.asking = .allow(holdID: holdID, name: name(hold.cardID), command: hold.command)
        case .reject(let holdID):
            guard let hold = snapshot.run.holds.first(where: { $0.id == holdID }) else { return }
            controls.asking = .reject(holdID: holdID, name: name(hold.cardID), from: hold.from, text: hold.text)
        case .startAgent(let cardID):
            let state = snapshot.run.sessions[cardID] ?? .notStarted
            if state == .notStarted || state == .exited {
                Task { await perform(press) }
            } else {
                controls.asking = .restart(cardID: cardID, name: name(cardID), isWorking: state == .working || state == .needsYou)
            }
        case .run, .startAgents, .approve, .dontRun:
            Task { await perform(press) }
        }
    }

    /// The person said yes to what was asked.
    func confirm(_ ask: Ask, note: String = "") {
        controls.asking = nil
        let press: Press = switch ask {
        case .stop: .stop
        case .restart(let cardID, _, _): .startAgent(cardID: cardID)
        case .allow(let holdID, _, _): .allow(holdID: holdID)
        case .reject(let holdID, _, _, _): .reject(holdID: holdID)
        }
        Task { await perform(press, note: note) }
    }

    /// Sends what a press asks for and waits for the Mac. Returns nil when it was done, or why it wasn't.
    @discardableResult
    func perform(_ press: Press, note: String = "") async -> String? {
        guard let flowID = mirror.openFlowID else { return Self.notConnected }
        return await perform(press.command(flowID: flowID, note: note))
    }

    /// "Run from here": starts a run at a card, with a message for it.
    @discardableResult
    func run(from cardID: String, text: String) async -> String? {
        guard let flowID = mirror.openFlowID else { return Self.notConnected }
        return await perform(.runFrom(flowID: flowID, cardID: cardID, text: text))
    }

    /// Every control's command goes through here, so what the Mac turned down is shown in one place, and
    /// goes away when the next thing works.
    private func perform(_ command: RemoteCommand) async -> String? {
        let refusal = await send(command)
        controls.refusal = refusal.map { ControlRefusal(command: command, text: $0) }
        return refusal
    }
}
