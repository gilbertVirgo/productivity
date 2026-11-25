import Testing
import Core

@Suite struct SmokeTests {
    @Test func coreLinks() { #expect(PointRules.sessionComplete == 10) }
}
