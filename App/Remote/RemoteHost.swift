import Foundation
import Network
import Observation
import QueenBeeCore
import QueenBeeLink

/// A pairing in progress: the code on screen and when it stops working.
struct PairingOffer: Equatable {
    let code: PairingCode
    let expires: Date
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
    /// A device only ever sends a few words, so nothing bigger is taken from one.
    static let largestFromDevice = 64 * 1024

    let devices = RemoteDevices()
    private(set) var isOn = false
    private(set) var sessions: [RemoteSession] = []
    private(set) var pairing: PairingOffer?
    /// What to tell the person about Remote not working. Pairing going wrong is the newer news, so it comes first.
    var problem: String? { pairingProblem ?? listeningProblem }
    private var listeningProblem: String?
    private var pairingProblem: String?

    @ObservationIgnored private var listeners: [String: LinkListener] = [:]
    @ObservationIgnored private(set) var ports: [String: UInt16] = [:]
    /// The devices whose listener failed and hasn't come back yet.
    @ObservationIgnored private var failing: Set<String> = []
    /// Connections that haven't yet said who they are, with the device each should be. Nil is one that came to pair.
    @ObservationIgnored private var unannounced: [(deviceID: String?, connection: LinkConnection)] = []
    @ObservationIgnored private var pairingListener: LinkListener?
    @ObservationIgnored private(set) var pairingPort: UInt16?
    @ObservationIgnored private var lastLibrary: RemoteLibrary?
    /// Goes up each time Remote is turned on or off, so a watcher from an earlier turn knows to stop.
    @ObservationIgnored private var watch = 0

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
            watchLibrary(watch)
        } else {
            shutDown()
        }
    }

    func shutDown() {
        isOn = false
        cancelPairing()
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
    }

    // MARK: Paired devices

    private func listen(for device: PairedDevice) {
        guard isOn, listeners[device.id] == nil, let key = devices.key(for: device.id) else { return }
        let id = device.id
        do {
            // The record lets a device pick out its own listener on its own Mac without connecting to try.
            let service = localOnly ? nil : NWListener.Service(
                name: "\(macName) \(id.prefix(4))", type: Remote.service,
                txtRecord: NWTXTRecord(["mac": devices.macID, "device": id, "name": macName]))
            let listener = try LinkListener(key: key, service: service, localOnly: localOnly, largestInbound: Self.largestFromDevice)
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

    /// A device is being listened for, or no longer needs to be. The problem goes once that is true of every device.
    private func listening(_ id: String) {
        failing.remove(id)
        if failing.isEmpty { listeningProblem = nil }
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

    /// Unpairs a device: its listener stops, its connection closes and its key is deleted.
    func remove(_ id: String) {
        stopListening(id)
        devices.remove(id)
    }

    /// Starts a connection and returns the first thing it sends. One that says nothing in time is closed, so
    /// a connection can't be opened and left open without ever saying who it is.
    private func opening<T: Decodable & Sendable>(_ type: T.Type, on connection: LinkConnection, deviceID: String?) async throws -> T {
        unannounced.append((deviceID, connection))
        let limit = Task {
            try await Task.sleep(for: .seconds(Self.openingLimit))
            connection.close()
        }
        defer {
            limit.cancel()
            unannounced.removeAll { $0.connection === connection }
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
            guard hello.version == Remote.version else {
                let stale = hello.version < Remote.version ? "this device" : "your Mac"
                try await connection.send(HostMessage.refused("Update Queen Bee on \(stale), so both are on the same version."))
                connection.close()
                return
            }
            // Ids are kept in lower case, and a device may send its own in either.
            guard isOn, hello.deviceID.lowercased() == deviceID, let device = devices.devices.first(where: { $0.id == deviceID }) else {
                // Told, so the device can say so instead of trying again for ever as if the link had dropped.
                try await connection.send(HostMessage.refused("This device is no longer paired with this Mac. Pair it again from Settings on the Mac."))
                connection.close()
                return
            }
            // The listener it came in by was replaced while it was arriving. It can simply connect again.
            guard listeners[deviceID] === listener else { connection.close(); return }
            // A device that connects again has given up on its old connection, even if the Mac hasn't noticed yet.
            closeSessions(of: deviceID)
            let session = RemoteSession(connection: connection, device: device)
            sessions.append(session)
            session.send(.welcome(RemoteWelcome(version: Remote.version, macName: macName, canControl: device.canControl)))
            session.send(.library(library()))
            await session.run()
            sessions.removeAll { $0 === session }
        } catch {
            connection.close()
        }
    }

    // MARK: The flow list

    private func library() -> RemoteLibrary {
        RemoteLibrary(projects: AppServices.shared.projects.map { project in
            RemoteProject(id: project.root.path, name: project.name, flows: project.controllers.map {
                RemoteFlowSummary(id: $0.flow.id, name: $0.flow.name, isSubflow: $0.flow.isSubflow == true, activity: $0.activity)
            })
        })
    }

    /// Sends the flow list to every device whenever a project, a flow's name or what a flow needs changes.
    private func watchLibrary(_ generation: Int) {
        // Off and on again starts a new watcher. Without this check the old one would carry on beside it.
        guard isOn, generation == watch else { return }
        var current = RemoteLibrary(projects: [])
        withObservationTracking { current = library() } onChange: {
            Task { @MainActor in RemoteHost.shared.watchLibrary(generation) }
        }
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
                                            largestInbound: Self.largestFromDevice)
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
            let name = String(request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            // A device being paired again keeps working with its old key until it has been given the new one.
            let before = devices.devices.first { $0.id == id }
            let oldKey = devices.key(for: id)
            guard let key = devices.add(id: id, name: name.isEmpty ? "Device" : name) else {
                pairingProblem = "Queen Bee couldn't save the device's key in your Keychain, so it wasn't paired."
                try await connection.send(PairReply.refused("Queen Bee couldn't save this device's key on the Mac."))
                return
            }
            do {
                try await connection.send(PairReply.granted(PairGrant(key: key, deviceID: id, macID: devices.macID, macName: macName)))
            } catch {
                // The device never got its new key. One that was paired before goes back to its old key, and its
                // listener was never touched. A new one could never connect, and listing it would only mislead.
                if let before, let oldKey, devices.restore(before, key: oldKey) { return }
                remove(id)
                return
            }
            // Whatever it had open used the old key, so it ends, and the listener starts again with the new one.
            stopListening(id)
            if let device = devices.devices.first(where: { $0.id == id }) { listen(for: device) }
        } catch {}
    }
}
