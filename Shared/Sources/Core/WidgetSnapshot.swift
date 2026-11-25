import Foundation

/// What the phone's Today screen and the widgets show (spec §6.9). Built by the app; widgets get it as JSON.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var colorHex: String
        public var weekFocusedSec: Int
        public var weeklyGoalSec: Int?
        public var todayFocusedSec: Int
        /// Today's daily goal; nil when the project has none today.
        public var dailyGoalSec: Int?
        /// The daily goal and its ISO weekdays, kept so `asOf` can recompute `dailyGoalSec` for a later day.
        public var dailyTargetSec: Int?
        public var dailyGoalDays: [Int]
    }

    public struct ProjectGoals: Sendable {
        public var id: UUID, name: String, colorHex: String
        public var weeklyHoursGoal: Double?, dailyHoursGoal: Double?
        public var dailyGoalDays: [Int]
        public init(id: UUID, name: String, colorHex: String, weeklyHoursGoal: Double?, dailyHoursGoal: Double?, dailyGoalDays: [Int]) {
            self.id = id; self.name = name; self.colorHex = colorHex
            self.weeklyHoursGoal = weeklyHoursGoal; self.dailyHoursGoal = dailyHoursGoal; self.dailyGoalDays = dailyGoalDays
        }
    }

    public var generatedAt: Date
    public var lines: [Line]
    public var pointsToday: Int

    public var todayFocusedSec: Int { lines.reduce(0) { $0 + $1.todayFocusedSec } }
    public var todayGoalSec: Int { lines.compactMap(\.dailyGoalSec).reduce(0, +) }

    /// Start widget: the project with the most daily-goal time left today; ties go to the first line. nil when all are met.
    public var startProjectID: UUID? {
        lines.compactMap { l in l.dailyGoalSec.map { (l.id, $0 - l.todayFocusedSec) } }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func sec(_ hours: Double?) -> Int? { hours.map { Int(($0 * 3600).rounded()) } }

    private static func goal(_ l: Line, on now: Date, _ calendar: PeriodCalendar) -> Int? {
        hasDailyGoal(on: now, days: Set(l.dailyGoalDays), calendar: calendar) ? l.dailyTargetSec : nil
    }

    public static func build(projects: [ProjectGoals], sessions: [SessionSummary], pointsToday: Int,
                             now: Date, calendar: PeriodCalendar) -> WidgetSnapshot {
        let day = calendar.dayInterval(containing: now), week = calendar.weekInterval(containing: now)
        let lines = projects.map { p in
            var l = Line(id: p.id, name: p.name, colorHex: p.colorHex,
                         weekFocusedSec: focusedSec(sessions, projectID: p.id, in: week),
                         weeklyGoalSec: sec(p.weeklyHoursGoal),
                         todayFocusedSec: focusedSec(sessions, projectID: p.id, in: day),
                         dailyGoalSec: nil, dailyTargetSec: sec(p.dailyHoursGoal), dailyGoalDays: p.dailyGoalDays)
            l.dailyGoalSec = goal(l, on: now, calendar)
            return l
        }
        return WidgetSnapshot(generatedAt: now, lines: lines, pointsToday: pointsToday)
    }

    /// The snapshot as a widget should show it at `now`: today's numbers reset once the day it was built has
    /// ended, week numbers once the week has; daily goals follow `now`'s weekday.
    public func asOf(_ now: Date, calendar: PeriodCalendar) -> WidgetSnapshot {
        var s = self
        let sameDay = calendar.dayInterval(containing: now).contains(generatedAt)
        let sameWeek = calendar.weekInterval(containing: now).contains(generatedAt)
        for i in s.lines.indices {
            if !sameDay { s.lines[i].todayFocusedSec = 0 }
            if !sameWeek { s.lines[i].weekFocusedSec = 0 }
            s.lines[i].dailyGoalSec = Self.goal(s.lines[i], on: now, calendar)
        }
        if !sameDay { s.pointsToday = 0 }
        return s
    }
}
