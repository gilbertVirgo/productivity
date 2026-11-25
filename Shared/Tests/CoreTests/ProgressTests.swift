import Testing
import Foundation
@testable import Core

@Suite struct ProgressTests {
    let a = UUID(), b = UUID()
    let day = DateInterval(start: date("2026-11-24T00:00:00Z"), end: date("2026-11-25T00:00:00Z"))

    var sessions: [SessionSummary] {[
        SessionSummary(projectID: a, startedAt: date("2026-11-24T09:00:00Z"), focusedSec: 3000, breakSec: 600),
        SessionSummary(projectID: a, startedAt: date("2026-11-24T23:50:00Z"), focusedSec: 1200, breakSec: 0),  // crosses midnight: counts for 24th
        SessionSummary(projectID: b, startedAt: date("2026-11-24T14:00:00Z"), focusedSec: 1500, breakSec: 300),
        SessionSummary(projectID: a, startedAt: date("2026-11-25T00:00:00Z"), focusedSec: 900, breakSec: 120),  // next day
    ]}

    @Test func focusedPerProjectByStartDay() {
        #expect(focusedSec(sessions, projectID: a, in: day) == 4200)
        #expect(focusedSec(sessions, projectID: b, in: day) == 1500)
    }

    @Test func breakAcrossProjects() {
        #expect(breakSec(sessions, in: day) == 900)
    }
}
