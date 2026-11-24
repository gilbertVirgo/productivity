import Testing
import Foundation
@testable import Core

@Suite struct PeriodsTests {
    let london = PeriodCalendar(timeZone: TimeZone(identifier: "Europe/London")!)
    let sydney = PeriodCalendar(timeZone: TimeZone(identifier: "Australia/Sydney")!)

    @Test func weekStartsMonday() {
        let w = london.weekInterval(containing: date("2026-11-24T16:52:00Z")) // Tue
        #expect(w.start == date("2026-11-23T00:00:00Z"))
        #expect(w.end == date("2026-11-30T00:00:00Z"))
    }

    @Test func lateSundayIsSameWeek() {
        let w = london.weekInterval(containing: date("2026-11-29T23:30:00Z"))
        #expect(w.start == date("2026-11-23T00:00:00Z"))
    }

    @Test func dayUsesOwnerTimezone() {
        // 23:30 UTC Monday is already Tuesday 10:30 in Sydney (UTC+11 in November).
        let d = sydney.dayInterval(containing: date("2026-11-23T23:30:00Z"))
        #expect(d.start == date("2026-11-24T00:00:00+11:00"))
        #expect(sydney.isoWeekday(of: date("2026-11-23T23:30:00Z")) == 2)
    }

    @Test func dstSpringForwardDayIs23Hours() {
        // UK clocks go forward Sunday 29 March 2026.
        #expect(london.dayInterval(containing: date("2026-03-29T12:00:00Z")).duration == 23 * 3600)
        #expect(london.weekInterval(containing: date("2026-03-29T12:00:00Z")).duration == 167 * 3600)
    }

    @Test func isoWeekdays() {
        #expect(london.isoWeekday(of: date("2026-11-23T12:00:00Z")) == 1) // Mon
        #expect(london.isoWeekday(of: date("2026-11-28T12:00:00Z")) == 6) // Sat
        #expect(london.isoWeekday(of: date("2026-11-29T12:00:00Z")) == 7) // Sun
    }

    @Test func elapsedFractionIsClamped() {
        let w = london.weekInterval(containing: date("2026-11-24T00:00:00Z"))
        #expect(london.elapsedFraction(of: w, at: date("2026-11-26T12:00:00Z")) == 0.5)
        #expect(london.elapsedFraction(of: w, at: date("2026-11-01T00:00:00Z")) == 0)
        #expect(london.elapsedFraction(of: w, at: date("2026-12-25T00:00:00Z")) == 1)
    }
}
