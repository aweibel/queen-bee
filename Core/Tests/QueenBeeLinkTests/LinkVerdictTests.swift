import Foundation
import Network
import QueenBeeCore
import Testing
@testable import QueenBeeLink

@Suite struct LinkVerdictTests {
    private func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    /// Starts a connection that is expected to fail and returns what it failed with.
    private func failure(to port: UInt16, key: Data) async -> LinkError? {
        let client = LinkConnection(to: endpoint(port), key: key)
        defer { client.close() }
        do {
            try await client.start(timeout: 4)
            return nil
        } catch {
            return error as? LinkError
        }
    }

    @Test func theUnpairedRefusalMeansPairAgain() {
        #expect(LinkVerdict.refused(Remote.unpairedRefusal) == .mustPairAgain(Remote.unpairedRefusal))
    }

    @Test func anyOtherRefusalMeansUpdate() {
        let text = "Update Queen Bee on this device, so both are on the same version."
        #expect(LinkVerdict.refused(text) == .needsUpdate(text))
    }

    @Test func aKeyTheMacTurnedDownMeansPairAgain() {
        #expect(LinkVerdict.failed(LinkError("bad key", keyRefused: true)) == .mustPairAgain(LinkVerdict.keyRefusedText))
    }

    @Test func anythingElseGoingWrongMeansTryAgain() {
        #expect(LinkVerdict.failed(LinkError("timed out")) == .tryAgain)
        #expect(LinkVerdict.failed(LinkError("closed")) == .tryAgain)
        #expect(LinkVerdict.failed(CancellationError()) == .tryAgain)
    }

    @Test func retriesBackOffToEightSeconds() {
        #expect((0..<6).map(LinkVerdict.wait(beforeAttempt:)) == [1, 2, 4, 8, 8, 8])
    }

    @Test func aListenerThatDoesNotAnswerTwiceRunningMeansTheMacIsOutOfReach() {
        #expect((0..<4).map(LinkVerdict.isOutOfReach(afterMisses:)) == [false, false, true, true])
    }

    /// The real thing: a listener with another key says so in a way the device can tell from nobody being there.
    @Test func aListenerWithAnotherKeyIsToldApartFromNoListener() async throws {
        let listener = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true)
        let port = try await listener.start { server in Task { try? await server.start() } }
        let wrongKey = await failure(to: port, key: LinkSecurity.randomKey())
        #expect(wrongKey?.keyRefused == true)
        #expect(wrongKey.map(LinkVerdict.failed) == .mustPairAgain(LinkVerdict.keyRefusedText))

        listener.stop()
        try await Task.sleep(for: .milliseconds(200))
        let nobody = await failure(to: port, key: LinkSecurity.randomKey())
        #expect(nobody != nil && nobody?.keyRefused == false)
        #expect(nobody.map(LinkVerdict.failed) == .tryAgain)
    }

    @Test func aListenerTakesThePortItIsGiven() async throws {
        // Found by asking for any port, then letting it go.
        let probe = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true)
        let free = try await probe.start { _ in }
        probe.stop()
        try await Task.sleep(for: .milliseconds(200))
        let listener = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true, port: free)
        defer { listener.stop() }
        #expect(try await listener.start { _ in } == free)
    }
}
