import Testing
import Foundation
@testable import Stint

@Suite struct NudgeTests {
    @Test func offTaskLine() {
        #expect(Stint.offTaskLine(elapsedSec: 42) == "Off task so far 0:42 · −0 pts")
        #expect(Stint.offTaskLine(elapsedSec: 125) == "Off task so far 2:05 · −4 pts")
    }
}
