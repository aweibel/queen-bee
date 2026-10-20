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

    /// A handshake that failed may have been cut off, or made with something copying the Mac's name. It is never
    /// on its own a reason to stop trying.
    @Test func aKeyTheMacTurnedDownMeansTryAgain() {
        #expect(LinkVerdict.failed(LinkError("bad key", keyRefused: true)) == .tryAgain)
    }

    @Test func onlySeveralRefusalsInARowPutTheKeyInDoubt() {
        var doubt = KeyDoubt()
        let refused = LinkError("bad key", keyRefused: true)
        doubt.note(refused)
        doubt.note(refused)
        #expect(!doubt.doubtsKey)
        // Something else in between starts the count again: the Mac wasn't there to judge the key.
        doubt.note(LinkError("timed out"))
        doubt.note(refused)
        doubt.note(refused)
        #expect(!doubt.doubtsKey)
        // Giving up from here says nothing either way.
        doubt.note(CancellationError())
        doubt.note(refused)
        #expect(doubt.doubtsKey)
        // Let in, and the doubt is gone.
        doubt.note(nil)
        #expect(!doubt.doubtsKey && doubt.refusals == 0)
    }

    @Test func aKeyInDoubtIsStillTriedSlowly() {
        #expect(LinkVerdict.wait(beforeAttempt: 0, doubtingKey: true) == 30)
        #expect(LinkVerdict.wait(beforeAttempt: 9, doubtingKey: true) == 30)
    }

    /// One that drops within seconds of being let in, every time, must not be made again every second.
    @Test func onlyAConnectionThatLastedStartsTheWaitsAgain() {
        #expect(!LinkVerdict.resetsWaits(afterConnectedFor: 0.5))
        #expect(!LinkVerdict.resetsWaits(afterConnectedFor: 9))
        #expect(LinkVerdict.resetsWaits(afterConnectedFor: 10))
        #expect(LinkVerdict.resetsWaits(afterConnectedFor: 3_600))
    }

    @Test func onlyTheErrorsOfTwoDifferentKeysCountAsARefusal() {
        for status: OSStatus in [-9846, -9820, -9845, -9821, -9825, -9864] { #expect(LinkError.isKeyRefusal(tlsStatus: status)) }
        // Closed part-way, cut off, refused outright, or a handshake that simply failed.
        for status: OSStatus in [-9806, -9805, -9816, -9844, -9824, errSecSuccess] { #expect(!LinkError.isKeyRefusal(tlsStatus: status)) }
    }

    @Test func anythingElseGoingWrongMeansTryAgain() {
        #expect(LinkVerdict.failed(LinkError("timed out")) == .tryAgain)
        #expect(LinkVerdict.failed(LinkError("closed")) == .tryAgain)
        #expect(LinkVerdict.failed(CancellationError()) == .tryAgain)
    }

    @Test func retriesBackOffToEightSeconds() {
        #expect((0..<6).map { LinkVerdict.wait(beforeAttempt: $0) } == [1, 2, 4, 8, 8, 8])
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
        #expect(wrongKey.map(LinkVerdict.failed) == .tryAgain)

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
