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

    let devices = RemoteDevices()
    private(set) var isOn = false
    private(set) var sessions: [RemoteSession] = []
    private(set) var pairing: PairingOffer?
    private(set) var problem: String?

    @ObservationIgnored private var listeners: [String: LinkListener] = [:]
    @ObservationIgnored private(set) var ports: [String: UInt16] = [:]
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
        problem = nil
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
            let listener = try LinkListener(key: key, service: service, localOnly: localOnly)
            listeners[id] = listener
            Task {
                do {
                    let port = try await listener.start(onFailure: { error in
                        Task { @MainActor in RemoteHost.shared.listenerEnded(listener, deviceID: id, error: error) }
                    }) { connection in
                        Task { @MainActor in await RemoteHost.shared.serve(connection, deviceID: id) }
                    }
                    // It may have been stopped or replaced while it was starting.
                    if listeners[id] === listener { ports[id] = port }
                } catch {
                    listenerEnded(listener, deviceID: id, error: error)
                }
            }
        } catch {
            problem = "Queen Bee couldn't start listening for your devices: \(error)"
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
        problem = "Queen Bee stopped listening for your devices and will try again: \(error)"
        Task {
            try? await Task.sleep(for: .seconds(Self.listenRetry))
            // `listen` itself checks that Remote is still on and nothing else is listening for the device.
            if let device = devices.devices.first(where: { $0.id == id }) { listen(for: device) }
        }
    }

    private func stopListening(_ id: String) {
        listeners[id]?.stop()
        listeners[id] = nil
        ports[id] = nil
        for session in sessions where session.device.id == id { session.close() }
        sessions.removeAll { $0.device.id == id }
    }

    /// Unpairs a device: its listener stops, its connection closes and its key is deleted.
    func remove(_ id: String) {
        stopListening(id)
        devices.remove(id)
    }

    private func serve(_ connection: LinkConnection, deviceID: String) async {
        do {
            try await connection.start()
            guard case .hello(let hello) = try await connection.receive(DeviceMessage.self) else { connection.close(); return }
            guard hello.version == Remote.version else {
                let stale = hello.version < Remote.version ? "this device" : "your Mac"
                try await connection.send(HostMessage.refused("Update Queen Bee on \(stale), so both are on the same version."))
                connection.close()
                return
            }
            guard isOn, hello.deviceID == deviceID, let device = devices.devices.first(where: { $0.id == deviceID }) else {
                connection.close()
                return
            }
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
        sessions.forEach { $0.send(.library(current)) }
    }

    // MARK: Pairing

    /// Puts a new one-time code on offer and listens for the device that scans it.
    func beginPairing() {
        cancelPairing()
        let offer = PairingOffer(code: PairingCode(), expires: Date().addingTimeInterval(Self.pairingWindow))
        pairing = offer
        do {
            let service = localOnly ? nil : NWListener.Service(name: macName, type: Remote.pairingService)
            let listener = try LinkListener(key: offer.code.secret, service: service, localOnly: localOnly)
            pairingListener = listener
            Task {
                do {
                    let port = try await listener.start { connection in
                        Task { @MainActor in await RemoteHost.shared.pair(connection, offer: offer) }
                    }
                    if pairing == offer { pairingPort = port }
                } catch {
                    problem = "Queen Bee couldn't start pairing: \(error)"
                    if pairing == offer { cancelPairing() }
                }
            }
        } catch {
            problem = "Queen Bee couldn't start pairing: \(error)"
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
    }

    private func pair(_ connection: LinkConnection, offer: PairingOffer) async {
        defer { connection.close() }
        do {
            try await connection.start()
            let request = try await connection.receive(PairRequest.self)
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
            stopListening(id)
            let key = devices.add(id: id, name: name.isEmpty ? "Device" : name)
            do {
                try await connection.send(PairReply.granted(PairGrant(key: key, macID: devices.macID, macName: macName)))
            } catch {
                // The device never got its key, so it could never connect. Listing it would only mislead.
                remove(id)
                return
            }
            if let device = devices.devices.first(where: { $0.id == id }) { listen(for: device) }
        } catch {}
    }
}
