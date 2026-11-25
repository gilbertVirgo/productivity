import Testing
@testable import Stint

@Suite struct AppStateTests {
    @Test func remainingTextFormats() {
        #expect(remainingText(1066) == "17:46")
        #expect(remainingText(0) == "0:00")
        #expect(remainingText(-5) == "0:00")
        #expect(remainingText(1500) == "25:00")
    }
}
