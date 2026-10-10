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

/// One encrypted connection carrying frames: a four-byte big-endian length, then that many bytes.
public final class LinkConnection: @unchecked Sendable {
    /// Far above any real message, and low enough that a garbled length fails fast.
    public static let largestFrame = 64 * 1024 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.queenbee.link.connection")

    public init(_ connection: NWConnection) { self.connection = connection }

    public convenience init(to endpoint: NWEndpoint, key: Data) {
        self.init(NWConnection(to: endpoint, using: LinkSecurity.parameters(key: key)))
    }

    /// Returns once both ends have proved they hold the key. Throws if they haven't within `timeout`.
    public func start(timeout: TimeInterval = 8) async throws {
        let once = Once()
        let connection = connection
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: LinkError("\(error)")) }
                    case .cancelled: once.run { continuation.resume(throwing: LinkError("closed")) }
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { once.run { continuation.resume(throwing: LinkError("timed out")) } }
                connection.start(queue: queue)
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    public func send(_ body: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Wire.frame(body), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: LinkError("\(error)")) } else { continuation.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        let header = try await read(4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.largestFrame else { throw LinkError("frame too large") }
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

    public func send<T: Encodable>(_ message: T) async throws { try await send(try Remote.encode(message)) }

    public func receive<T: Decodable>(_ type: T.Type) async throws -> T { try Remote.decode(type, from: try await receive()) }

    public func close() { connection.cancel() }
}

/// Accepts connections from ends that hold `key`.
public final class LinkListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.queenbee.link.listener")

    /// `service` advertises the listener on the local network. `localOnly` keeps it to this machine, for tests.
    public init(key: Data, service: NWListener.Service?, localOnly: Bool) throws {
        let parameters = LinkSecurity.parameters(key: key)
        if localOnly { parameters.requiredInterfaceType = .loopback }
        listener = try NWListener(using: parameters)
        listener.service = service
    }

    /// Starts listening and returns the port. Each connection is handed over not yet started.
    public func start(onConnection: @escaping @Sendable (LinkConnection) -> Void) async throws -> UInt16 {
        let once = Once()
        let listener = listener
        listener.newConnectionHandler = { onConnection(LinkConnection($0)) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: LinkError("\(error)")) }
                case .cancelled: once.run { continuation.resume(throwing: LinkError("closed")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }
}
