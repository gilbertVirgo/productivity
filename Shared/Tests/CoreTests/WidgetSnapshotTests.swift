import Testing
import Foundation
@testable import Core

@Suite struct WidgetSnapshotTests {
    let cal = PeriodCalendar(timeZone: TimeZone(identifier: "UTC")!)
    let a = UUID(), b = UUID()
    let now = date("2026-11-24T15:00:00Z")

    var projects: [WidgetSnapshot.ProjectGoals] {[
        .init(id: a, name: "Alpha", colorHex: "#0F7B6C", weeklyHoursGoal: 10, dailyHoursGoal: 2, dailyGoalDays: [1, 2, 3, 4, 5]),
        .init(id: b, name: "Beta", colorHex: "#B7671F", weeklyHoursGoal: nil, dailyHoursGoal: 1, dailyGoalDays: [2]),
    ]}

    func build(_ todayA: Int = 1800, _ todayB: Int = 600) -> WidgetSnapshot {
        WidgetSnapshot.build(projects: projects, sessions: [
            SessionSummary(projectID: a, startedAt: date("2026-11-23T09:00:00Z"), focusedSec: 3600, breakSec: 0), // Monday
            SessionSummary(projectID: a, startedAt: date("2026-11-24T09:00:00Z"), focusedSec: todayA, breakSec: 0),
            SessionSummary(projectID: b, startedAt: date("2026-11-24T10:00:00Z"), focusedSec: todayB, breakSec: 0),
        ], pointsToday: 42, now: now, calendar: cal)
    }

    @Test func buildsLines() {
        let s = build()
        #expect(s.lines.map(\.weekFocusedSec) == [5400, 600])
        #expect(s.lines.map(\.todayFocusedSec) == [1800, 600])
        #expect(s.lines.map(\.weeklyGoalSec) == [36000, nil])
        #expect(s.lines.map(\.dailyGoalSec) == [7200, 3600])
        #expect(s.todayFocusedSec == 2400 && s.todayGoalSec == 10800 && s.pointsToday == 42)
    }

    @Test func startPicksMostTimeLeft() {
        #expect(build().startProjectID == a)          // Alpha 5400 s left, Beta 3000 s
        #expect(build(7200, 0).startProjectID == b)   // Alpha met
        #expect(build(7200, 3600).startProjectID == nil)
    }

    @Test func nextDayZeroesTodayAndRecomputesGoals() {
        let s = build().asOf(date("2026-11-25T08:00:00Z"), calendar: cal) // Wednesday
        #expect(s.lines.map(\.todayFocusedSec) == [0, 0])
        #expect(s.pointsToday == 0)
        #expect(s.lines.map(\.weekFocusedSec) == [5400, 600])
        #expect(s.lines.map(\.dailyGoalSec) == [7200, nil]) // Beta's goal is Tuesdays only
    }

    @Test func nextWeekZeroesWeek() {
        #expect(build().asOf(date("2026-11-30T08:00:00Z"), calendar: cal).lines.map(\.weekFocusedSec) == [0, 0])
    }

    @Test func codableRoundTrip() throws {
        let s = build()
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s)) == s)
    }
}
