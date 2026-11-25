import Testing
@testable import Stint

@Suite struct AppleNonceTests {
    @Test func randomIs64HexAndUnique() {
        let a = AppleNonce.random(), b = AppleNonce.random()
        #expect(a.count == 64 && a.allSatisfy(\.isHexDigit) && a != b)
    }
    @Test func sha256KnownVector() {
        #expect(AppleNonce.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
