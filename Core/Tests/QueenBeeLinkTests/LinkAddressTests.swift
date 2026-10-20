import Foundation
import Network
import QueenBeeCore
import Security
import Testing
@testable import QueenBeeLink

/// The listener a device reaches by the Mac's address, which takes every paired device's key, and what keeps
/// one device from passing itself off as another there.
@Suite struct LinkAddressTests {
    private func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    /// A listener holding two devices' keys, which sends each connection the binding it worked out.
    private func listener(_ keys: [String: Data]) async throws -> (LinkListener, UInt16) {
        let listener = try LinkListener(keys: keys, service: nil, localOnly: true)
        let port = try await listener.start { server in
            Task {
                do {
                    try await server.start()
                    try await server.send(server.binding() ?? Data())
                } catch { server.close() }
            }
        }
        return (listener, port)
    }

    @Test func eachDeviceGetsInWithItsOwnKeyUnderItsOwnName() async throws {
        let a = LinkSecurity.randomKey(), b = LinkSecurity.randomKey()
        let (listener, port) = try await listener(["a": a, "b": b])
        defer { listener.stop() }
        for (name, key) in [("a", a), ("b", b)] {
            let client = LinkConnection(to: endpoint(port), key: key, identity: name)
            defer { client.close() }
            try await client.start()
            // Both ends work out the same binding, and it is new for every connection.
            let binding = try #require(client.binding())
            #expect(try await client.receive() == binding)
            #expect(binding.count == 32)
        }
    }

    /// A device can't use another's name with its own key, nor a name the listener doesn't know.
    @Test func aKeyUnderAnotherNameGetsNothing() async throws {
        let a = LinkSecurity.randomKey(), b = LinkSecurity.randomKey()
        let (listener, port) = try await listener(["a": a, "b": b])
        defer { listener.stop() }
        for (name, key) in [("a", b), ("c", a), (LinkSecurity.soleIdentity, a)] {
            let client = LinkConnection(to: endpoint(port), key: key, identity: name)
            defer { client.close() }
            await #expect(throws: LinkError.self) { try await client.start(timeout: 4) }
        }
    }

    /// The proof is what says which device it is: only the device's own key makes it, and only for this connection.
    @Test func aProofIsTiedToTheKeyAndTheConnection() {
        let key = LinkSecurity.randomKey(), other = LinkSecurity.randomKey()
        let binding = LinkSecurity.randomKey(), another = LinkSecurity.randomKey()
        let proof = LinkSecurity.proof(key: key, binding: binding)
        #expect(LinkSecurity.checks(proof, key: key, binding: binding))
        #expect(!LinkSecurity.checks(proof, key: other, binding: binding))
        #expect(!LinkSecurity.checks(proof, key: key, binding: another))
        #expect(!LinkSecurity.checks(Data(), key: key, binding: binding))
    }

    @Test func aListenerOnAFixedPortCanBeStartedAgainOnIt() async throws {
        let probe = try LinkListener(key: LinkSecurity.randomKey(), service: nil, localOnly: true)
        let free = try await probe.start { _ in }
        probe.stop()
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<2 {
            let listener = try LinkListener(keys: ["a": LinkSecurity.randomKey()], service: nil, localOnly: true, port: free)
            #expect(try await listener.start { _ in } == free)
            listener.stop()
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

@Suite struct MacAddressTests {
    @Test func anAddressIsReadAsItIsTyped() {
        #expect(MacAddress(text: "mac.tail1234.ts.net") == MacAddress(host: "mac.tail1234.ts.net", port: Remote.addressPort))
        #expect(MacAddress(text: " 100.64.0.7:6000 \n") == MacAddress(host: "100.64.0.7", port: 6000))
        #expect(MacAddress(text: "[fd7a:115c::1]:6000") == MacAddress(host: "fd7a:115c::1", port: 6000))
        #expect(MacAddress(text: "fd7a:115c::1") == MacAddress(host: "fd7a:115c::1", port: Remote.addressPort))
        #expect(MacAddress(text: "[fd7a::1]") == MacAddress(host: "fd7a::1", port: Remote.addressPort))
    }

    @Test func whatCantBeAnAddressIsNot() {
        for text in ["", "  ", "my mac", "http://mac", "mac:", "mac:0", "mac:70000", "mac:port", "[fd7a::1", "[fd7a::1]x", ":6000"] {
            #expect(MacAddress(text: text) == nil, "\(text)")
        }
    }

    @Test func anAddressIsShownAsItWouldBeTyped() {
        #expect(MacAddress(host: "mac.local").text == "mac.local")
        #expect(MacAddress(host: "10.0.0.2", port: 6000).text == "10.0.0.2:6000")
        #expect(MacAddress(host: "fd7a::1", port: 6000).text == "[fd7a::1]:6000")
        for text in ["mac.local", "10.0.0.2:6000", "[fd7a::1]:6000"] { #expect(MacAddress(text: text)?.text == text) }
        #expect(MacAddress(host: "mac.local").endpoint != nil)
    }
}

@Suite struct LinkGateTests {
    /// Which of these addresses, in turn, were let in.
    private func admitted(_ addresses: [String?], to gate: inout LinkGate) -> [Bool] { addresses.map { gate.admit($0) } }

    @Test func tooManyFromOneAddressAreTurnedAway() {
        var gate = LinkGate(most: 10, mostFromOne: 2)
        // Another address is let in all the same.
        #expect(admitted(["10.0.0.2", "10.0.0.2", "10.0.0.2", "10.0.0.3"], to: &gate) == [true, true, false, true])
        gate.release("10.0.0.2")
        #expect(admitted(["10.0.0.2"], to: &gate) == [true])
        #expect(gate.count == 3)
    }

    @Test func tooManyInAllAreTurnedAway() {
        var gate = LinkGate(most: 3, mostFromOne: 2)
        #expect(admitted(["a", "b", nil, "c"], to: &gate) == [true, true, true, false])
        gate.release(nil)
        #expect(admitted(["c"], to: &gate) == [true])
    }

    /// Letting go of one that was never let in changes nothing.
    @Test func releasingWhatWasNeverAdmittedDoesNothing() {
        var gate = LinkGate(most: 2, mostFromOne: 2)
        gate.release("a")
        #expect(gate.count == 0)
        #expect(admitted(["a", "a", "a"], to: &gate) == [true, true, false])
    }
}

@Suite struct KeyStoreTests {
    private let key = Data(repeating: 7, count: 32)

    @Test func aKeyFromBeforeIsMovedOverTheFirstTimeItIsRead() {
        let modern = MemoryKeyStore(), legacy = MemoryKeyStore(["device-a": key])
        let store = MigratingKeyStore(modern: modern, legacy: legacy)
        #expect(store.lookUp("device-a") == .found(key))
        #expect(modern.stored == ["device-a": key])
        #expect(legacy.stored.isEmpty)
        #expect(store.lookUp("device-a") == .found(key))
    }

    /// Where the new place can't be used, nothing moves and the key is kept where it was.
    @Test func aKeyStaysWhereItIsWhenTheNewPlaceCantBeUsed() {
        let modern = MemoryKeyStore(), legacy = MemoryKeyStore(["device-a": key])
        modern.lookUpFails = errSecMissingEntitlement
        modern.writeFails = errSecMissingEntitlement
        let store = MigratingKeyStore(modern: modern, legacy: legacy)
        #expect(store.lookUp("device-a") == .found(key))
        #expect(legacy.stored == ["device-a": key])
        #expect(store.lookUp("device-b") == .missing)
        // A new key goes where it can.
        #expect(store.write(key, "device-b") == errSecSuccess)
        #expect(legacy.stored["device-b"] == key)
    }

    /// A key that couldn't be written to the new place stays in the old one, and is found there.
    @Test func aKeyIsNotDeletedUntilItHasBeenKeptElsewhere() {
        let modern = MemoryKeyStore(), legacy = MemoryKeyStore(["device-a": key])
        modern.writeFails = errSecInteractionNotAllowed
        let store = MigratingKeyStore(modern: modern, legacy: legacy)
        #expect(store.lookUp("device-a") == .found(key))
        #expect(legacy.stored == ["device-a": key])
        #expect(modern.stored.isEmpty)
    }

    /// Locked, the new place says nothing, and a key that isn't in the old one isn't known to be gone either.
    @Test func aLockedKeychainNeverMakesAKeyMissing() {
        let modern = MemoryKeyStore(["device-a": key]), legacy = MemoryKeyStore()
        modern.lookUpFails = errSecInteractionNotAllowed
        let store = MigratingKeyStore(modern: modern, legacy: legacy)
        #expect(store.lookUp("device-a") == .unreadable(errSecInteractionNotAllowed))
        #expect(store.lookUp("device-a").keepsDevice)
    }

    @Test func writingAndDeletingTouchBothPlaces() {
        let modern = MemoryKeyStore(), legacy = MemoryKeyStore(["device-a": Data(repeating: 1, count: 32)])
        let store = MigratingKeyStore(modern: modern, legacy: legacy)
        #expect(store.write(key, "device-a") == errSecSuccess)
        // An older key left behind could be found again one day, so it goes.
        #expect(legacy.stored.isEmpty)
        #expect(store.accounts() == ["device-a"])
        #expect(store.delete("device-a") == errSecSuccess)
        #expect(modern.stored.isEmpty && legacy.stored.isEmpty)
        #expect(store.lookUp("device-a") == .missing)
        // Nothing left to delete is not a failure.
        #expect(MigratingKeyStore.gone(store.delete("device-a")))
    }

    /// A new key that only the old place would take: the key the new place held goes first, or it would be read in
    /// place of the new one.
    @Test func aNewKeyKeptInTheOldPlaceIsNotShadowedByAnOlderOne() {
        let old = Data(repeating: 1, count: 32)
        let modern = MemoryKeyStore(["device-a": old]), legacy = MemoryKeyStore()
        modern.writeFails = errSecInteractionNotAllowed
        let store = MigratingKeyStore(modern: modern, legacy: legacy)
        #expect(store.write(key, "device-a") == errSecSuccess)
        #expect(modern.stored.isEmpty)
        #expect(store.lookUp("device-a") == .found(key))
    }

    /// When the older key can't be got rid of either, the write fails and the key stays as it was.
    @Test func aWriteFailsWhenAnOlderKeyWouldShadowIt() {
        let old = Data(repeating: 1, count: 32)
        let modern = MemoryKeyStore(["device-a": old]), legacy = MemoryKeyStore()
        modern.writeFails = errSecInteractionNotAllowed
        modern.deleteFails = errSecInteractionNotAllowed
        let store = MigratingKeyStore(modern: modern, legacy: legacy)
        #expect(store.write(key, "device-a") == errSecInteractionNotAllowed)
        #expect(legacy.stored.isEmpty)
        #expect(store.lookUp("device-a") == .found(old))
    }

    @Test func aDeleteThatFailsSaysSo() {
        let modern = MemoryKeyStore(["device-a": key]), legacy = MemoryKeyStore()
        modern.deleteFails = errSecInteractionNotAllowed
        let store = MigratingKeyStore(modern: modern, legacy: legacy)
        #expect(store.delete("device-a") == errSecInteractionNotAllowed)
        #expect(!MigratingKeyStore.gone(errSecInteractionNotAllowed))
    }

    /// The list made again from the keys leaves out devices that were removed, whose keys couldn't be deleted.
    @Test func removedDevicesDontComeBackFromTheirKeys() {
        let accounts = ["device-a", "device-b", "other", DeviceKeys.account("c")]
        #expect(DeviceKeys.pairedIDs(in: accounts, leavingOut: []) == ["a", "b", "c"])
        #expect(DeviceKeys.pairedIDs(in: accounts, leavingOut: ["b"]) == ["a", "c"])
    }

    /// A key of the wrong length can never be used, so it is as good as gone.
    @Test func aKeyOfTheWrongLengthIsMissing() {
        #expect(StoredKey.found(key).checked == .found(key))
        #expect(StoredKey.found(Data(repeating: 1, count: 31)).checked == .missing)
        #expect(StoredKey.found(Data()).checked == .missing)
        #expect(StoredKey.unreadable(errSecInteractionNotAllowed).checked == .unreadable(errSecInteractionNotAllowed))
        #expect(StoredKey.missing.checked == .missing)
    }
}
