import Foundation

public enum GoalStatus: String, Codable, Sendable {
    case onTrack = "on_track", behind, met, missed
}

public func goalStatus(target: Double, actual: Double, elapsedFraction: Double, closed: Bool) -> GoalStatus {
    if actual >= target { return .met }
    if closed { return .missed }
    return actual >= target * elapsedFraction ? .onTrack : .behind
}

/// `days` uses ISO weekdays: 1 = Monday … 7 = Sunday.
public func hasDailyGoal(on date: Date, days: Set<Int>, calendar: PeriodCalendar) -> Bool {
    days.contains(calendar.isoWeekday(of: date))
}
