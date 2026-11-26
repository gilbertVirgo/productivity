import Testing
import Core

@Suite struct SmokeTests {
    @Test func coreLinks() { #expect(PointRules.perFocusedMinute == 1) }
}
