import Foundation
import Security
import Testing
@testable import QueenBeeLink

@Suite struct LinkSecurityTests {
    @Test func keysAreLongAndDiffer() {
        let a = LinkSecurity.randomKey(), b = LinkSecurity.randomKey()
        #expect(a.count == 32)
        #expect(a != b)
    }

    /// Only a key the Keychain says isn't there takes a device off the list. A locked Keychain, a prompt turned
    /// down or one that couldn't be shown leave it paired, to be read again later.
    @Test func onlyAKeyThatIsGoneUnpairsADevice() {
        let key = Data(repeating: 7, count: 32)
        #expect(StoredKey(status: errSecSuccess, data: key) == .found(key))
        #expect(StoredKey(status: errSecSuccess, data: key).keepsDevice)
        #expect(StoredKey(status: errSecItemNotFound, data: nil) == .missing)
        #expect(!StoredKey(status: errSecItemNotFound, data: nil).keepsDevice)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNotAvailable] {
            #expect(StoredKey(status: status, data: nil) == .unreadable(status))
            #expect(StoredKey(status: status, data: nil).keepsDevice)
            #expect(StoredKey(status: status, data: nil).key == nil)
        }
        #expect(StoredKey(status: errSecSuccess, data: nil).keepsDevice)
    }

    @Test func aPairingCodeSurvivesBeingTyped() {
        let code = PairingCode()
        #expect(code.text.hasPrefix("queenbee-pair:1:"))
        #expect(PairingCode(text: code.text) == code)
        #expect(PairingCode(text: "  " + code.text + "\n") == code)
    }

    @Test func junkIsNotAPairingCode() {
        #expect(PairingCode(text: "") == nil)
        #expect(PairingCode(text: "queenbee-pair:2:AAAA") == nil)
        #expect(PairingCode(text: "queenbee-pair:1:short") == nil)
        #expect(PairingCode(text: "https://example.com") == nil)
    }
}
