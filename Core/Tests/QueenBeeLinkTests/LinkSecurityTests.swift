import Foundation
import Testing
@testable import QueenBeeLink

@Suite struct LinkSecurityTests {
    @Test func keysAreLongAndDiffer() {
        let a = LinkSecurity.randomKey(), b = LinkSecurity.randomKey()
        #expect(a.count == 32)
        #expect(a != b)
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
