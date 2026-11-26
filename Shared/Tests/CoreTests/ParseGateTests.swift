import Testing
@testable import Core

@Suite struct ParseGateTests {
    @Test func sameTextSendsOnce() {
        var g = ParseGate()
        #expect(g.begin("a") == 1)
        #expect(g.begin("a") == nil)
        #expect(g.begin("a b") == 2)
        #expect(g.begin("a b", force: true) == 3)
    }

    @Test func onlyNewestIsLatest() {
        var g = ParseGate()
        let old = g.begin("a")!, new = g.begin("a b")!
        #expect(!g.isLatest(old))
        #expect(g.isLatest(new))
    }

    @Test func failedNewestCanBeResent() {
        var g = ParseGate()
        let n = g.begin("a")!
        g.failed(n)
        #expect(g.begin("a") == 2)
        g.failed(1) // an older failure doesn't reopen the newest text
        #expect(g.begin("a") == nil)
    }
}
