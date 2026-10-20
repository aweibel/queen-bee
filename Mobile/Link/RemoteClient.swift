import Foundation
import Network
import Observation
import QueenBeeCore
import QueenBeeLink
import UIKit

/// The device's end of the link: pairs with a Mac, connects to it, and keeps connecting for as long as the
/// app is on screen, and for a little while after it leaves. Everything the Mac sends lands in `mirror`, which
/// is what the rest of the app draws.
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
        /// The Mac said it no longer knows this device, or this device's own key has gone.
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
    /// True when the Mac was there and turned this device's key down several times running. The device goes on
    /// trying, slowly, and offers pairing again beside that: see `KeyDoubt`.
    private(set) var keyInDoubt = false
    /// True while this device's own key can't be read, as while it is locked after a restart. It is read again in
    /// a moment: the key is there.
    private(set) var keyUnreadable = false
    /// Where the Mac is reached when it isn't found on the Wi-Fi, from the app's settings. Nil for nowhere.
    private(set) var macAddress = DeviceIdentity.macAddress
    let terminals = TerminalRegistry()
    /// The browsers of the open flow's agent cards: the pictures of the pages on screen, and their bars.
    let browsers = BrowserFeeds()
    /// What is on its way to the cards' browsers. See `BrowserInput.swift`.
    @ObservationIgnored let browserInput = BrowserInputQueue()
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
    /// The notifications this device shows about runs while the app is in the background.
    let notifier = Notifier()

    /// How long to look before saying the Mac can't be found. Finding it usually takes well under a second.
    private static let lookLimit: Duration = .seconds(5)
    /// How long to look on the Wi-Fi before trying the Mac's address as well, when the person has given one.
    private static let lookBeforeAddress: Duration = .seconds(3)
    /// How long the connection is kept after the app goes to the background, so switching to another app for a
    /// moment doesn't cost a fresh copy of everything. iOS gives an app about half a minute.
    static let backgroundGrace: Duration = .seconds(25)
    /// What a connection by the Mac's address is remembered as, in place of a service name.
    private static let addressName = "address"

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
    /// The commands that went out on a connection and haven't been answered, by id. When the connection drops,
    /// what became of them isn't known: a Mac that remembers commands is sent them again once the device is back,
    /// with the same ids, and answers each with what became of it, never doing one twice.
    @ObservationIgnored private var unanswered: [Int: RemoteCommand] = [:]
    /// Whether the Mac this device is connected to remembers commands: see `RemoteFeature.commandMemory`.
    @ObservationIgnored private var macRemembers = false
    /// The `RemoteWelcome.memoryID` of the Mac's last welcome: what the commands in `unanswered` went to. One sent
    /// again to a Mac app that has started since would be done twice.
    @ObservationIgnored private var macMemoryID: String?
    /// How many times running the Mac turned this device's key down. Kept across connections for as long as the
    /// app runs, so going to the background and back doesn't forget "can't connect", until the Mac lets it in.
    @ObservationIgnored private var doubt = KeyDoubt()
    /// The time iOS gives the app after it goes to the background, and what ends it.
    @ObservationIgnored private var grace: (task: UIBackgroundTaskIdentifier, timer: Task<Void, Never>)?
    #if DEBUG
    /// Where a test said the Mac's listener for this device will be, to be kept once pairing has worked.
    @ObservationIgnored private var directAfterPairing: DebugLaunch.Direct?
    /// Stands in for the link when a test has no Mac: it is handed each command in place of one.
    @ObservationIgnored var debugOutbox: ((_ id: Int, _ command: RemoteCommand) -> Void)?
    /// And is told which flow the device asks to see, as the Mac would be, with what the device had of the one it left.
    @ObservationIgnored var debugOpener: ((_ flowID: String?, _ leaving: RemoteFlowSnapshot?) -> Void)?
    /// Every command that left for the Mac, in order, for a test to see that nothing else did.
    private(set) var debugSent: [RemoteCommand] = []
    /// And is told which browser cards the device has on screen, as the Mac would be.
    @ObservationIgnored var debugWatcher: ((_ flowID: String, _ cardIDs: [String]) -> Void)?
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

    /// One place the Mac may be listening for this device: its listener found on the Wi-Fi, under the name it is
    /// advertised by, or the address the person gave.
    private struct Place {
        let endpoint: NWEndpoint
        let name: String?
        let byAddress: Bool
    }

    /// How one connection went.
    private struct Outcome {
        var verdict = LinkVerdict.tryAgain
        /// Whether the Mac let the device in, and for how long it stayed.
        var gotIn = false
        var lasted: TimeInterval = 0
        /// What it failed with before the Mac let it in.
        var error: Error?
    }

    init() {
        // The canvas puts each session's terminal in its card, and is told when one comes, goes or moves.
        canvas.terminalSource = { [terminals] key in terminals.view(for: key) }
        canvas.expandTerminal = { [weak self] key in self?.openTerminal(key) }
        terminals.onChange = { [canvas] in canvas.terminalsChanged() }
        canvas.onPress = { [weak self] in self?.press($0) }
        canvas.expandBrowser = { [weak self] id in self?.openBrowser(id) }
        browsers.onChange = { [canvas] id in canvas.view?.browserChanged(id) }
        browsers.sendWatch = { [weak self] ids in self?.watch(ids) }
        notifier.client = self
        // Before the app has finished starting, so a notification's button that launched it is heard.
        notifier.setUp()
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
        if DebugBrowser.isWanted {
            Task { await DebugBrowser.play(self) }
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

    /// The app has come to the front or gone to the background. In the background the connection is kept for a
    /// little while, then closed: nothing can be shown, so nothing more is fetched.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            endGrace()
            // Worth another go: the Mac may have been updated while the app was away.
            if case .needsUpdate = state { state = .lookingForMac }
            // And Local Network may have been turned on in Settings. The look that starts now says so again if not.
            localNetworkBlocked = false
            connect()
        } else {
            beginGrace()
        }
    }

    /// Keeps the app running for `backgroundGrace` in the background, with the connection as it is, then closes it.
    /// Asked again, the time starts again.
    private func beginGrace() {
        endGrace()
        let task = UIApplication.shared.beginBackgroundTask(withName: "Queen Bee connection") { [weak self] in
            // iOS has run out of patience: the connection closes now, before the app is suspended.
            MainActor.assumeIsolated { self?.graceOver() }
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.backgroundGrace)
            guard !Task.isCancelled else { return }
            self?.graceOver()
        }
        grace = (task, timer)
    }

    /// The time in the background is up. The connection closes cleanly, so the Mac lets go of it at once.
    private func graceOver() {
        guard grace != nil else { return }
        if !isActive {
            stop()
            if state == .connecting || state == .connected { state = .lookingForMac }
        }
        endGrace()
    }

    private func endGrace() {
        guard let grace else { return }
        self.grace = nil
        grace.timer.cancel()
        UIApplication.shared.endBackgroundTask(grace.task)
    }

    /// For the "Try again" button on the update message.
    func tryAgain() {
        guard case .needsUpdate = state else { return }
        state = .lookingForMac
        connect()
    }

    /// `inBackground` is for answering a notification, which the app does without coming to the front.
    private func connect(inBackground: Bool = false) {
        guard run == nil, isActive || inBackground, mac != nil, state == .lookingForMac else { return }
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
            let key: Data
            switch DeviceIdentity.storedKey {
            case .found(let found):
                key = found
                keyUnreadable = false
            case .missing:
                // The Mac is remembered and its key has gone, as after restoring this device from a backup.
                state = .mustPairAgain(LinkVerdict.keyRefusedText)
                return
            case .unreadable:
                // Locked, or still starting up after a restart. The key is there, and is read again in a moment.
                keyUnreadable = true
                state = .lookingForMac
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            state = .lookingForMac
            let places = await locate(mac, mine)
            guard turn == mine else { return }
            var outcome = Outcome()
            // Each place that says it is the Mac is tried in turn, until one lets the device in or says why not.
            for place in places {
                state = .connecting
                outcome = await converse(with: mac, at: place, key: key, mine)
                guard turn == mine else { return }
                doubt.note(outcome.gotIn ? nil : outcome.error)
                if outcome.gotIn || outcome.verdict != .tryAgain { break }
            }
            keyInDoubt = doubt.doubtsKey
            switch outcome.verdict {
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
            misses = !places.isEmpty && !outcome.gotIn ? misses + 1 : 0
            if LinkVerdict.isOutOfReach(afterMisses: misses) { noteMac(notFound: true) }
            // A connection that worked for a while and then dropped starts the waits again from the shortest. One
            // that dropped at once is tried again no faster than any other failure.
            if outcome.gotIn, LinkVerdict.resetsWaits(afterConnectedFor: outcome.lasted) { attempt = 0 }
            try? await Task.sleep(for: .seconds(LinkVerdict.wait(beforeAttempt: attempt, doubtingKey: doubt.doubtsKey)))
            attempt += 1
        }
    }

    /// Where the Mac may be listening for this device, in the order to try: its listeners found on the Wi-Fi,
    /// and the address the person gave, with whichever let the device in last time first. Empty if none was found
    /// or the wait was cancelled.
    private func locate(_ mac: PairedMac, _ mine: Int) async -> [Place] {
        #if DEBUG
        if let direct = DebugLaunch.savedDirect { return [Place(endpoint: direct.endpoint, name: nil, byAddress: false)] }
        #endif
        let address = DeviceIdentity.macAddress?.endpoint.map { Place(endpoint: $0, name: Self.addressName, byAddress: true) }
        let slow = Task {
            try? await Task.sleep(for: Self.lookLimit)
            if !Task.isCancelled, turn == mine { noteMac(notFound: true) }
        }
        defer { slow.cancel() }
        let deviceID = DeviceIdentity.deviceID
        let look = Task {
            await MacBrowser.findListener(deviceID: deviceID, macID: mac.macID) {
                // iOS let the app look, which is all "not blocked" means. The Mac itself may be asleep and never found.
                Task { @MainActor in if self.turn == mine { self.localNetworkBlocked = false } }
            }
        }
        // With an address to try as well, the look on the Wi-Fi is cut short: the Mac may be on another network.
        let cutShort = address == nil ? nil : Task {
            try? await Task.sleep(for: Self.lookBeforeAddress)
            look.cancel()
        }
        let search = await withTaskCancellationHandler { await look.value } onCancel: { look.cancel() }
        cutShort?.cancel()
        guard turn == mine else { return [] }
        var places: [Place] = []
        switch search {
        case .found(let matches):
            localNetworkBlocked = false
            places = matches.map { Place(endpoint: $0.endpoint, name: $0.name, byAddress: false) }
        case .blocked:
            // An address on another network may still be reached, so the app isn't stopped for it.
            if address == nil {
                localNetworkBlocked = true
                noteMac(notFound: true)
            }
        case .failed, nil:
            break
        }
        if let address { places.append(address) }
        return LinkCandidates.ordered(places, name: \.name, preferring: DeviceIdentity.goodService)
    }

    /// One connection, from hello until it ends.
    private func converse(with mac: PairedMac, at place: Place, key: Data, _ mine: Int) async -> Outcome {
        // The Mac's address listener holds every paired device's key, each under its device's id.
        let connection = place.byAddress ? LinkConnection(to: place.endpoint, key: key, identity: DeviceIdentity.deviceID)
            : LinkConnection(to: place.endpoint, key: key)
        let link = Link(connection)
        self.link = link
        var outcome = Outcome()
        var since: Date?
        defer {
            link.close()
            if self.link === link {
                self.link = nil
                linkLost()
            }
        }
        do {
            try await connection.start()
            // By address, the device proves which device it is, on this very connection.
            var proof: Data?
            if place.byAddress {
                guard let binding = connection.binding() else { throw LinkError("no binding") }
                proof = LinkSecurity.proof(key: key, binding: binding)
            }
            try await connection.send(DeviceMessage.hello(
                RemoteHello(version: Remote.version, deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName,
                            epoch: DeviceIdentity.epoch, features: [RemoteFeature.historyChanges], proof: proof)))
            while true {
                let frame = try await connection.receive()
                guard turn == mine else { return outcome }
                outcome.lasted = since.map { Date().timeIntervalSince($0) } ?? 0
                let reading: MacReading
                do {
                    reading = try Remote.read(fromMac: frame)
                } catch {
                    // Something it knows the name of and can't read: the two apps don't agree on it. Trying again
                    // would only download everything again and fail at the same place.
                    outcome.verdict = .needsUpdate(Remote.unreadableText)
                    return outcome
                }
                // A kind of message from a newer Mac that this app doesn't know is passed over.
                guard case .message(let message) = reading else { continue }
                take(message)
                switch message {
                case .refused(let text):
                    outcome.verdict = LinkVerdict.refused(text)
                    return outcome
                case .welcome(let welcome):
                    outcome.gotIn = true
                    since = Date()
                    state = .connected
                    doubt = KeyDoubt()
                    keyInDoubt = false
                    noteMac(notFound: false)
                    DeviceIdentity.goodService = place.name
                    if welcome.macName != mac.macName, self.mac?.macID == mac.macID {
                        self.mac?.macName = welcome.macName
                        self.mac.map(DeviceIdentity.rename)
                    }
                    // Asked for again without clearing what is on screen, so the flow that was open stays
                    // there until its fresh copy arrives.
                    if let flowID = mirror.openFlowID { link.send(.open(flowID: flowID)) }
                    sendAgain(welcome, on: link)
                    notifier.connected()
                default:
                    break
                }
            }
        } catch {
            outcome.verdict = LinkVerdict.failed(error)
            outcome.lasted = since.map { Date().timeIntervalSince($0) } ?? 0
            if !outcome.gotIn { outcome.error = error }
            #if DEBUG
            // With no browsing, nothing answering at the address is all "the Mac isn't there" can look like.
            if DebugLaunch.savedDirect != nil, !outcome.gotIn, turn == mine { noteMac(notFound: true) }
            #endif
            return outcome
        }
    }

    /// Takes one message from the Mac. Terminal output is most of what arrives, and it is handed to the terminals
    /// without touching `mirror`: assigning to it, even with nothing changed, has everything drawn from it worked out again.
    private func take(_ message: HostMessage) {
        if case .terminal = message {
            mirror.terminalEvent(in: message).map(terminals.receive)
            return
        }
        // Pictures of pages, like terminal output, go straight to what draws them.
        switch message {
        case .browserPage(let id, _, _), .browserFrame(let id, _, _), .browserCopied(let id, _, _):
            if id == mirror.openFlowID { browsers.receive(message) }
            return
        default:
            break
        }
        mirror.apply(message).forEach(terminals.receive)
        switch message {
        // A device that may only watch is sent no page of any card's browser, and shows a line in its place.
        case .welcome, .control:
            browsers.setCanSee(mirror.canControl, cards: (mirror.snapshot?.flow.cards ?? []).filter { $0.browser == true }.map(\.id))
            if case .control = message { browsers.tellAgain() }
        case .answer(let id, let refusal):
            unanswered[id] = nil
            giveUps.removeValue(forKey: id)?.cancel()
            answers.removeValue(forKey: id)?.resume(returning: refusal)
        // The Mac's copy of the flow is what every setting that isn't being written in shows. A flow sent
        // afresh, as after connecting again, comes with no browser watched on the Mac.
        case .opened:
            fieldsFollowMac()
            browsers.tellAgain()
        case .flow: fieldsFollowMac()
        // A flow made from here is opened once the Mac lists it.
        case .library: openNewFlow()
        default: break
        }
        switch message {
        case .welcome, .opened, .run, .library, .control: notifier.look(at: mirror, inBackground: !isActive)
        default: break
        }
    }

    // MARK: Commands

    /// What a command is answered with when there is no Mac to hear it.
    static let notConnected = "Not connected to your Mac right now."
    /// What a command is answered with when the Mac has been heard from and hasn't said what became of it, or the
    /// connection it went on dropped before the Mac answered. It doesn't say the command failed, because it may not have.
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

    /// What to say of a command whose fate isn't known: it went, and nothing came back.
    static func noAnswer(to command: RemoteCommand) -> String {
        switch command {
        case .prompt, .keys: noAnswerTyping
        default: command.isEdit ? noAnswerEdit : noAnswer
        }
    }

    /// Asks the Mac to do something, and waits for what it says. Nil means it was done. Otherwise the text is
    /// why not: the Mac's own words, or that the Mac can't be reached. A command that could not go now is given
    /// up, so a run never starts late by surprise. One that went and whose connection dropped is sent again, with
    /// the same id, as soon as the device is back, to a Mac that remembers commands and so never does one twice.
    func send(_ command: RemoteCommand) async -> String? {
        if let problem = command.problem ?? standInProblem(command) { return problem }
        guard state == .connected else { return Self.notConnected }
        #if DEBUG
        let outbox = debugOutbox
        #else
        let outbox: ((Int, RemoteCommand) -> Void)? = nil
        #endif
        guard link != nil || outbox != nil else { return Self.notConnected }
        let id = DeviceIdentity.nextCommandID()
        mirror.willSend(command, id: id)
        #if DEBUG
        debugSent.append(command)
        #endif
        // A button waits for its command's answer, and one that never came would leave it waiting for ever.
        giveUps[id] = Task {
            try? await Task.sleep(for: Self.answerWait)
            guard !Task.isCancelled else { return }
            giveUps[id] = nil
            unanswered[id] = nil
            mirror.giveUpWaiting(for: id)
            answers.removeValue(forKey: id)?.resume(returning: Self.noAnswer(to: command))
        }
        return await withCheckedContinuation { waiting in
            answers[id] = waiting
            unanswered[id] = command
            if let link { link.send(.command(id: id, command: command)) } else { outbox?(id, command) }
        }
    }

    /// Why a command can't be sent from here whatever the Mac would say: it is about a card this app can only show
    /// as a note standing in for it, which a newer Mac sent.
    private func standInProblem(_ command: RemoteCommand) -> String? {
        let cards: [String] = switch command {
        case .patchCard(_, let cardID, _), .revertSettings(_, let cardID), .saveRole(_, let cardID, _), .startSession(_, let cardID): [cardID]
        case .duplicate(_, let cardIDs), .group(_, let cardIDs, _): cardIDs
        default: []
        }
        let flow = mirror.snapshot?.flow
        return cards.contains { flow?.card($0)?.unknownKind != nil } ? Remote.unknownCardText : nil
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
        let id = DeviceIdentity.nextCommandID()
        mirror.willSend(command, id: id)
        #if DEBUG
        debugSent.append(command)
        #endif
        if let link { link.send(.command(id: id, command: command)) } else { outbox?(id, command) }
    }

    /// The connection has dropped. To a Mac that remembers commands, the ones it hadn't answered are sent again
    /// once the device is back: until then their buttons go on waiting, for at most `answerWait` from when they
    /// were pressed. To one that doesn't, what became of them can't be known, and they are told so.
    private func linkLost() {
        guard !macRemembers else { return }
        failWaiting()
    }

    /// The Mac has let the device in again. What went out before and wasn't answered goes again, with the same
    /// ids, to a Mac that remembers commands and hasn't started again since they went. Any other Mac can't say
    /// whether it did them, so they are given up.
    private func sendAgain(_ welcome: RemoteWelcome, on link: Link) {
        macRemembers = welcome.has(RemoteFeature.commandMemory)
        let resends = welcome.resends(sentUnder: macMemoryID)
        macMemoryID = welcome.memoryID
        let pending = unanswered.sorted { $0.key < $1.key }
        guard resends else {
            for (id, command) in pending { settle(id, Self.noAnswer(to: command)) }
            return
        }
        for (id, command) in pending {
            mirror.willSend(command, id: id)
            link.send(.command(id: id, command: command))
        }
    }

    /// Nothing waiting will be answered: the app is going to the background, or leaving the Mac. A command that
    /// went may have been done; one that didn't go wasn't.
    private func failWaiting() {
        mirror.dropWaiting()
        giveUps.values.forEach { $0.cancel() }
        giveUps = [:]
        let waiting = answers
        let went = unanswered
        answers = [:]
        unanswered = [:]
        for id in waiting.keys.sorted() {
            waiting[id]?.resume(returning: went[id].map(Self.noAnswer(to:)) ?? Self.notConnected)
        }
    }

    /// Gives one command its answer and stops waiting for it.
    private func settle(_ id: Int, _ text: String?) {
        unanswered[id] = nil
        mirror.giveUpWaiting(for: id)
        giveUps.removeValue(forKey: id)?.cancel()
        answers.removeValue(forKey: id)?.resume(returning: text)
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

    // MARK: Notifications

    /// Answers a held message from a notification's button, with the app perhaps still in the background:
    /// connects if it isn't connected, sends the answer, and lets the connection go again a little later. Does
    /// nothing for a device that may only watch: the Mac would refuse it, and the button shouldn't have been there.
    func answerFromNotification(_ command: RemoteCommand) async {
        let time = BackgroundTime(named: "Queen Bee answer")
        defer { time.end() }
        // Launched for this, the app may not have started connecting yet.
        start()
        if state == .lookingForMac { connect(inBackground: true) }
        let deadline = Date().addingTimeInterval(20)
        while state != .connected, Date() < deadline {
            if case .mustPairAgain = state { return }
            if case .needsUpdate = state { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard state == .connected, mirror.canControl else { return }
        if let refusal = await send(command) { notifier.tell(couldNotAnswer: refusal) }
        // Not on screen: the connection goes in a while, as when the app is put away. An app launched only to
        // answer may never have been told it is in the background.
        if UIApplication.shared.applicationState == .background {
            isActive = false
            beginGrace()
        }
    }

    /// "Pair again", offered beside "Can't connect" when the key is in doubt.
    func pairAgain() { forget() }

    // MARK: Connecting by address

    /// Keeps the Mac's address, or forgets it, and tries it at once if the device isn't connected.
    func setMacAddress(_ address: MacAddress?) {
        DeviceIdentity.macAddress = address
        macAddress = address
        guard mac != nil, state != .connected, state != .unpaired, state != .pairing else { return }
        if case .mustPairAgain = state { return }
        stop()
        state = .lookingForMac
        connect()
    }

    /// Time iOS gives the app to finish something in the background, given back when it is done or when iOS
    /// wants it back, whichever comes first.
    private final class BackgroundTime {
        private var id = UIBackgroundTaskIdentifier.invalid

        init(named name: String) {
            id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                MainActor.assumeIsolated { self?.end() }
            }
        }

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    // MARK: Flows

    /// Shows a flow, or none. What was on show goes at once, and the new flow follows when the Mac sends it.
    func open(_ flowID: String?) {
        #if DEBUG
        let leaving = mirror.snapshot
        #endif
        // A question about the flow that was open is not one about the next, and nor is editing it, or what
        // was selected in it, whose details would otherwise stay up over the next.
        if flowID != mirror.openFlowID {
            controls.asking = nil
            stopEditing()
            canvas.select(.none)
        }
        if flowID != mirror.openFlowID {
            browsers.reset()
            browserInput.clear()
        }
        // The flow already on show is not sent again by the Mac, so nothing of it is cleared here either.
        guard mirror.willOpen(flowID) else { return }
        terminals.reset()
        // When not connected there is nobody to ask: the flow is asked for as soon as the Mac lets the device in.
        if state == .connected { link?.send(.open(flowID: flowID)) }
        #if DEBUG
        if state == .connected, link == nil { debugOpener?(flowID, leaving) }
        #endif
    }

    /// Tells the Mac which browser cards of the open flow are on screen. With no connection there is nobody to
    /// tell: the flow is sent afresh once there is one, and that tells it again.
    private func watch(_ cardIDs: [String]) {
        guard state == .connected, let flowID = mirror.openFlowID else { return }
        if let link {
            link.send(.watchBrowsers(flowID: flowID, cardIDs: cardIDs))
        } else {
            #if DEBUG
            debugWatcher?(flowID, cardIDs)
            #endif
        }
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
        // A new key, and perhaps a new Mac: nothing from before counts against it, or is sent to it again.
        doubt = KeyDoubt()
        keyInDoubt = false
        macMemoryID = nil
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
        browsers.reset()
        browserInput.clear()
        canvas.viewports = [:]
        noteMac(notFound: false)
        localNetworkBlocked = false
        keyInDoubt = false
        doubt = KeyDoubt()
        keyUnreadable = false
        macRemembers = false
        macMemoryID = nil
        macAddress = nil
        notifier.forget()
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
