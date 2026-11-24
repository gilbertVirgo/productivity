import Foundation

/// Day and week boundaries in the owner's timezone. Weeks start Monday (ISO 8601).
public struct PeriodCalendar: Sendable {
    let calendar: Calendar

    public init(timeZone: TimeZone) {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = timeZone
        calendar = c
    }

    public func dayInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)!
    }

    public func weekInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    /// 1 = Monday … 7 = Sunday.
    public func isoWeekday(of date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    public func elapsedFraction(of interval: DateInterval, at now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(interval.start) / interval.duration))
    }
}
