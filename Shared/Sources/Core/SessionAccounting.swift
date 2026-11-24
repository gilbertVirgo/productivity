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

    public init(_ type: SessionEventType, at: Date) {
        self.type = type
        self.at = at
    }
}

public struct SessionTotals: Equatable, Sendable {
    public var focusedSec: Int
    public var offtaskSec: Int
    public var breakSec: Int
    public var idleSec: Int
    public var sleepSec: Int

    /// Time that uses up the planned length: everything except breaks and sleep.
    public var activeSec: Int { focusedSec + offtaskSec + idleSec }

    public init(focusedSec: Int = 0, offtaskSec: Int = 0, breakSec: Int = 0, idleSec: Int = 0, sleepSec: Int = 0) {
        self.focusedSec = focusedSec
        self.offtaskSec = offtaskSec
        self.breakSec = breakSec
        self.idleSec = idleSec
        self.sleepSec = sleepSec
    }
}

/// Splits `[start, end]` into buckets. Overlap priority: sleep > break > idle > off-task > focused.
public func sessionTotals(start: Date, end: Date, events: [SessionEvent]) -> SessionTotals {
    var focused = 0.0, offtask = 0.0, onBreak = 0.0, idle = 0.0, asleep = 0.0
    var isOff = false, isBreak = false, isIdle = false, isAsleep = false
    var cursor = start

    func advance(to time: Date) {
        let d = time.timeIntervalSince(cursor)
        if isAsleep { asleep += d } else if isBreak { onBreak += d } else if isIdle { idle += d }
        else if isOff { offtask += d } else { focused += d }
        cursor = time
    }

    for e in events.filter({ $0.at >= start && $0.at <= end }).sorted(by: { $0.at < $1.at }) {
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

    return SessionTotals(focusedSec: Int(focused), offtaskSec: Int(offtask), breakSec: Int(onBreak),
                         idleSec: Int(idle), sleepSec: Int(asleep))
}

public func isComplete(_ totals: SessionTotals, plannedMin: Int) -> Bool {
    totals.activeSec >= plannedMin * 60
}
