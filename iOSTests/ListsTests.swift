import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct ListsTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func upNextSkipsDoneAndArchivedAndSorts() throws {
        // Keep the container alive: a context alone doesn't retain its store.
        let container = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let c = container.mainContext
        let live = Project(name: "Live"), old = Project(name: "Old"); old.archivedAt = .now
        c.insert(live); c.insert(old)
        func task(_ title: String, _ sort: Int, _ p: Project, done: Bool = false) -> TaskItem {
            let t = TaskItem(title: title, sort: sort); c.insert(t); t.project = p; if done { t.doneAt = .now }; return t
        }
        let tasks = [task("b", 2, live), task("a", 1, live), task("x", 0, live, done: true), task("z", 0, old)]
        #expect(upNext(tasks, limit: 5).map(\.title) == ["a", "b"])
        #expect(upNext(tasks, limit: 1).map(\.title) == ["a"])
        withExtendedLifetime(container) {}
    }

    @Test func visibleTasksKeepsDoneToday() throws {
        let cal = PeriodCalendar(timeZone: utc)
        let now = date("2026-11-24T15:00:00Z")
        let open = TaskItem(title: "open", sort: 1)
        let today = TaskItem(title: "today", sort: 0); today.doneAt = date("2026-11-24T09:00:00Z")
        let yesterday = TaskItem(title: "yesterday", sort: 0); yesterday.doneAt = date("2026-11-23T09:00:00Z")
        #expect(visibleTasks([open, today, yesterday], now: now, calendar: cal).map(\.title) == ["today", "open"])
    }

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
