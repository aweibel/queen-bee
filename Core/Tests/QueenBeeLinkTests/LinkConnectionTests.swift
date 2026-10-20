import Foundation
import Network
import QueenBeeCore
import Testing
@testable import QueenBeeLink

/// Counts across threads.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite struct LinkConnectionTests {
    private func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    /// A listener that sends back whatever it gets with "!" on the end.
    private func echo(key: Data, frames: Tally? = nil, largestInbound: Int = LinkConnection.largestFrame) async throws
        -> (listener: LinkListener, port: UInt16) {
        let listener = try LinkListener(key: key, service: nil, localOnly: true, largestInbound: largestInbound)
        let port = try await listener.start { server in
            Task {
                do {
                    try await server.start()
                    while true {
                        let frame = try await server.receive()
                        frames?.add()
                        try await server.send(frame + Data("!".utf8))
                    }
                } catch { server.close() }
            }
        }
        return (listener, port)
    }

    /// Connects some other kind of client, sends it a "hello" frame and returns whatever bytes come back.
    private func reply(to port: UInt16, using parameters: NWParameters) async -> Data {
        let connection = NWConnection(to: endpoint(port), using: parameters)
        defer { connection.cancel() }
        let (replies, continuation) = AsyncStream.makeStream(of: Data.self)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Wire.frame(Data("hello".utf8)), completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in continuation.yield(data ?? Data()) }
            case .failed, .waiting, .cancelled: continuation.yield(Data())
            default: break
            }
        }
        let queue = DispatchQueue(label: "dev.queenbee.link.tests")
        queue.asyncAfter(deadline: .now() + 5) { continuation.yield(Data()) }
        connection.start(queue: queue)
        for await reply in replies { return reply }
        return Data()
    }

    @Test func framesCrossAnEncryptedLoopback() async throws {
        let key = LinkSecurity.randomKey()
        let (listener, port) = try await echo(key: key)
        defer { listener.stop() }
        let client = LinkConnection(to: endpoint(port), key: key)
        defer { client.close() }
        try await client.start()
        try await client.send(Data("hello".utf8))
        #expect(try await client.receive() == Data("hello!".utf8))
        let big = Data(repeating: 7, count: 300_000)
        try await client.send(big)
        #expect(try await client.receive() == big + Data("!".utf8))
        try await client.send(Data())
        #expect(try await client.receive() == Data("!".utf8))
    }

    @Test func aWrongKeyGetsNothing() async throws {
        let (listener, port) = try await echo(key: LinkSecurity.randomKey())
        defer { listener.stop() }
        let client = LinkConnection(to: endpoint(port), key: LinkSecurity.randomKey())
        defer { client.close() }
        await #expect(throws: (any Error).self) {
            try await client.start(timeout: 4)
            try await client.send(Data("hello".utf8))
            _ = try await client.receive()
        }
    }

    /// A connection that worked must not let the next one in without the key.
    @Test func aWrongKeyGetsNothingAfterARightOne() async throws {
        let key = LinkSecurity.randomKey()
        let (listener, port) = try await echo(key: key)
        defer { listener.stop() }
        let first = LinkConnection(to: endpoint(port), key: key)
        try await first.start()
        try await first.send(Data("hello".utf8))
        #expect(try await first.receive() == Data("hello!".utf8))
        first.close()
        let second = LinkConnection(to: endpoint(port), key: LinkSecurity.randomKey())
        defer { second.close() }
        await #expect(throws: (any Error).self) {
            try await second.start(timeout: 4)
            try await second.send(Data("hello".utf8))
            _ = try await second.receive()
        }
    }

    @Test func aStoppedListenerRefusesNewConnections() async throws {
        let key = LinkSecurity.randomKey()
        let (listener, port) = try await echo(key: key)
        listener.stop()
        try await Task.sleep(for: .milliseconds(200))
        let client = LinkConnection(to: endpoint(port), key: key)
        defer { client.close() }
        await #expect(throws: (any Error).self) { try await client.start(timeout: 3) }
    }

    /// Ordinary TLS, with certificates and no key, must not be an open door.
    @Test func aPlainTLSClientGetsNothing() async throws {
        let frames = Tally()
        let (listener, port) = try await echo(key: LinkSecurity.randomKey(), frames: frames)
        defer { listener.stop() }
        let reply = await reply(to: port, using: NWParameters(tls: NWProtocolTLS.Options()))
        #expect(reply.isEmpty)
        #expect(frames.value == 0)
    }

    @Test func aPlainTCPClientGetsNothing() async throws {
        let frames = Tally()
        let (listener, port) = try await echo(key: LinkSecurity.randomKey(), frames: frames)
        defer { listener.stop() }
        // The listener may answer with a TLS alert. It must not answer with the echo.
        let reply = await reply(to: port, using: .tcp)
        #expect(reply.range(of: Data("hello".utf8)) == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(frames.value == 0)
    }

    @Test func aFrameThatIsTooLargeIsNotSent() async throws {
        let client = LinkConnection(to: endpoint(9), key: LinkSecurity.randomKey())
        defer { client.close() }
        await #expect(throws: LinkError("frame too large")) {
            try await client.send(Data(count: LinkConnection.largestFrame + 1))
        }
    }

    /// The other end can't be trusted after a length like that, so the connection ends.
    @Test func aFrameThatClaimsToBeTooLargeClosesTheConnection() async throws {
        let key = LinkSecurity.randomKey()
        let parameters = LinkSecurity.parameters(key: key)
        parameters.requiredInterfaceType = .loopback
        let raw = try NWListener(using: parameters)
        defer { raw.cancel() }
        let queue = DispatchQueue(label: "dev.queenbee.link.tests")
        raw.newConnectionHandler = { server in
            server.stateUpdateHandler = { state in
                if case .ready = state {
                    server.send(content: Data([0xFF, 0xFF, 0xFF, 0xFF]), completion: .contentProcessed { _ in })
                }
            }
            server.start(queue: queue)
        }
        let (ports, continuation) = AsyncStream.makeStream(of: UInt16.self)
        raw.stateUpdateHandler = { state in
            if case .ready = state { continuation.yield(raw.port?.rawValue ?? 0) }
        }
        raw.start(queue: queue)
        var port: UInt16 = 0
        for await ready in ports { port = ready; break }
        let client = LinkConnection(to: endpoint(port), key: key)
        defer { client.close() }
        try await client.start()
        await #expect(throws: LinkError("frame too large")) { _ = try await client.receive() }
        await #expect(throws: (any Error).self) { try await client.send(Data("hello".utf8)) }
    }

    /// A listener that expects only small messages takes nothing bigger, and ends the connection that sent it.
    @Test func aFrameOverTheListenersOwnLimitClosesTheConnection() async throws {
        let key = LinkSecurity.randomKey()
        let frames = Tally()
        let (listener, port) = try await echo(key: key, frames: frames, largestInbound: 1024)
        defer { listener.stop() }
        let client = LinkConnection(to: endpoint(port), key: key)
        defer { client.close() }
        try await client.start()
        try await client.send(Data(count: 1024))
        #expect(try await client.receive().count == 1025)
        try await client.send(Data(count: 1025))
        await #expect(throws: (any Error).self) { _ = try await client.receive() }
        #expect(frames.value == 1)
    }

    @Test func aListenerStoppedBeforeItStartsThrows() async throws {
        let listener = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true)
        listener.stop()
        await #expect(throws: LinkError("closed")) { _ = try await listener.start { $0.close() } }
    }

    @Test func aListenerStoppedWhileItStartsThrowsOrIsStopped() async throws {
        let listener = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true)
        async let port = listener.start { $0.close() }
        listener.stop()
        // Either the stop won, or the listener was ready first. It must not hang.
        _ = try? await port
    }

    /// Stopping on purpose is not a failure.
    @Test func stoppingAListenerIsNotReportedAsAFailure() async throws {
        let failures = Tally()
        let listener = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true)
        let port = try await listener.start(onFailure: { _ in failures.add() }) { $0.close() }
        #expect(port != 0)
        listener.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(failures.value == 0)
    }

    /// A listener on a fixed port, stopped and waited for, leaves the port to the next one at once.
    @Test func aStoppedListenerLetsGoOfItsPortForTheNext() async throws {
        let first = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true)
        let port = try await first.start { $0.close() }
        first.stop()
        await first.whenCancelled()
        let second = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true, port: port)
        #expect(try await second.start { $0.close() } == port)
        second.stop()
        await second.whenCancelled()
    }

    /// One never started has nothing to let go of, and waiting on it doesn't hang.
    @Test func waitingOnAListenerNeverStartedReturnsAtOnce() async throws {
        let listener = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true)
        listener.stop()
        await listener.whenCancelled()
    }

    /// A key of the wrong length is left out rather than stopping the app, and a listener with no key it can use
    /// isn't made.
    @Test func aKeyOfTheWrongLengthNeverStopsTheApp() throws {
        _ = LinkSecurity.parameters(keys: ["a": Data(repeating: 1, count: 31), "b": LinkSecurity.randomKey()])
        _ = LinkSecurity.parameters(key: Data())
        #expect(throws: LinkError("no usable key")) {
            _ = try LinkListener(keys: ["a": Data(repeating: 1, count: 16)], service: nil, localOnly: true)
        }
        _ = try LinkListener(keys: ["a": Data(repeating: 1, count: 16), "b": LinkSecurity.randomKey()], service: nil, localOnly: true)
    }

    /// A port still held is tried again in a moment, a few times, and then slowly, like any other failure.
    @Test func aPortStillHeldIsTriedAgainQuicklyAFewTimes() {
        let held = LinkError("in use", addressInUse: true)
        #expect(ListenRetry.wait(after: held, quickSoFar: 0) == ListenRetry.quick)
        #expect(ListenRetry.wait(after: held, quickSoFar: ListenRetry.quickTries - 1) == ListenRetry.quick)
        #expect(ListenRetry.wait(after: held, quickSoFar: ListenRetry.quickTries) == ListenRetry.slow)
        #expect(ListenRetry.wait(after: LinkError("other"), quickSoFar: 0) == ListenRetry.slow)
        #expect(ListenRetry.wait(after: CancellationError(), quickSoFar: 0) == ListenRetry.slow)
    }
}
