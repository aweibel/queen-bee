import Foundation
import Network
import Testing
@testable import QueenBeeLink

@Suite struct LinkConnectionTests {
    private func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    /// A listener that sends back whatever it gets with "!" on the end.
    private func echo(key: Data) async throws -> (listener: LinkListener, port: UInt16) {
        let listener = try LinkListener(key: key, service: nil, localOnly: true)
        let port = try await listener.start { server in
            Task {
                do {
                    try await server.start()
                    while true { try await server.send(try await server.receive() + Data("!".utf8)) }
                } catch { server.close() }
            }
        }
        return (listener, port)
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
}
