import Testing
import Foundation
@testable import Core

@Suite struct GoalsTests {
    @Test func metBeforePeriodEnds() {
        #expect(goalStatus(target: 12, actual: 12.4, elapsedFraction: 0.6, closed: false) == .met)
    }

    @Test func missedWhenClosedShort() {
        #expect(goalStatus(target: 4, actual: 2.5, elapsedFraction: 1, closed: true) == .missed)
    }

    @Test func onTrackVersusBehindByPace() {
        #expect(goalStatus(target: 12, actual: 6, elapsedFraction: 0.5, closed: false) == .onTrack)
        #expect(goalStatus(target: 12, actual: 5.9, elapsedFraction: 0.5, closed: false) == .behind)
        #expect(goalStatus(target: 12, actual: 0, elapsedFraction: 0, closed: false) == .onTrack)
    }

    @Test func dailyGoalDays() {
        let cal = PeriodCalendar(timeZone: TimeZone(identifier: "Europe/London")!)
        let weekdays: Set<Int> = [1, 2, 3, 4, 5]
        #expect(hasDailyGoal(on: date("2026-11-24T12:00:00Z"), days: weekdays, calendar: cal))  // Tue
        #expect(!hasDailyGoal(on: date("2026-11-28T12:00:00Z"), days: weekdays, calendar: cal)) // Sat
    }
}
