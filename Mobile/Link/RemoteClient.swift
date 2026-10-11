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
    /// True when iOS won't let the app look for the Mac.
    private(set) var localNetworkBlocked = false
    let terminals = TerminalRegistry()

    /// How long to look before saying the Mac can't be found. Finding it usually takes well under a second.
    private static let lookLimit: Duration = .seconds(5)

    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var link: Link?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var hasStarted = false
    /// Goes up whenever connecting is stopped or started afresh, so a try from before knows it is no longer wanted.
    @ObservationIgnored private var turn = 0
    #if DEBUG
    /// Where a test said the Mac's listener for this device will be, to be kept once pairing has worked.
    @ObservationIgnored private var directAfterPairing: DebugLaunch.Direct?
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

    // MARK: Starting and stopping

    /// Runs once at launch. A second window asks too, and is told nothing new.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        mac = DeviceIdentity.pairedMac
        #if DEBUG
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
    }

    // MARK: Staying connected

    /// Finds the Mac, connects, follows what it says, and starts again when that ends. Returns when the app
    /// goes to the background, or when trying again can't help.
    private func keepConnected(_ mine: Int) async {
        var attempt = 0
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
            if !Task.isCancelled, turn == mine { macNotFound = true }
        }
        defer { slow.cancel() }
        let search = await MacBrowser.findListener(deviceID: DeviceIdentity.deviceID, macID: mac.macID)
        guard turn == mine else { return nil }
        switch search {
        case .found(let endpoint):
            localNetworkBlocked = false
            return endpoint
        case .blocked:
            localNetworkBlocked = true
            macNotFound = true
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
            if self.link === link { self.link = nil }
        }
        var gotIn = false
        do {
            try await connection.start()
            try await connection.send(DeviceMessage.hello(
                RemoteHello(version: Remote.version, deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName)))
            while true {
                let message = try await connection.receive(HostMessage.self)
                guard turn == mine else { return (.tryAgain, gotIn) }
                mirror.apply(message).forEach(terminals.receive)
                switch message {
                case .refused(let text):
                    return (LinkVerdict.refused(text), gotIn)
                case .welcome(let welcome):
                    gotIn = true
                    state = .connected
                    macNotFound = false
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
            if DebugLaunch.savedDirect != nil, !gotIn, verdict == .tryAgain, turn == mine { macNotFound = true }
            #endif
            return (verdict, gotIn)
        }
    }

    // MARK: Flows

    /// Shows a flow, or none. What was on show goes at once, and the new flow follows when the Mac sends it.
    func open(_ flowID: String?) {
        mirror.willOpen(flowID)
        terminals.reset()
        // When not connected there is nobody to ask: the flow is asked for as soon as the Mac lets the device in.
        if state == .connected { link?.send(.open(flowID: flowID)) }
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
        mirror = RemoteMirror()
        terminals.reset()
        macNotFound = false
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
        terminals.reset()
        macNotFound = false
        localNetworkBlocked = false
        pairingProblem = nil
        state = .unpaired
    }

    #if DEBUG
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
