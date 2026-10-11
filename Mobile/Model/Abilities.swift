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
    /// The agents waiting on the person in their terminals, which this device may open and type into.
    var inTerminal: Set<String> = []
    /// What typing into each session comes to, by the session's key. See `Typing`.
    var typing: [String: Typing] = [:]

    static let howToTurnOn = "This device can only watch. To run and answer from here, turn on “Can control” for it on your Mac: Settings, then Remote."
    static let nothingToRun = "Nothing to run yet. On your Mac, give the Start card something to start with and link it to a card."

    init() {}

    /// - Parameter viewed: the earlier run on show, or nil for the latest.
    /// - Parameter waiting: the commands sent and not yet answered.
    init(canControl: Bool, isConnected: Bool, snapshot: RemoteFlowSnapshot?, viewed: RunRecord?, waiting: [RemoteCommand]) {
        guard let snapshot else { return }
        let flow = snapshot.flow, run = snapshot.run
        let held = run.holds.filter { $0.kind == .approval || $0.needsAllow }
        // The sessions a flow has are its orchestrator's and each agent card's.
        let keys = [Remote.orchestratorKey] + flow.cards.filter { $0.kind == .agent }.map(\.id)
        for key in keys {
            typing[key] = Typing(state: run.sessions[key] ?? .notStarted, canControl: canControl, isConnected: isConnected, isEarlier: viewed != nil)
        }
        guard isConnected, canControl, viewed == nil else {
            // The Mac's words for it are kept for the device that can't answer at all.
            answerLine = isConnected && canControl ? "Go back to the latest run to answer." : WaitingCard.answer
            if isConnected, viewed == nil { hint = Self.howToTurnOn }
            return
        }
        canAct = true
        // An agent waiting in its terminal is answered there, with the keys.
        inTerminal = Set(flow.cards.filter { $0.kind == .agent && run.sessions[$0.id] == .needsYou }.map(\.id))
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
        let startAll = button("Start its agents", .startAgents, hint: "Starts this flow's sessions on your Mac.")
        if keys.contains(where: { (run.sessions[$0] ?? .notStarted) == .notStarted }) { bar.insert(startAll, at: 0) }

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
        // A session that isn't running is offered its way of starting, beside the line that says so.
        for key in keys where typing[key]?.line == Typing.notRunning {
            if key != Remote.orchestratorKey {
                typing[key]?.action = details[key]?.first
            } else if (run.sessions[key] ?? .notStarted) == .notStarted {
                typing[key]?.action = startAll
            }
        }
    }
}

/// What typing into one session comes to on this device right now: a bar to type in, or one line saying why
/// there is none. Like the rest of `Abilities` it is a courtesy. The Mac checks every message and every key.
nonisolated struct Typing: Equatable {
    /// The message box and the keys are on show.
    var hasBar = false
    /// They are on show and nothing can leave them now: the Mac can't be reached. What was written is kept.
    var isAway = false
    /// Said by the message box: when what is sent will reach the session.
    var note: String?
    /// The session is waiting on the person in its terminal, which keys answer and a message doesn't.
    var wantsKeys = false
    /// Said in place of the bar.
    var line: String?
    /// Beside the line: what starts the session.
    var action: PressButton?

    static let howToTurnOn = "This device can only watch. To type here, turn on “Can control” for it on your Mac: Settings, then Remote."
    static let notRunning = "This session isn't running."
    static let earlier = "Go back to the latest run to type here."
    static let away = "Not connected to your Mac right now. What you've written is kept here."
    static let queued = "It's busy. Your message will be delivered when it's ready."
    static let waiting = "It's waiting for an answer in its terminal. Switch to Keys to answer. A message is delivered after that."
    static let waitingInPanel = "It's waiting for an answer in its terminal. Open the terminal full screen to answer with keys."

    init() {}

    init(state: SessionState, canControl: Bool, isConnected: Bool, isEarlier: Bool) {
        let isLive = state != .notStarted && state != .exited
        guard isConnected else {
            // The link has dropped. A box that was there stays, so what is in it isn't lost from sight.
            if canControl, isLive, !isEarlier {
                hasBar = true
                isAway = true
                note = Self.away
            }
            return
        }
        guard canControl else {
            line = Self.howToTurnOn
            return
        }
        guard !isEarlier else {
            line = Self.earlier
            return
        }
        guard isLive else {
            line = Self.notRunning
            return
        }
        hasBar = true
        switch state {
        case .working, .starting: note = Self.queued
        case .needsYou:
            note = Self.waiting
            wantsKeys = true
        default: break
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

/// Where a person is typing for the sessions of the open flow: what they have written and not sent, by
/// session, and the keys on their way. What is written is kept for as long as the app runs, so it is
/// still there when a terminal is closed and opened again, and when the link drops and comes back.
@Observable
final class ComposerModel {
    /// The two ways to type into a session, which share the bar under its terminal.
    enum Mode: String {
        /// A message, written whole and then sent. The Mac enters it when the session is ready for one.
        case message
        /// Keys, each sent as it is pressed: for answering a prompt in the terminal, or interrupting.
        case keys
    }

    /// Which of the two the full-screen terminal's bar is showing.
    var mode = Mode.message
    /// In keys mode: the keyboard is wanted. It is the app's own key catcher that asks for it.
    var wantsKeyboard = false
    /// The key catcher has the keyboard: the one on screen, or a real one.
    var isCatching = false
    /// What has been written and not sent, by flow and session.
    fileprivate(set) var drafts: [String: String] = [:]
    /// The sessions with a message on its way to the Mac and not yet answered.
    fileprivate(set) var sending: Set<String> = []
    /// The last thing the Mac wouldn't type, by flow and session, until it is put away or the next thing works.
    fileprivate(set) var refusals: [String: String] = [:]
    /// Holds Ctrl between its press and the key it goes with.
    fileprivate(set) var typer = KeyTyper()

    /// Keys pressed and not yet sent, by flow and session, in the order they were pressed.
    @ObservationIgnored fileprivate var pending: [String: [UInt8]] = [:]
    /// What is sending each session's keys, one message at a time.
    @ObservationIgnored fileprivate var pumps: [String: Task<Void, Never>] = [:]
    /// How long keys are gathered before they are sent, so that quick typing goes as one message.
    fileprivate static let gather: Duration = .milliseconds(12)
    #if DEBUG
    /// Where each bar is on screen, for a test that can't see it: "viewer" and "panel".
    var debugFrames: [String: CGRect] = [:]
    #endif

    func draft(_ id: String?) -> String { id.flatMap { drafts[$0] } ?? "" }

    func write(_ text: String, for id: String?) {
        guard let id else { return }
        drafts[id] = text.isEmpty ? nil : text
    }

    func dismissRefusal(_ id: String?) {
        if let id { refusals[id] = nil }
    }

    func toggleControl() { typer.toggleControl() }

    /// Ctrl pressed for one terminal is never left waiting for a key typed in another.
    func releaseControl() { typer.releaseControl() }

    /// The next message's worth of a session's keys, taken off the front. Nil when there are none left.
    fileprivate func next(_ id: String) -> Data? {
        guard let bytes = pending[id], let first = TerminalKeys.chunks(bytes).first else {
            pending[id] = nil
            return nil
        }
        pending[id] = Array(bytes.dropFirst(first.count))
        return first
    }

    /// Another Mac, or none: nothing written for the last one's sessions is this one's.
    func clear() {
        pumps.values.forEach { $0.cancel() }
        pumps = [:]
        pending = [:]
        drafts = [:]
        sending = []
        refusals = [:]
        typer = KeyTyper()
        mode = .message
        wantsKeyboard = false
    }
}

/// What the controls are in the middle of: a question put to the person, and the last thing that was turned down.
@Observable
final class ControlsModel {
    /// What is being asked before a press is sent. One at a time. Set by `ask(_:in:)`, and put away by setting it to nil.
    var asking: Ask? {
        didSet { if asking == nil { askedIn = nil } }
    }
    /// The flow that was open when the question was asked, which is the only flow its answer is for.
    private(set) var askedIn: String?

    func ask(_ ask: Ask, in flowID: String) {
        asking = ask
        askedIn = flowID
    }
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
        // The flow on screen as the button is pressed. What is sent names this flow, whatever is open by then.
        let flowID = snapshot.flow.id
        func name(_ cardID: String) -> String { snapshot.flow.card(cardID)?.name ?? "this card" }
        switch press {
        case .stop:
            controls.ask(.stop, in: flowID)
        case .allow(let holdID):
            guard let hold = snapshot.run.holds.first(where: { $0.id == holdID }) else { return }
            controls.ask(.allow(holdID: holdID, name: name(hold.cardID), command: hold.command), in: flowID)
        case .reject(let holdID):
            guard let hold = snapshot.run.holds.first(where: { $0.id == holdID }) else { return }
            controls.ask(.reject(holdID: holdID, name: name(hold.cardID), from: hold.from, text: hold.text), in: flowID)
        case .startAgent(let cardID):
            let state = snapshot.run.sessions[cardID] ?? .notStarted
            if state == .notStarted || state == .exited {
                Task { await perform(press, in: flowID) }
            } else {
                controls.ask(.restart(cardID: cardID, name: name(cardID), isWorking: state == .working || state == .needsYou), in: flowID)
            }
        case .run, .startAgents, .approve, .dontRun:
            Task { await perform(press, in: flowID) }
        }
    }

    /// The person said yes to what was asked. The answer goes to the flow the question was asked about, and
    /// nowhere if that flow is no longer the one open: "Stop the run?" is never a yes to another flow's run.
    func confirm(_ ask: Ask, note: String = "") {
        let flowID = controls.askedIn
        controls.asking = nil
        guard let flowID, flowID == mirror.openFlowID else { return }
        let press: Press = switch ask {
        case .stop: .stop
        case .restart(let cardID, _, _): .startAgent(cardID: cardID)
        case .allow(let holdID, _, _): .allow(holdID: holdID)
        case .reject(let holdID, _, _, _): .reject(holdID: holdID)
        }
        Task { await perform(press, note: note, in: flowID) }
    }

    /// Sends what a press asks for and waits for the Mac. Returns nil when it was done, or why it wasn't.
    /// `flowID` is the flow the press was made in, or nil for the one open now.
    @discardableResult
    func perform(_ press: Press, note: String = "", in flowID: String? = nil) async -> String? {
        guard let flowID = flowID ?? mirror.openFlowID else { return Self.notConnected }
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

    // MARK: Typing

    /// What a session of the open flow goes by in `composer`: its flow and its key. Nil with no flow open.
    func composerID(_ key: String) -> String? { mirror.openFlowID.map { "\($0)/\(key)" } }

    /// Opens a session's terminal full screen, with the message box under it, or with the keys.
    func openTerminal(_ key: String, keys: Bool = false) {
        composer.releaseControl()
        composer.mode = keys ? .keys : .message
        composer.wantsKeyboard = keys
        terminals.expand(key)
    }

    /// Send was pressed: what is written for a session goes to the Mac as one message. Returns nil when the
    /// Mac took it, and the box is emptied. Otherwise why not, and what was written stays.
    @discardableResult
    func sendMessage(to key: String) async -> String? {
        guard let flowID = mirror.openFlowID, let id = composerID(key) else { return Self.notConnected }
        guard !composer.sending.contains(id) else { return nil }
        let text = composer.draft(id)
        composer.sending.insert(id)
        let refusal = await send(.prompt(flowID: flowID, key: key, text: text))
        composer.sending.remove(id)
        composer.refusals[id] = refusal
        // More may have been written while the Mac was answering, and that is not thrown away.
        if refusal == nil, composer.draft(id) == text { composer.drafts[id] = nil }
        return refusal
    }

    /// Text came from the keyboard for a session's terminal. It is sent at once, as the keys that make it.
    func type(_ text: String, into key: String) {
        enqueue(composer.typer.type(text), for: key)
    }

    /// One of the keys beside the keyboard was pressed.
    func press(_ named: TerminalKey, in key: String) {
        enqueue(composer.typer.press(named), for: key)
    }

    /// Ctrl was held down with a character on a real keyboard. False if Ctrl does nothing to that character.
    @discardableResult
    func control(_ character: Character, in key: String) -> Bool {
        guard let bytes = composer.typer.control(character) else { return false }
        enqueue(bytes, for: key)
        return true
    }

    /// Keys leave in the order they were pressed. Each session has one sender, which waits for the Mac's
    /// answer to a message before it sends the next, so nothing can overtake. Keys pressed while it waits go
    /// together in the next message. If the Mac refuses, the keys still waiting are dropped: typed late and
    /// out of step they could answer a question the person never saw.
    private func enqueue(_ bytes: [UInt8], for key: String) {
        guard !bytes.isEmpty, let flowID = mirror.openFlowID, let id = composerID(key) else { return }
        composer.pending[id, default: []] += bytes
        guard composer.pumps[id] == nil else { return }
        composer.pumps[id] = Task {
            try? await Task.sleep(for: ComposerModel.gather)
            while !Task.isCancelled, let data = composer.next(id) {
                let refusal = await send(.keys(flowID: flowID, key: key, data: data))
                if composer.refusals[id] != refusal { composer.refusals[id] = refusal }
                if refusal != nil {
                    composer.pending[id] = nil
                    break
                }
            }
            composer.pumps[id] = nil
        }
    }

    #if DEBUG
    /// Waits until every key pressed for a session has been sent and answered. Returns what the Mac refused, if it did.
    func debugKeysSent(for key: String) async -> String? {
        guard let id = composerID(key) else { return Self.notConnected }
        await composer.pumps[id]?.value
        return composer.refusals[id]
    }
    #endif
}
