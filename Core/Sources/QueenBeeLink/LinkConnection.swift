import Foundation
import Network
import QueenBeeCore

/// Runs its body for the first caller only. A connection's state can report an end more than once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Holds what a connection is waiting on. Only ever touched on that connection's queue.
private final class Waiting: @unchecked Sendable {
    var reason: String?
}

private extension NWError {
    /// Whether securing the connection failed the way two different keys make it fail. A handshake that was
    /// only cut off fails in TLS too, and says nothing about the key.
    var isKeyRefusal: Bool { if case .tls(let status) = self { LinkError.isKeyRefusal(tlsStatus: status) } else { false } }
}

/// One encrypted connection carrying frames: a four-byte big-endian length, then that many bytes.
public final class LinkConnection: @unchecked Sendable {
    /// Far above any real message, and low enough that a garbled length fails fast.
    public static let largestFrame = 64 * 1024 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.queenbee.link.connection")
    /// The largest frame this end takes. An end that only ever expects small messages sets it low, so the
    /// other end can't make it hold 64 MB for a frame it would throw away.
    private let largestInbound: Int

    public init(_ connection: NWConnection, largestInbound: Int = LinkConnection.largestFrame) {
        self.connection = connection
        self.largestInbound = min(largestInbound, Self.largestFrame)
    }

    /// `identity` names the key to a listener that holds several: see `LinkSecurity.parameters(keys:)`.
    public convenience init(to endpoint: NWEndpoint, key: Data, identity: String = LinkSecurity.soleIdentity) {
        self.init(NWConnection(to: endpoint, using: LinkSecurity.parameters(key: key, identity: identity)))
    }

    /// Returns once both ends have proved they hold the key. Throws if they haven't within `timeout`.
    public func start(timeout: TimeInterval = 8) async throws {
        let once = Once()
        let waiting = Waiting()
        let connection = connection
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume() }
                    case .failed(let error): once.run { continuation.resume(throwing: LinkError("\(error)", keyRefused: error.isKeyRefusal)) }
                    // Securing the connection went wrong. Waiting would not change that, so say so at once.
                    case .waiting(.tls(let status)):
                        let error = NWError.tls(status)
                        once.run { continuation.resume(throwing: LinkError("\(error)", keyRefused: error.isKeyRefusal)) }
                    // Any other wait isn't the end: on a device the first connection waits here while it asks to use
                    // the local network, and a network that is down may come back. The timeout is what gives up.
                    case .waiting(let error): waiting.reason = "\(error)"
                    case .cancelled: once.run { continuation.resume(throwing: LinkError("closed")) }
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    once.run { continuation.resume(throwing: LinkError(waiting.reason.map { "timed out: \($0)" } ?? "timed out")) }
                }
                connection.start(queue: queue)
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    public func send(_ body: Data) async throws {
        // The other end would drop the connection on a frame this size, so it never leaves.
        guard body.count <= Self.largestFrame else { throw LinkError("frame too large") }
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Wire.frame(body), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: LinkError("\(error)")) } else { continuation.resume() }
            })
        }
    }

    /// One reader at a time: a frame is read as a length and then a body, and two readers at once would take
    /// each other's halves.
    public func receive() async throws -> Data {
        let header = try await read(4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= largestInbound else {
            // Whatever follows a length like that can't be trusted to be frames, so the connection ends here.
            connection.cancel()
            throw LinkError("frame too large")
        }
        return length == 0 ? Data() : try await read(length)
    }

    private func read(_ count: Int) async throws -> Data {
        let connection = connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LinkError(error.map { "\($0)" } ?? "closed"))
                }
            }
        }
    }

    /// A secret both ends of this connection work out from it once it is secured, and nobody else can: new for
    /// every connection. Nil before the connection is ready.
    public func binding() -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = "EXPORTER-queenbee-binding"
        let secret = label.withCString { sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, 32) }
        return secret.map { Data($0 as DispatchData) }
    }

    /// The address the other end connected from, as text, or nil when it isn't known.
    public var remoteHost: String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        return switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }

    public func send<T: Encodable>(_ message: T) async throws { try await send(try Remote.encode(message)) }

    public func receive<T: Decodable>(_ type: T.Type) async throws -> T { try Remote.decode(type, from: try await receive()) }

    public func close() { connection.cancel() }
}

/// Accepts connections from ends that hold `key`.
public final class LinkListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.queenbee.link.listener")
    private let lock = NSLock()
    /// True once `start` has returned a port.
    private var ready = false
    /// True once `stop()` has been called, so an end that was asked for isn't reported as a failure.
    private var stopped = false
    /// Ends a `start` that hasn't returned yet.
    private var abandon: (@Sendable (LinkError) -> Void)?
    /// True once the listener has been started, and once it has let go of its port for good.
    private var began = false
    private var cancelled = false
    /// Who is waiting in `whenCancelled`.
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    private let largestInbound: Int

    /// `service` advertises the listener on the local network. `localOnly` keeps it to this machine, for tests.
    /// `largestInbound` is the largest frame taken from an end that connects.
    /// `port` is for a test that has to know the port before the listener exists. Left out, the system picks one.
    public convenience init(key: Data, service: NWListener.Service?, localOnly: Bool, largestInbound: Int = LinkConnection.largestFrame,
                            port: UInt16? = nil) throws {
        try self.init(keys: [LinkSecurity.soleIdentity: key], service: service, localOnly: localOnly, largestInbound: largestInbound, port: port)
    }

    /// A listener that takes any of several keys, each under its own name: see `LinkSecurity.parameters(keys:)`.
    /// A listener on a fixed port is one that may be stopped and started again on it at once, so the port is
    /// let go of straight away.
    public init(keys: [String: Data], service: NWListener.Service?, localOnly: Bool, largestInbound: Int = LinkConnection.largestFrame,
                port: UInt16? = nil) throws {
        self.largestInbound = largestInbound
        // One with no key it can use would turn everyone away.
        guard keys.values.contains(where: LinkSecurity.isUsable) else { throw LinkError("no usable key") }
        let parameters = LinkSecurity.parameters(keys: keys)
        if localOnly { parameters.requiredInterfaceType = .loopback }
        if port != nil { parameters.allowLocalEndpointReuse = true }
        listener = try NWListener(using: parameters, on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        listener.service = service
    }

    /// Starts listening and returns the port. Each connection is handed over not yet started.
    /// Throws if it isn't listening within `timeout`, or if `stop()` is called first.
    /// `onFailure` is called once if the listener dies by itself after this has returned.
    public func start(
        timeout: TimeInterval = 10, onFailure: (@Sendable (LinkError) -> Void)? = nil,
        onConnection: @escaping @Sendable (LinkConnection) -> Void
    ) async throws -> UInt16 {
        let started = Once()
        let failed = Once()
        let listener = listener
        let largestInbound = largestInbound
        listener.newConnectionHandler = { onConnection(LinkConnection($0, largestInbound: largestInbound)) }
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                let giveUp: @Sendable (LinkError) -> Void = { error in started.run { continuation.resume(throwing: error) } }
                let alreadyStopped = lock.withLock {
                    if !stopped { abandon = giveUp }
                    return stopped
                }
                // A listener that has been cancelled never reports a state, so starting it would wait for ever.
                guard !alreadyStopped else { giveUp(LinkError("closed")); return }
                // After `start` has returned nobody is waiting for an error, so the end goes to `onFailure`.
                let ended: @Sendable (LinkError) -> Void = { [weak self] error in
                    giveUp(error)
                    guard let self, self.lock.withLock({ self.ready && !self.stopped }) else { return }
                    failed.run { onFailure?(error) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        started.run {
                            // Port 0 is no port: nothing could connect to it.
                            guard let port = listener.port?.rawValue, port != 0 else {
                                continuation.resume(throwing: LinkError("listening without a port"))
                                return
                            }
                            self?.lock.withLock { self?.ready = true }
                            continuation.resume(returning: port)
                        }
                    case .failed(let error):
                        ended(LinkError("\(error)", addressInUse: error == NWError.posix(.EADDRINUSE)))
                        // A failed listener still holds its port and its advertisement until it is cancelled.
                        listener.cancel()
                    // Waiting for a port something else holds could take for ever. Said at once, so it can be tried
                    // again soon.
                    case .waiting(let error) where error == NWError.posix(.EADDRINUSE):
                        ended(LinkError("\(error)", addressInUse: true))
                        listener.cancel()
                    case .cancelled:
                        self?.letGo()
                        ended(LinkError("closed"))
                    // Waiting isn't the end: the network may simply not be up yet. The timeout is what gives up.
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { giveUp(LinkError("timed out")) }
                lock.withLock { began = true }
                listener.start(queue: queue)
            }
        } catch {
            listener.cancel()
            throw error
        }
    }

    public func stop() {
        let abandon = lock.withLock {
            stopped = true
            defer { self.abandon = nil }
            return self.abandon
        }
        abandon?(LinkError("closed"))
        listener.cancel()
    }

    /// Returns once the listener has let go of its port, after `stop()`, so a new one can have it. At once for one
    /// that was never started, and after `timeout` at most.
    public func whenCancelled(timeout: TimeInterval = 2) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock {
                if !began || cancelled { return true }
                cancelWaiters.append(continuation)
                return false
            }
            if now { return continuation.resume() }
            queue.asyncAfter(deadline: .now() + timeout) { self.resumeCancelWaiters() }
        }
    }

    private func letGo() {
        lock.withLock { cancelled = true }
        resumeCancelWaiters()
    }

    private func resumeCancelWaiters() {
        let waiters = lock.withLock {
            defer { cancelWaiters = [] }
            return cancelWaiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// How long to leave it before listening again on a fixed port that couldn't be listened on.
public enum ListenRetry {
    /// A port still held is usually a listener before that is letting go of it, which takes a moment. It is tried
    /// again after `quick` this many times running, before waiting `slow` as for any other failure.
    public static let quickTries = 3
    public static let quick: TimeInterval = 1
    public static let slow: TimeInterval = 30

    /// The wait before the next try, after `error`, with `quickSoFar` quick tries made since the listener last worked.
    public static func wait(after error: Error, quickSoFar: Int) -> TimeInterval {
        guard let error = error as? LinkError, error.addressInUse, quickSoFar < quickTries else { return slow }
        return quick
    }
}
