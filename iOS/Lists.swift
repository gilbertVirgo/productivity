import Foundation
import Core
import StintData

struct WeekGoals: Identifiable {
    var weekStart: Date
    var results: [GoalResultRecord]
    var id: Date { weekStart }
}

/// Week tab: goal results grouped by week. `periodStart` is stored as UTC midnight (Mapping), so group in UTC.
func goalHistory(_ records: [GoalResultRecord]) -> [WeekGoals] {
    let utc = PeriodCalendar(timeZone: TimeZone(identifier: "UTC")!)
    return Dictionary(grouping: records) { utc.weekInterval(containing: $0.periodStart).start }
        .map { week, rs in
            WeekGoals(weekStart: week, results: rs.sorted { ($0.period == "week" ? 0 : 1, $0.periodStart) < ($1.period == "week" ? 0 : 1, $1.periodStart) })
        }
        .sorted { $0.weekStart > $1.weekStart }
}
