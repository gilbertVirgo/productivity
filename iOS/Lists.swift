import Foundation
import Core
import StintData

private func byOrder(_ a: TaskItem, _ b: TaskItem) -> Bool { (a.sort, a.createdAt) < (b.sort, b.createdAt) }

/// Today's "Up next": open tasks of live projects.
func upNext(_ tasks: [TaskItem], limit: Int) -> [TaskItem] {
    Array(tasks.filter { $0.doneAt == nil && $0.project != nil && $0.project?.archivedAt == nil }.sorted(by: byOrder).prefix(limit))
}

/// Tasks tab: open tasks plus those finished today (so a mis-tap can be undone).
func visibleTasks(_ tasks: [TaskItem], now: Date, calendar: PeriodCalendar) -> [TaskItem] {
    let today = calendar.dayInterval(containing: now)
    return tasks.filter { t in t.doneAt.map { $0 >= today.start && $0 < today.end } ?? true }.sorted(by: byOrder)
}

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
