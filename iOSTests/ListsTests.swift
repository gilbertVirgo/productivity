import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct ListsTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func goalHistoryGroupsByWeekNewestFirst() {
        let p = UUID()
        func r(_ period: String, _ day: String) -> GoalResultRecord {
            GoalResultRecord(projectID: p, period: period, periodStart: date(day), goalKind: "hours", target: 2, actual: 1, met: false)
        }
        let h = goalHistory([r("day", "2026-11-24T00:00:00Z"), r("week", "2026-11-16T00:00:00Z"),
                             r("week", "2026-11-23T00:00:00Z"), r("day", "2026-11-23T00:00:00Z")])
        #expect(h.map(\.weekStart) == [date("2026-11-23T00:00:00Z"), date("2026-11-16T00:00:00Z")])
        #expect(h[0].results.map(\.period) == ["week", "day", "day"])
        #expect(h[0].results[1].periodStart == date("2026-11-23T00:00:00Z"))
    }
}

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
