import Foundation
import Network
import Observation
import QueenBeeCore
import QueenBeeLink
import SystemConfiguration

/// A pairing in progress: the code on screen and when it stops working.
struct PairingOffer: Equatable {
    let code: PairingCode
    let expires: Date
}

/// A connection waiting to hear what became of a command a device sent again, while the first is being done.
struct CommandWaiter {
    weak var session: RemoteSession?
    let command: RemoteCommand
}

/// Lets paired devices connect: one listener per device, each locked to that device's key.
@Observable
final class RemoteHost {
    static let shared = RemoteHost()
    static let enabledKey = "remoteEnabled"
    /// How long a pairing code works.
    static let pairingWindow: TimeInterval = 120
    /// How long to leave it before listening again for a device whose listener failed.
    static let listenRetry: TimeInterval = 5

    /// How long a new connection has to say who it is.
    static let openingLimit: TimeInterval = 10
    /// A device only ever sends a few words, so nothing bigger is taken from one. A device checks what it sends
    /// against the same number, so it refuses a command this big itself rather than have the connection end.
    static let largestFromDevice = Remote.largestFromDevice
    /// How long to leave it before reading a device's key again when the Keychain wouldn't give it.
    static let keyRetry: TimeInterval = 60

    /// Whether a device may also connect by this Mac's address, on `addressPort`, as from another network over a
    /// private network such as Tailscale. Off until it is turned on.
    static let byAddressKey = "remoteByAddress"
    /// The port devices connect to by address. Fixed, so it can be typed into a device once and for all.
    static let addressPort = Remote.addressPort

    let devices = RemoteDevices()
    private(set) var isOn = false
    private(set) var sessions: [RemoteSession] = []
    private(set) var pairing: PairingOffer?
    /// What to tell the person about Remote not working. Pairing going wrong is the newer news, so it comes first.
    var problem: String? { pairingProblem ?? listeningProblem ?? addressProblem ?? devices.problem }
    private var listeningProblem: String?
    private var pairingProblem: String?
    private var addressProblem: String?
    /// True while devices can connect by address.
    private(set) var isListeningByAddress = false

    /// Connections that haven't yet said who they are, counted in all and by address, so nobody on the network
    /// can make the Mac hold more than a few.
    @ObservationIgnored private var gate = LinkGate()
    /// The answer to each command devices sent lately: see `CommandMemory`.
    @ObservationIgnored private var memory = CommandMemory<CommandWaiter>()
    @ObservationIgnored private var addressListener: LinkListener?
    /// Goes up whenever the address listener is to be made afresh, so one from before knows it has been replaced.
    @ObservationIgnored private var addressTurn = 0

    @ObservationIgnored private var listeners: [String: LinkListener] = [:]
    @ObservationIgnored private(set) var ports: [String: UInt16] = [:]
    /// The devices whose listener failed and hasn't come back yet.
    @ObservationIgnored private var failing: Set<String> = []
    /// Devices whose key is to be read again, after the Keychain wouldn't give it.
    @ObservationIgnored private var keyRetries: Set<String> = []
    /// Connections that haven't yet said who they are, with the device each should be. Nil is one that came to pair.
    @ObservationIgnored private var unannounced: [(deviceID: String?, connection: LinkConnection)] = []
    @ObservationIgnored private var pairingListener: LinkListener?
    @ObservationIgnored private(set) var pairingPort: UInt16?
    @ObservationIgnored private var lastLibrary: RemoteLibrary?
    /// When the flow list was last worked out, and the wait for the next time it may be. It is worked out at most
    /// once a second, however fast what it is made from changes: a card dragged on the Mac changes a flow sixty
    /// times a second.
    @ObservationIgnored private var libraryBuilt = Date.distantPast
    @ObservationIgnored private var libraryLater: Task<Void, Never>?
    static let libraryEvery: TimeInterval = 1
    /// What flows have cost changes with every turn of every agent. The list is looked at again for it every five
    /// seconds, and not each time it changes.
    static let usageEvery: Duration = .seconds(5)
    /// The browser program each project would use, looked for on the disk at most every half a minute, or when a
    /// project's browser changes state.
    @ObservationIgnored private var browserFound: (key: String, at: Date, name: String?)?
    /// Goes up each time Remote is turned on or off, so a watcher from an earlier turn knows to stop.
    @ObservationIgnored private var watch = 0

    #if DEBUG
    /// Ports a test asked for, because the app it drives has to be told where to connect before it is
    /// launched: one for the next pairing listener, and one for the listener of the device that pairs there.
    @ObservationIgnored var testPorts: (pairing: UInt16?, device: UInt16?) = (nil, nil)
    /// The port each device paired that way is listened for on.
    @ObservationIgnored private var testDevicePorts: [String: UInt16] = [:]
    #endif

    /// The port a test fixed for the pairing listener, or for a device's. Nil, always, outside a test copy.
    private func fixedPort(for deviceID: String?) -> UInt16? {
        #if DEBUG
        guard TestHarness.isEnabled else { return nil }
        return deviceID.map { testDevicePorts[$0] } ?? testPorts.pairing
        #else
        return nil
        #endif
    }

    /// A test copy stays on this machine and is never advertised.
    private var localOnly: Bool { TestHarness.isEnabled }
    private var macName: String { Host.current().localizedName ?? "Mac" }

    /// Runs once at launch. A test copy turns Remote on itself.
    func start() {
        if !TestHarness.isEnabled, UserDefaults.standard.bool(forKey: Self.enabledKey) { setOn(true) }
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        listeningProblem = nil
        pairingProblem = nil
        watch += 1
        if on {
            devices.devices.forEach(listen(for:))
            listenByAddress()
            watchLibrary(watch)
            watchUsage(watch)
        } else {
            shutDown()
        }
    }

    func shutDown() {
        isOn = false
        cancelPairing()
        stopListeningByAddress()
        listeners.values.forEach { $0.stop() }
        listeners.removeAll()
        ports.removeAll()
        failing.removeAll()
        // A connection that hasn't said hello yet has no session to close, so it is closed here.
        unannounced.forEach { $0.connection.close() }
        unannounced.removeAll()
        sessions.forEach { $0.close() }
        sessions.removeAll()
        watch += 1
        // The next device to connect after Remote comes back on must be sent the list, changed or not.
        lastLibrary = nil
        libraryLater?.cancel()
        libraryLater = nil
    }

    // MARK: Paired devices

    private func listen(for device: PairedDevice) {
        // With no id for this Mac a device couldn't tell its listener from another Mac's: see `RemoteDevices.startAfresh`.
        guard isOn, listeners[device.id] == nil, let macID = devices.macID else { return }
        let id = device.id
        let key: Data
        switch devices.storedKey(for: id) {
        case .found(let found): key = found
        // Gone from the Keychain: nothing can connect as the device.
        case .missing: return
        // The Keychain was locked, or its prompt turned down. The device stays paired and is tried again in a while.
        case .unreadable(let status): return keyUnreadable(id, status: status)
        }
        do {
            // The record lets a device pick out its own listener on its own Mac without connecting to try.
            let service = localOnly ? nil : NWListener.Service(
                name: "\(macName) \(id.prefix(4))", type: Remote.service,
                txtRecord: NWTXTRecord(["mac": macID, "device": id, "name": macName]))
            let listener = try LinkListener(key: key, service: service, localOnly: localOnly, largestInbound: Self.largestFromDevice,
                                            port: fixedPort(for: id))
            listeners[id] = listener
            Task {
                do {
                    let port = try await listener.start(onFailure: { error in
                        Task { @MainActor in RemoteHost.shared.listenerEnded(listener, deviceID: id, error: error) }
                    }) { connection in
                        Task { @MainActor in await RemoteHost.shared.serve(connection, deviceID: id, from: listener) }
                    }
                    // It may have been stopped or replaced while it was starting.
                    guard listeners[id] === listener else { return }
                    ports[id] = port
                    listening(id)
                } catch {
                    listenerEnded(listener, deviceID: id, error: error)
                }
            }
        } catch {
            listeningFailed(id, error: error)
        }
    }

    /// A listener that never started, or died later: it is forgotten, and tried again shortly, because a
    /// device with no listener can't connect until Remote is turned off and on.
    private func listenerEnded(_ listener: LinkListener, deviceID id: String, error: Error) {
        // Stopped on purpose or already replaced: the device was unpaired or paired again, or Remote was turned off.
        guard listeners[id] === listener else { return }
        listener.stop()
        listeners[id] = nil
        ports[id] = nil
        listeningFailed(id, error: error)
    }

    /// Says so, and tries again shortly. Also where a listener that couldn't even be made ends up.
    private func listeningFailed(_ id: String, error: Error) {
        failing.insert(id)
        listeningProblem = "Queen Bee couldn't listen for your devices and will try again: \(error)"
        Task {
            try? await Task.sleep(for: .seconds(Self.listenRetry))
            // `listen` itself checks that Remote is still on and nothing else is listening for the device.
            if let device = devices.devices.first(where: { $0.id == id }) { listen(for: device) }
        }
    }

    /// Says so, and reads the key again later. One wait at a time for each device.
    private func keyUnreadable(_ id: String, status: OSStatus) {
        failing.insert(id)
        listeningProblem = "Queen Bee couldn't read a device's key from the Keychain (\(status)) and will try again in a minute."
        guard keyRetries.insert(id).inserted else { return }
        Task {
            try? await Task.sleep(for: .seconds(Self.keyRetry))
            keyRetries.remove(id)
            if let device = devices.devices.first(where: { $0.id == id }) { listen(for: device) }
        }
    }

    /// A device is being listened for, or no longer needs to be. The problem goes once that is true of every device.
    private func listening(_ id: String) {
        failing.remove(id)
        if failing.isEmpty { listeningProblem = nil }
        // Its key may not have been readable when the address listener was made, or there was none.
        if isOn, UserDefaults.standard.bool(forKey: Self.byAddressKey) { listenByAddressSoon() }
    }

    private func stopListening(_ id: String) {
        listeners[id]?.stop()
        listeners[id] = nil
        ports[id] = nil
        listening(id)
        for waiting in unannounced where waiting.deviceID == id { waiting.connection.close() }
        unannounced.removeAll { $0.deviceID == id }
        closeSessions(of: id)
    }

    private func closeSessions(of id: String) {
        for session in sessions where session.device.id == id { session.close() }
        sessions.removeAll { $0.device.id == id }
    }

    /// Turns "Can control" on or off for a device. One that is connected is told at once, and its very next
    /// command is judged by the new setting.
    func setCanControl(_ on: Bool, for id: String) {
        guard devices.canControl(id) != on else { return }
        devices.setCanControl(on, for: id)
        for session in sessions where session.device.id == id { session.controlChanged(on) }
    }

    /// Unpairs a device: its listener stops, its connection closes and its key is deleted.
    func remove(_ id: String) {
        // Told first, if it is connected. Otherwise all it would see is the Mac going quiet, and it would
        // look for the Mac for ever instead of asking to be paired again.
        for session in sessions where session.device.id == id { session.turnAway(Remote.unpairedRefusal) }
        sessions.removeAll { $0.device.id == id }
        stopListening(id)
        devices.remove(id)
        memory.forget(device: id)
        // At once, so its key gets nowhere by address either.
        listenByAddress()
        #if DEBUG
        testDevicePorts[id] = nil
        #endif
    }

    /// Starts a connection and returns the first thing it sends. One that says nothing in time is closed, so
    /// a connection can't be opened and left open without ever saying who it is.
    private func opening<T: Decodable & Sendable>(_ type: T.Type, on connection: LinkConnection, deviceID: String?) async throws -> T {
        // One too many from anywhere, or from one address, is closed before it costs a handshake.
        let address = connection.remoteHost
        guard gate.admit(address) else {
            connection.close()
            throw LinkError("too many connections")
        }
        unannounced.append((deviceID, connection))
        let limit = Task {
            try await Task.sleep(for: .seconds(Self.openingLimit))
            connection.close()
        }
        defer {
            limit.cancel()
            unannounced.removeAll { $0.connection === connection }
            gate.release(address)
        }
        try await connection.start()
        return try await connection.receive(type)
    }

    private func serve(_ connection: LinkConnection, deviceID: String, from listener: LinkListener) async {
        do {
            guard case .hello(let hello) = try await opening(DeviceMessage.self, on: connection, deviceID: deviceID) else {
                connection.close()
                return
            }
            guard try await sameVersion(hello, on: connection) else { return }
            // Ids are kept in lower case, and a device may send its own in either.
            guard isOn, hello.deviceID.lowercased() == deviceID, let device = devices.devices.first(where: { $0.id == deviceID }) else {
                // Told, so the device can say so instead of trying again for ever as if the link had dropped.
                try await connection.send(HostMessage.refused(Remote.unpairedRefusal))
                connection.close()
                return
            }
            // The listener it came in by was replaced while it was arriving. It can simply connect again.
            guard listeners[deviceID] === listener else { connection.close(); return }
            await welcome(device, hello: hello, on: connection)
        } catch {
            connection.close()
        }
    }

    /// Turns a device on another version away, saying which to update. False if it was.
    private func sameVersion(_ hello: RemoteHello, on connection: LinkConnection) async throws -> Bool {
        guard hello.version != Remote.version else { return true }
        let stale = hello.version < Remote.version ? "this device" : "your Mac"
        try await connection.send(HostMessage.refused("Update Queen Bee on \(stale), so both are on the same version."))
        connection.close()
        return false
    }

    /// Lets a device in, and follows it until it goes.
    private func welcome(_ device: PairedDevice, hello: RemoteHello, on connection: LinkConnection) async {
        // A device that connects again has given up on its old connection, even if the Mac hasn't noticed yet.
        closeSessions(of: device.id)
        let session = RemoteSession(connection: connection, device: device, hello: hello)
        sessions.append(session)
        session.send(.welcome(RemoteWelcome(version: Remote.version, macName: macName, canControl: device.canControl,
                                            features: [RemoteFeature.commandMemory])))
        session.send(.library(library()))
        await session.run()
        sessions.removeAll { $0 === session }
    }

    // MARK: Connecting by address

    /// The addresses this Mac can be reached at, for Settings to show beside the port: its name on the local
    /// network, and each address it has on a network, a private one such as Tailscale's included.
    static func addresses() -> [String] {
        var found: [String] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { found.append("\(name).local") }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return found }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !found.contains(text) { found.append(text) }
        }
        return found
    }

    /// After the list of devices and the Mac's id were lost: a new id, so devices can be paired again.
    func startAfresh() {
        devices.startAfresh()
        devices.devices.forEach(listen(for:))
    }

    /// Turns connecting by address on or off, from Settings.
    func setByAddress(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.byAddressKey)
        listenByAddress()
    }

    /// Listens on `addressPort` with every paired device's key, if connecting by address is on, or stops. Made
    /// afresh whenever a device is paired, paired again or removed, so it holds exactly the keys of the devices
    /// paired now. A test copy never listens by address: it would take the port from the copy you use.
    private func listenByAddress() {
        stopListeningByAddress()
        guard isOn, !TestHarness.isEnabled, UserDefaults.standard.bool(forKey: Self.byAddressKey) else { return }
        var keys: [String: Data] = [:]
        for device in devices.devices { if let key = devices.storedKey(for: device.id).key { keys[device.id] = key } }
        // A listener with no key would turn everyone away, so there is none until a device is paired.
        guard !keys.isEmpty else { return }
        addressTurn += 1
        let turn = addressTurn
        do {
            let listener = try LinkListener(keys: keys, service: nil, localOnly: false, largestInbound: Self.largestFromDevice, port: Self.addressPort)
            addressListener = listener
            Task {
                do {
                    _ = try await listener.start(onFailure: { error in
                        Task { @MainActor in RemoteHost.shared.addressListenerEnded(turn, error: error) }
                    }) { connection in
                        Task { @MainActor in await RemoteHost.shared.serveByAddress(connection, from: listener) }
                    }
                    guard addressTurn == turn else { return }
                    isListeningByAddress = true
                    addressProblem = nil
                } catch {
                    addressListenerEnded(turn, error: error)
                }
            }
        } catch {
            addressListenerEnded(turn, error: error)
        }
    }

    /// Made afresh in a moment, once, however many devices start being listened for meanwhile.
    @ObservationIgnored private var addressLater: Task<Void, Never>?
    private func listenByAddressSoon() {
        guard addressLater == nil else { return }
        addressLater = Task {
            try? await Task.sleep(for: .milliseconds(500))
            addressLater = nil
            listenByAddress()
        }
    }

    private func addressListenerEnded(_ turn: Int, error: Error) {
        guard addressTurn == turn else { return }
        stopListeningByAddress()
        addressProblem = "Queen Bee couldn't listen on port \(Self.addressPort) for devices connecting by address, and will try again. Another app may be using the port: \(error)"
        let retry = addressTurn
        Task {
            try? await Task.sleep(for: .seconds(Self.listenRetry * 6))
            // Not if it has been turned off, or made afresh, since.
            if addressTurn == retry { listenByAddress() }
        }
    }

    private func stopListeningByAddress() {
        addressTurn += 1
        addressListener?.stop()
        addressListener = nil
        isListeningByAddress = false
        if !UserDefaults.standard.bool(forKey: Self.byAddressKey) || !isOn { addressProblem = nil }
        for waiting in unannounced where waiting.deviceID == Self.byAddressMark { waiting.connection.close() }
        unannounced.removeAll { $0.deviceID == Self.byAddressMark }
    }

    /// What a connection by address waits as, before it says which device it is.
    private static let byAddressMark = "address"

    /// A connection by address. It got in with some paired device's key, so it is a paired device, and it says
    /// which: its proof shows it holds that device's own key, on this very connection. Anything less is closed
    /// with nothing said, as a stranger is by a device's own listener.
    private func serveByAddress(_ connection: LinkConnection, from listener: LinkListener) async {
        do {
            guard case .hello(let hello) = try await opening(DeviceMessage.self, on: connection, deviceID: Self.byAddressMark),
                  addressListener === listener else {
                connection.close()
                return
            }
            guard try await sameVersion(hello, on: connection) else { return }
            let id = hello.deviceID.lowercased()
            guard isOn, let device = devices.devices.first(where: { $0.id == id }), let key = devices.key(for: id),
                  let proof = hello.proof, let binding = connection.binding(), LinkSecurity.checks(proof, key: key, binding: binding) else {
                connection.close()
                return
            }
            await welcome(device, hello: hello, on: connection)
        } catch {
            connection.close()
        }
    }

    // MARK: Commands sent again

    /// A command has arrived from a device that sends commands again after a drop. Returns what is known of it:
    /// new, to be done now; being done, when `session` is told its answer too; or done, with the answer to give.
    func arrived(_ id: Int, _ command: RemoteCommand, from session: RemoteSession, epoch: String) -> CommandMemory<CommandWaiter>.Seen {
        memory.arrive(device: session.device.id, epoch: epoch, id: id, waiter: CommandWaiter(session: session, command: command))
    }

    /// A command that was remembered as being done has been. Every connection waiting on it is told, as well as
    /// the one it came on, which is told by its session.
    func finished(_ id: Int, device: String, epoch: String, refusal: String?) {
        for waiter in memory.finish(device: device, epoch: epoch, id: id, refusal: refusal) {
            waiter.session?.answerAgain(id, waiter.command, refusal)
        }
    }

    // MARK: The flow list

    /// The flow list as it is now, with what each flow has cost.
    private func library() -> RemoteLibrary { withUsage(libraryWithoutUsage()) }

    /// Everything in the flow list but what flows have cost, which changes too often to watch: see `watchUsage`.
    private func libraryWithoutUsage() -> RemoteLibrary {
        let services = AppServices.shared
        let found = browserName()
        // Ids that flows of more than one open project have: a device can't open or change those.
        var seen = Set<String>(), shared = Set<String>()
        for controller in services.allFlows where !seen.insert(controller.flow.id).inserted { shared.insert(controller.flow.id) }
        return RemoteLibrary(projects: services.projects.map { project in
            // One for the project, as working it out reads every flow.
            let nesting = project.nesting
            return RemoteProject(id: project.root.path, name: project.name, flows: project.controllers.map { controller in
                let id = controller.flow.id
                let outer = nesting.outerFlows(of: id)
                return RemoteFlowSummary(id: id, name: controller.flow.name, isSubflow: controller.flow.isSubflow == true,
                                         activity: controller.activity, parentID: outer.count == 1 ? outer[0] : nil,
                                         pinned: services.pinnedFlowIDs.contains(id), cardNames: Remote.listedNames(of: controller.flow),
                                         sharedID: shared.contains(id) ? true : nil)
            }, browser: Self.browserState(of: project, browser: found))
        // What a role holds, so a device can say when a card has drifted from it, with the start of its instructions and a
        // fingerprint of the whole. A role has no folder. A role a device saved or changed says which.
        }, roles: services.roles.map {
            RemoteRole.listed(id: $0.id, name: $0.name, instructions: $0.instructions, model: $0.model, effort: $0.effort,
                              permissionMode: $0.permissionMode, changedFrom: $0.changedFrom?.device, changedAt: $0.changedFrom?.date)
        })
    }

    /// The same list with what each flow's own sessions have used, and that with every sub-flow below it.
    private func withUsage(_ library: RemoteLibrary) -> RemoteLibrary {
        var library = library
        let services = AppServices.shared
        for index in library.projects.indices {
            guard let project = services.projects.first(where: { $0.root.path == library.projects[index].id }) else { continue }
            let nesting = project.nesting
            for flowIndex in library.projects[index].flows.indices {
                let id = library.projects[index].flows[flowIndex].id
                guard let controller = project.controller(id) else { continue }
                let own = controller.totalUsage
                let below = nesting.subflows(of: id).compactMap { project.controller($0.id)?.totalUsage }.reduce(own, +)
                library.projects[index].flows[flowIndex].usage = own.isZero ? nil : own
                library.projects[index].flows[flowIndex].usageWithSubflows = below.isZero ? nil : below
            }
        }
        return library
    }

    /// The browser program the Mac would use, such as "Google Chrome", looked for again when a project's browser
    /// changes state or half a minute has passed.
    private func browserName() -> String? {
        let key = AppServices.shared.projects.map { "\($0.browser.state)" }.joined(separator: "|")
        if let found = browserFound, found.key == key, Date().timeIntervalSince(found.at) < 30 { return found.name }
        // The program's own name: "Google Chrome", "Chromium", "Google Chrome for Testing".
        let name = BrowserFinder.find(support: AppServices.shared.supportDirectory).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        browserFound = (key, Date(), name)
        return name
    }

    /// A project's browser as its cards and the flow's settings show it on the Mac.
    private static func browserState(of project: ProjectModel, browser: String?) -> RemoteBrowserState {
        let host = project.browser
        // Read so that the profile being made or deleted counts as a change.
        var state = RemoteBrowserState(hasData: host.hasData)
        switch host.state {
        case .idle: state.status = .idle
        case .starting: state.status = .starting
        case .running: state.status = .running
        case .missing: state.status = .missing
        case .downloading(let fraction):
            state.status = .downloading
            state.progress = RemoteBrowserState.step(fraction)
        case .stopped: state.status = .stopped
        case .failed(let reason):
            state.status = .failed
            state.problem = reason
        }
        state.browser = browser
        return state
    }

    /// Sends the flow list to every device whenever a project, a flow's name or cards, what a flow needs or a saved
    /// role changes, and when a project's browser starts, stops, downloads or is cleared: at most once a second,
    /// with what is true then.
    private func watchLibrary(_ generation: Int) {
        // Off and on again starts a new watcher. Without this check the old one would carry on beside it.
        guard isOn, generation == watch else { return }
        let wait = Self.libraryEvery - Date().timeIntervalSince(libraryBuilt)
        if wait > 0 {
            guard libraryLater == nil else { return }
            libraryLater = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.libraryLater = nil
                self.watchLibrary(generation)
            }
            return
        }
        libraryBuilt = Date()
        var base = RemoteLibrary(projects: [])
        withObservationTracking { base = libraryWithoutUsage() } onChange: {
            Task { @MainActor in RemoteHost.shared.watchLibrary(generation) }
        }
        send(withUsage(base))
    }

    /// Looks at what flows have cost every few seconds, and sends the list if it has changed.
    private func watchUsage(_ generation: Int) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.usageEvery)
                guard let self, self.isOn, generation == self.watch else { return }
                // Nothing to tell nobody, and the list is worked out on the main thread.
                guard !self.sessions.isEmpty, let last = self.lastLibrary else { continue }
                var current = last
                current = self.withUsage(current)
                if current != last { self.send(current) }
            }
        }
    }

    private func send(_ current: RemoteLibrary) {
        guard current != lastLibrary else { return }
        lastLibrary = current
        for session in sessions {
            session.send(.library(current))
            session.dropFlowIfGone()
        }
    }

    // MARK: Pairing

    /// Puts a new one-time code on offer and listens for the device that scans it.
    func beginPairing() {
        // Nothing listens while Remote is off, the pairing listener included.
        guard isOn else { return }
        cancelPairing()
        pairingProblem = nil
        let offer = PairingOffer(code: PairingCode(), expires: Date().addingTimeInterval(Self.pairingWindow))
        pairing = offer
        do {
            let service = localOnly ? nil : NWListener.Service(name: macName, type: Remote.pairingService)
            let listener = try LinkListener(key: offer.code.secret, service: service, localOnly: localOnly,
                                            largestInbound: Self.largestFromDevice, port: fixedPort(for: nil))
            pairingListener = listener
            Task {
                do {
                    let port = try await listener.start { connection in
                        Task { @MainActor in await RemoteHost.shared.pair(connection, offer: offer) }
                    }
                    if pairing == offer { pairingPort = port }
                } catch {
                    // A listener stopped because the code was used, put away or replaced hasn't failed.
                    guard pairing == offer else { return }
                    pairingProblem = "Queen Bee couldn't start pairing: \(error)"
                    cancelPairing()
                }
            }
        } catch {
            pairingProblem = "Queen Bee couldn't start pairing: \(error)"
            cancelPairing()
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.pairingWindow))
            if pairing == offer { cancelPairing() }
        }
    }

    func cancelPairing() {
        pairingListener?.stop()
        pairingListener = nil
        pairingPort = nil
        pairing = nil
        for waiting in unannounced where waiting.deviceID == nil { waiting.connection.close() }
        unannounced.removeAll { $0.deviceID == nil }
    }

    private func pair(_ connection: LinkConnection, offer: PairingOffer) async {
        defer { connection.close() }
        do {
            let request = try await opening(PairRequest.self, on: connection, deviceID: nil)
            // The code works once: the first device to get this far takes it.
            guard pairing == offer, offer.expires > Date() else { return }
            guard request.version == Remote.version else {
                let stale = request.version < Remote.version ? "this device" : "your Mac"
                try await connection.send(PairReply.refused("Update Queen Bee on \(stale), so both are on the same version."))
                return
            }
            // The id ends up in a Keychain entry and a service record, so it has to be a real id.
            guard UUID(uuidString: request.deviceID) != nil else {
                try await connection.send(PairReply.refused("This device sent an id Queen Bee can't use."))
                return
            }
            cancelPairing()
            let id = request.deviceID.lowercased()
            #if DEBUG
            if TestHarness.isEnabled { testDevicePorts[id] = testPorts.device }
            #endif
            let name = String(request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            // A device being paired again goes back to its old key if it can't be given the new one.
            let before = devices.devices.first { $0.id == id }
            let oldKey = devices.key(for: id)
            guard let key = devices.add(id: id, name: name.isEmpty ? "Device" : name), let macID = devices.macID else {
                pairingProblem = "Queen Bee couldn't save the device's key in your Keychain, so it wasn't paired."
                try await connection.send(PairReply.refused("Queen Bee couldn't save this device's key on the Mac."))
                return
            }
            // Whatever it had open used the old key, so it ends, and the listener starts again with the new one.
            // Before the device is given the key, and not after: it connects the moment it has it, and a
            // listener still on the old key would tell it that its new key was wrong.
            stopListening(id)
            memory.forget(device: id)
            if let device = devices.devices.first(where: { $0.id == id }) { listen(for: device) }
            // The address listener too: the old key gets nowhere from now on.
            listenByAddress()
            do {
                try await connection.send(PairReply.granted(PairGrant(key: key, deviceID: id, macID: macID, macName: macName)))
            } catch {
                // The device never got its new key. One that was paired before goes back to its old key, and is
                // listened for with that again. A new one could never connect, and listing it would only mislead.
                stopListening(id)
                if let before, let oldKey, devices.restore(before, key: oldKey) {
                    listen(for: before)
                    listenByAddress()
                    return
                }
                remove(id)
                return
            }
        } catch {}
    }
}
