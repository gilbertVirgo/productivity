import Foundation

public enum SessionEventType: String, Codable, Sendable {
    case offtaskStart = "offtask_start", offtaskEnd = "offtask_end"
    case breakStart = "break_start", breakEnd = "break_end"
    case idleStart = "idle_start", idleEnd = "idle_end"
    case sleep, wake
}

public struct SessionEvent: Hashable, Codable, Sendable {
    public var type: SessionEventType
    public var at: Date
    /// Spec §5 session_event.detail, e.g. `bundle_id` / `domain` on `offtask_start`.
    public var detail: [String: String]?

    public init(_ type: SessionEventType, at: Date, detail: [String: String]? = nil) {
        self.type = type
        self.at = at
        self.detail = detail
    }
}

public struct SessionTotals: Equatable, Sendable {
    public var focusedSec: Int
    public var offtaskSec: Int
    public var breakSec: Int
    public var idleSec: Int
    public var sleepSec: Int

    public init(focusedSec: Int = 0, offtaskSec: Int = 0, breakSec: Int = 0, idleSec: Int = 0, sleepSec: Int = 0) {
        self.focusedSec = focusedSec
        self.offtaskSec = offtaskSec
        self.breakSec = breakSec
        self.idleSec = idleSec
        self.sleepSec = sleepSec
    }
}

private func whole(_ d: Date) -> Date { Date(timeIntervalSinceReferenceDate: floor(d.timeIntervalSinceReferenceDate)) }

/// Start-type events sort before end-type events at the same instant.
private func isStart(_ t: SessionEventType) -> Bool {
    switch t {
    case .offtaskStart, .breakStart, .idleStart, .sleep: true
    case .offtaskEnd, .breakEnd, .idleEnd, .wake: false
    }
}

/// Splits `[start, end]` into buckets. Overlap priority: break > sleep > idle > off-task > focused
/// (sleep during a break counts as break).
///
/// Whole-second rule: `start`, `end` and every event time are floored to the whole second first, so all buckets
/// are whole seconds and sum exactly to the session length. The SQL view must use the same rule
/// (`date_trunc('second', …)`). Returns all zeros when `end <= start` after flooring.
public func sessionTotals(start: Date, end: Date, events: [SessionEvent]) -> SessionTotals {
    let start = whole(start), end = whole(end)
    guard end > start else { return SessionTotals() }
    var totals = SessionTotals()
    var isOff = false, isBreak = false, isIdle = false, isAsleep = false
    var cursor = start

    func advance(to time: Date) {
        let d = Int(time.timeIntervalSince(cursor))
        if isBreak { totals.breakSec += d } else if isAsleep { totals.sleepSec += d } else if isIdle { totals.idleSec += d }
        else if isOff { totals.offtaskSec += d } else { totals.focusedSec += d }
        cursor = time
    }

    let sorted = events
        .map { SessionEvent($0.type, at: whole($0.at)) }
        .filter { $0.at >= start && $0.at <= end }
        .sorted { $0.at != $1.at ? $0.at < $1.at : (isStart($0.type) && !isStart($1.type)) }
    for e in sorted {
        advance(to: e.at)
        switch e.type {
        case .offtaskStart: isOff = true
        case .offtaskEnd: isOff = false
        case .breakStart: isBreak = true
        case .breakEnd: isBreak = false
        case .idleStart: isIdle = true
        case .idleEnd: isIdle = false
        case .sleep: isAsleep = true
        case .wake: isAsleep = false
        }
    }
    advance(to: end)
    return totals
}

public extension SessionTotals {
    static func + (l: SessionTotals, r: SessionTotals) -> SessionTotals {
        SessionTotals(focusedSec: l.focusedSec + r.focusedSec, offtaskSec: l.offtaskSec + r.offtaskSec,
                      breakSec: l.breakSec + r.breakSec, idleSec: l.idleSec + r.idleSec, sleepSec: l.sleepSec + r.sleepSec)
    }
}
