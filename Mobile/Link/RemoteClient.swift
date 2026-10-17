import Foundation
import Network
import Observation
import QueenBeeCore
import QueenBeeLink

/// The device's end of the link: pairs with a Mac, connects to it, and keeps connecting for as long as the
/// app is on screen. Everything the Mac sends lands in `mirror`, which is what the rest of the app draws.
@Observable
final class RemoteClient {
    enum State: Equatable {
        /// No Mac yet: the pairing screens are showing.
        case unpaired
        /// A code has been scanned and the Mac is being asked.
        case pairing
        /// Paired, and waiting for the Mac to show up on the network. Also where it waits between tries.
        case lookingForMac
        case connecting
        case connected
        /// The two apps are on different versions. The text is the Mac's, and says which one to update.
        case needsUpdate(String)
        /// The Mac no longer knows this device.
        case mustPairAgain(String)
    }

    private(set) var state: State = .unpaired
    /// What the Mac last said. It is kept while the connection is down, so the last state can stay on screen.
    private(set) var mirror = RemoteMirror()
    private(set) var mac: PairedMac?
    /// Why the last try at pairing didn't work, for the pairing screen to show.
    private(set) var pairingProblem: String?
    /// True once the Mac has been looked for and not found, until it next lets the device in. Before that,
    /// not being connected is only "reconnecting".
    private(set) var macNotFound = false
    /// True once the Mac has stayed not found for a while, which is when it is worth saying it may have removed this device.
    private(set) var macLongNotFound = false
    /// True when iOS won't let the app look for the Mac.
    private(set) var localNetworkBlocked = false
    let terminals = TerminalRegistry()
    /// What this device is looking at on the open flow's canvas, and what it has selected there.
    let canvas = CanvasModel()
    /// Which page of the panel beside the canvas is on show.
    let panel = PanelModel()
    /// What the person is being asked before a control does its work, and the last thing the Mac turned down.
    let controls = ControlsModel()
    /// What the person has written for each session and not sent, and the keys on their way.
    let composer = ComposerModel()
    /// Whether the open flow is being edited from here, and what is under the finger.
    let edit = EditModel()
    /// The settings being changed from here and not yet taken by the Mac, and what the list of flows is asking.
    let settings = SettingsModel()

    /// How long to look before saying the Mac can't be found. Finding it usually takes well under a second.
    private static let lookLimit: Duration = .seconds(5)

    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var link: Link?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var hasStarted = false
    /// Goes up whenever connecting is stopped or started afresh, so a try from before knows it is no longer wanted.
    @ObservationIgnored private var turn = 0
    @ObservationIgnored private var longNotFound: Task<Void, Never>?
    /// Who is waiting to hear what became of each command, by the command's id.
    @ObservationIgnored private var answers: [Int: CheckedContinuation<String?, Never>] = [:]
    /// What gives up on each of those when the Mac has had long enough.
    @ObservationIgnored private var giveUps: [Int: Task<Void, Never>] = [:]
    #if DEBUG
    /// Where a test said the Mac's listener for this device will be, to be kept once pairing has worked.
    @ObservationIgnored private var directAfterPairing: DebugLaunch.Direct?
    /// Stands in for the link when a test has no Mac: it is handed each command in place of one.
    @ObservationIgnored var debugOutbox: ((_ id: Int, _ command: RemoteCommand) -> Void)?
    /// And is told which flow the device asks to see, as the Mac would be, with what the device had of the one it left.
    @ObservationIgnored var debugOpener: ((_ flowID: String?, _ leaving: RemoteFlowSnapshot?) -> Void)?
    /// Every command that left for the Mac, in order, for a test to see that nothing else did.
    private(set) var debugSent: [RemoteCommand] = []
    #endif

    /// One connection and the things waiting to be sent on it, which leave in the order they were asked for.
    private final class Link {
        let connection: LinkConnection
        private let outbox: AsyncStream<DeviceMessage>.Continuation

        init(_ connection: LinkConnection) {
            self.connection = connection
            let (stream, continuation) = AsyncStream.makeStream(of: DeviceMessage.self)
            outbox = continuation
            Task {
                for await message in stream {
                    do { try await connection.send(message) } catch { connection.close(); return }
                }
            }
        }

        func send(_ message: DeviceMessage) { outbox.yield(message) }

        func close() {
            outbox.finish()
            connection.close()
        }
    }

    init() {
        // The canvas puts each session's terminal in its card, and is told when one comes, goes or moves.
        canvas.terminalSource = { [terminals] key in terminals.view(for: key) }
        canvas.expandTerminal = { [weak self] key in self?.openTerminal(key) }
        terminals.onChange = { [canvas] in canvas.terminalsChanged() }
        canvas.onPress = { [weak self] in self?.press($0) }
    }

    // MARK: Starting and stopping

    /// Runs once at launch. Asked again, it does nothing new.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        mac = DeviceIdentity.pairedMac
        #if DEBUG
        if DebugCanned.isWanted {
            Task { await DebugCanned.play(self) }
            return
        }
        if DebugCannedRun.isWanted {
            Task { await DebugCannedRun.play(self) }
            return
        }
        if debugStart() { return }
        #endif
        guard mac != nil else {
            // A key outlives the app being deleted. With no Mac to go with it, it is only clutter.
            DeviceIdentity.forget()
            return
        }
        state = .lookingForMac
        connect()
    }

    /// The app has come to the front or gone to the background. Nothing is tried while nobody can see it.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            // Worth another go: the Mac may have been updated while the app was away.
            if case .needsUpdate = state { state = .lookingForMac }
            // And Local Network may have been turned on in Settings. The look that starts now says so again if not.
            localNetworkBlocked = false
            connect()
        } else {
            stop()
            if state == .connecting || state == .connected { state = .lookingForMac }
        }
    }

    /// For the "Try again" button on the update message.
    func tryAgain() {
        guard case .needsUpdate = state else { return }
        state = .lookingForMac
        connect()
    }

    private func connect() {
        guard run == nil, isActive, mac != nil, state == .lookingForMac else { return }
        turn += 1
        let mine = turn
        run = Task {
            await keepConnected(mine)
            if turn == mine { run = nil }
        }
    }

    private func stop() {
        turn += 1
        run?.cancel()
        run = nil
        link?.close()
        link = nil
        failWaiting()
    }

    // MARK: Staying connected

    /// Finds the Mac, connects, follows what it says, and starts again when that ends. Returns when the app
    /// goes to the background, or when trying again can't help.
    private func keepConnected(_ mine: Int) async {
        var attempt = 0
        /// How many times running the Mac's listener was found and didn't answer.
        var misses = 0
        while turn == mine, let mac {
            guard let key = DeviceIdentity.key else {
                // The Mac is remembered and its key has gone, as after restoring this device from a backup.
                state = .mustPairAgain(LinkVerdict.keyRefusedText)
                return
            }
            state = .lookingForMac
            let endpoint = await locate(mac, mine)
            guard turn == mine else { return }
            var verdict = LinkVerdict.tryAgain
            var gotIn = false
            if let endpoint {
                state = .connecting
                (verdict, gotIn) = await converse(with: mac, at: endpoint, key: key, mine)
                guard turn == mine else { return }
            }
            switch verdict {
            case .mustPairAgain(let text):
                state = .mustPairAgain(text)
                return
            case .needsUpdate(let text):
                state = .needsUpdate(text)
                return
            case .tryAgain:
                state = .lookingForMac
            }
            // A Mac that is asleep can still be listed on the network, so finding it is not the same as it being there.
            misses = endpoint != nil && !gotIn ? misses + 1 : 0
            if LinkVerdict.isOutOfReach(afterMisses: misses) { noteMac(notFound: true) }
            // A connection that worked and then dropped starts the waits again from the shortest.
            if gotIn { attempt = 0 }
            try? await Task.sleep(for: .seconds(LinkVerdict.wait(beforeAttempt: attempt)))
            attempt += 1
        }
    }

    /// Where the Mac is listening for this device. Nil if it couldn't be looked for, or the wait was cancelled.
    private func locate(_ mac: PairedMac, _ mine: Int) async -> NWEndpoint? {
        #if DEBUG
        if let direct = DebugLaunch.savedDirect { return direct.endpoint }
        #endif
        let slow = Task {
            try? await Task.sleep(for: Self.lookLimit)
            if !Task.isCancelled, turn == mine { noteMac(notFound: true) }
        }
        defer { slow.cancel() }
        let search = await MacBrowser.findListener(deviceID: DeviceIdentity.deviceID, macID: mac.macID) {
            // iOS let the app look, which is all "not blocked" means. The Mac itself may be asleep and never found.
            Task { @MainActor in if self.turn == mine { self.localNetworkBlocked = false } }
        }
        guard turn == mine else { return nil }
        switch search {
        case .found(let endpoint):
            localNetworkBlocked = false
            return endpoint
        case .blocked:
            localNetworkBlocked = true
            noteMac(notFound: true)
            return nil
        case .failed, nil:
            return nil
        }
    }

    /// One connection, from hello until it ends. Returns what to do next, and whether the Mac let the device in.
    private func converse(with mac: PairedMac, at endpoint: NWEndpoint, key: Data, _ mine: Int) async -> (LinkVerdict, gotIn: Bool) {
        let connection = LinkConnection(to: endpoint, key: key)
        let link = Link(connection)
        self.link = link
        defer {
            link.close()
            if self.link === link {
                self.link = nil
                failWaiting()
            }
        }
        var gotIn = false
        do {
            try await connection.start()
            try await connection.send(DeviceMessage.hello(
                RemoteHello(version: Remote.version, deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName)))
            while true {
                let message = try await connection.receive(HostMessage.self)
                guard turn == mine else { return (.tryAgain, gotIn) }
                take(message)
                switch message {
                case .refused(let text):
                    return (LinkVerdict.refused(text), gotIn)
                case .welcome(let welcome):
                    gotIn = true
                    state = .connected
                    noteMac(notFound: false)
                    if welcome.macName != mac.macName, self.mac?.macID == mac.macID {
                        self.mac?.macName = welcome.macName
                        self.mac.map(DeviceIdentity.rename)
                    }
                    // Asked for again without clearing what is on screen, so the flow that was open stays
                    // there until its fresh copy arrives.
                    if let flowID = mirror.openFlowID { link.send(.open(flowID: flowID)) }
                default:
                    break
                }
            }
        } catch {
            let verdict = LinkVerdict.failed(error)
            #if DEBUG
            // With no browsing, nothing answering at the address is all "the Mac isn't there" can look like.
            if DebugLaunch.savedDirect != nil, !gotIn, verdict == .tryAgain, turn == mine { noteMac(notFound: true) }
            #endif
            return (verdict, gotIn)
        }
    }

    /// Takes one message from the Mac. Terminal output is most of what arrives, and it is handed to the terminals
    /// without touching `mirror`: assigning to it, even with nothing changed, has everything drawn from it worked out again.
    private func take(_ message: HostMessage) {
        if case .terminal = message {
            mirror.terminalEvent(in: message).map(terminals.receive)
            return
        }
        // A welcome starts a new connection, and the mirror forgets what the old one was sent.
        if case .welcome = message { failWaiting() }
        mirror.apply(message).forEach(terminals.receive)
        switch message {
        case .answer(let id, let refusal):
            giveUps.removeValue(forKey: id)?.cancel()
            answers.removeValue(forKey: id)?.resume(returning: refusal)
        // The Mac's copy of the flow is what every setting that isn't being written in shows.
        case .opened, .flow: fieldsFollowMac()
        // A flow made from here is opened once the Mac lists it.
        case .library: openNewFlow()
        default: break
        }
    }

    // MARK: Commands

    /// What a command is answered with when there is no Mac to hear it.
    static let notConnected = "Not connected to your Mac right now."
    /// What a command is answered with when the Mac has been heard from and hasn't said what became of it.
    /// It doesn't say the command failed, because it may not have.
    static let noAnswer = "Your Mac didn't answer. Check the run on your Mac."
    static let noAnswerTyping = "Your Mac didn't answer. Check the session on your Mac."
    static let noAnswerEdit = "Your Mac didn't answer. Check the flow on your Mac."
    /// How long the Mac is given to answer a command. Starting a run can wait on a condition being judged,
    /// which takes seconds. Nothing takes this long unless something is wrong.
    static var answerWait: Duration {
        #if DEBUG
        if let seconds = DebugLaunch.answerWait { return .seconds(seconds) }
        #endif
        return .seconds(30)
    }

    /// Asks the Mac to do something, and waits for what it says. Nil means it was done. Otherwise the text is
    /// why not: the Mac's own words, or that the Mac can't be reached. Nothing is kept to send later: a
    /// command that could not go now is given up, so a run never starts late by surprise.
    func send(_ command: RemoteCommand) async -> String? {
        if let problem = command.problem { return problem }
        guard state == .connected else { return Self.notConnected }
        #if DEBUG
        let outbox = debugOutbox
        #else
        let outbox: ((Int, RemoteCommand) -> Void)? = nil
        #endif
        guard link != nil || outbox != nil else { return Self.notConnected }
        let id = mirror.willSend(command)
        #if DEBUG
        debugSent.append(command)
        #endif
        // A button waits for its command's answer, and one that never came would leave it waiting for ever.
        giveUps[id] = Task {
            try? await Task.sleep(for: Self.answerWait)
            guard !Task.isCancelled else { return }
            giveUps[id] = nil
            mirror.giveUpWaiting(for: id)
            let isTyping = switch command {
            case .prompt, .keys: true
            default: false
            }
            answers.removeValue(forKey: id)?.resume(returning: isTyping ? Self.noAnswerTyping : command.isEdit ? Self.noAnswerEdit : Self.noAnswer)
        }
        return await withCheckedContinuation { waiting in
            answers[id] = waiting
            if let link { link.send(.command(id: id, command: command)) } else { outbox?(id, command) }
        }
    }

    /// Sends a step of a drag that isn't the last. The Mac sends no answer to one, so nothing waits for one:
    /// the drag's last step goes through `send` and says how the whole drag went. A step that can't go now
    /// is dropped, and the next one says where things have got to.
    func sendStep(_ command: RemoteCommand) {
        guard !command.isAnswered, command.problem == nil, state == .connected else { return }
        #if DEBUG
        let outbox = debugOutbox
        #else
        let outbox: ((Int, RemoteCommand) -> Void)? = nil
        #endif
        guard link != nil || outbox != nil else { return }
        let id = mirror.willSend(command)
        #if DEBUG
        debugSent.append(command)
        #endif
        if let link { link.send(.command(id: id, command: command)) } else { outbox?(id, command) }
    }

    /// The link has gone, so nothing that was sent on it will be answered.
    private func failWaiting() {
        mirror.dropWaiting()
        giveUps.values.forEach { $0.cancel() }
        giveUps = [:]
        let waiting = answers
        answers = [:]
        for id in waiting.keys.sorted() { waiting[id]?.resume(returning: Self.notConnected) }
    }

    /// Says whether the Mac can't be found, and starts or stops the wait before saying it has been a long time.
    private func noteMac(notFound: Bool) {
        guard notFound != macNotFound else { return }
        macNotFound = notFound
        macLongNotFound = false
        longNotFound?.cancel()
        longNotFound = !notFound ? nil : Task {
            try? await Task.sleep(for: .seconds(LinkVerdict.removedHintDelay))
            if !Task.isCancelled { macLongNotFound = true }
        }
    }

    // MARK: Flows

    /// Shows a flow, or none. What was on show goes at once, and the new flow follows when the Mac sends it.
    func open(_ flowID: String?) {
        #if DEBUG
        let leaving = mirror.snapshot
        #endif
        // A question about the flow that was open is not one about the next, and nor is editing it.
        if flowID != mirror.openFlowID {
            controls.asking = nil
            stopEditing()
        }
        mirror.willOpen(flowID)
        terminals.reset()
        // When not connected there is nobody to ask: the flow is asked for as soon as the Mac lets the device in.
        if state == .connected { link?.send(.open(flowID: flowID)) }
        #if DEBUG
        if state == .connected, link == nil { debugOpener?(flowID, leaving) }
        #endif
    }

    /// The open flow as the Mac lists it, with the project it is in. Nil when none is open, or the Mac no longer lists it.
    typealias OpenFlow = (flow: RemoteFlowSummary, project: RemoteProject)
    var openFlow: OpenFlow? {
        guard let id = mirror.openFlowID else { return nil }
        for project in mirror.library?.projects ?? [] {
            if let flow = project.flows.first(where: { $0.id == id }) { return (flow, project) }
        }
        return nil
    }

    // MARK: Pairing

    /// Asks the chosen Mac to pair, with the code scanned from its screen.
    func pair(with code: PairingCode, at endpoint: NWEndpoint) {
        guard state == .unpaired else { return }
        state = .pairing
        pairingProblem = nil
        Task {
            // The code's secret is the key: only the Mac showing that code can answer.
            let connection = LinkConnection(to: endpoint, key: code.secret)
            defer { connection.close() }
            do {
                try await connection.start()
                try await connection.send(PairRequest(version: Remote.version, deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName))
                switch try await connection.receive(PairReply.self) {
                case .granted(let grant):
                    guard DeviceIdentity.save(grant) else {
                        pairingFailed("Queen Bee couldn't save the pairing on this device. Try again with a new code.")
                        return
                    }
                    paired()
                case .refused(let text):
                    pairingFailed(text)
                }
            } catch let error as LinkError where error.keyRefused {
                pairingFailed("That code didn't work. It may be for a different Mac. On your Mac, choose “Pair a device…” again and use the new code.")
            } catch {
                pairingFailed("Queen Bee couldn't reach your Mac. Check that the code is still on your Mac's screen and that both are on the same Wi-Fi, then try again.")
            }
        }
    }

    private func pairingFailed(_ text: String) {
        guard state == .pairing else { return }
        pairingProblem = text
        state = .unpaired
    }

    private func paired() {
        guard state == .pairing else { return }
        #if DEBUG
        DebugLaunch.savedDirect = directAfterPairing
        directAfterPairing = nil
        #endif
        mac = DeviceIdentity.pairedMac
        failWaiting()
        mirror = RemoteMirror()
        terminals.reset()
        noteMac(notFound: false)
        state = .lookingForMac
        connect()
    }

    /// "Forget this Mac", and what "Pair again" does first. The Mac still lists the device until it is removed there.
    func forget() {
        stop()
        DeviceIdentity.forget()
        #if DEBUG
        DebugLaunch.savedDirect = nil
        #endif
        mac = nil
        mirror = RemoteMirror()
        controls.clear()
        composer.clear()
        stopEditing()
        // What was copied came from that Mac's flows.
        edit.clipboard = nil
        settings.clear()
        terminals.reset()
        canvas.viewports = [:]
        noteMac(notFound: false)
        localNetworkBlocked = false
        pairingProblem = nil
        state = .unpaired
    }

    #if DEBUG
    /// Takes a message as if the Mac had just sent it, for a test that has no Mac. It goes the way a real one does.
    func debugTake(_ message: HostMessage) {
        take(message)
        if case .welcome = message { state = .connected }
    }

    /// As if the connection had dropped and the Mac had then been looked for and not found.
    func debugLoseMac() {
        state = .lookingForMac
        failWaiting()
        noteMac(notFound: true)
    }

    /// A test launched the app with a pairing code: it starts from nothing and pairs by itself. True if it did.
    private func debugStart() -> Bool {
        guard let code = DebugLaunch.pairCode else { return false }
        forget()
        if let pairing = DebugLaunch.pairing {
            // Told where both listeners are, so nothing is looked for on the network.
            directAfterPairing = DebugLaunch.direct
            pair(with: code, at: pairing)
        } else {
            // Told only the code: the first Mac found offering to pair is taken to be the one.
            Task {
                let browser = MacBrowser()
                browser.start()
                while browser.macs.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                let found = browser.macs[0]
                browser.stop()
                pair(with: code, at: found.endpoint)
            }
        }
        return true
    }
    #endif
}
