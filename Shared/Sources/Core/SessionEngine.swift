import Foundation

public struct FrontApp: Equatable, Sendable {
    public var bundleID: String
    public var host: String?
    public init(bundleID: String, host: String?) { self.bundleID = bundleID; self.host = host }
}

public struct SessionResult: Sendable {
    public var totals: SessionTotals
    public var completed: Bool
    public var points: [PointLine]
    public var events: [SessionEvent]
    public var allowAdded: [AllowEntry]

    public init(totals: SessionTotals, completed: Bool, points: [PointLine], events: [SessionEvent], allowAdded: [AllowEntry]) {
        self.totals = totals; self.completed = completed; self.points = points; self.events = events; self.allowAdded = allowAdded
    }
}

/// Rules for one running session (spec 6.3–6.7). Pure: the caller feeds observations and clock ticks.
public struct SessionEngine: Sendable {
    public enum Signal: Equatable, Sendable {
        case offTaskStarted(bundleID: String, host: String?)
        case offTaskEnded
        case reachedPlannedLength
    }

    public let plannedMin: Int
    public let startedAt: Date
    public private(set) var events: [SessionEvent] = []
    public private(set) var onBreak = false
    public private(set) var idle = false
    public private(set) var asleep = false
    public private(set) var front: FrontApp?
    public private(set) var lastOnTaskBundleID: String?
    public private(set) var allowAdded: [AllowEntry] = []
    var tracker: OffTaskTracker
    var completionSignalled = false

    public init(plannedMin: Int, startedAt: Date, allowlist: Allowlist) {
        self.plannedMin = plannedMin
        self.startedAt = startedAt
        self.tracker = OffTaskTracker(allowlist: allowlist)
    }

    public var isOffTask: Bool { tracker.isOffTask }
    public var allowlist: Allowlist { tracker.allowlist }

    public mutating func observe(bundleID: String, host: String?, at now: Date) -> [Signal] {
        front = FrontApp(bundleID: bundleID, host: host)
        if tracker.allowlist.isOnTask(bundleID: bundleID, host: host) { lastOnTaskBundleID = bundleID }
        return record(tracker.observe(bundleID: bundleID, host: host, at: now))
    }

    public mutating func tick(at now: Date) -> [Signal] {
        var signals = record(tracker.tick(at: now))
        if !completionSignalled && isComplete(totals(at: now), plannedMin: plannedMin) {
            completionSignalled = true
            signals.append(.reachedPlannedLength)
        }
        return signals
    }

    public mutating func setBreak(_ value: Bool, at now: Date) -> [Signal] {
        guard value != onBreak else { return [] }
        onBreak = value
        let signals = resuspend(at: now)
        events.append(SessionEvent(value ? .breakStart : .breakEnd, at: now))
        return signals
    }

    public mutating func setIdle(_ value: Bool, at now: Date) -> [Signal] {
        guard value != idle else { return [] }
        idle = value
        let signals = resuspend(at: now)
        events.append(SessionEvent(value ? .idleStart : .idleEnd, at: now))
        return signals
    }

    public mutating func setAsleep(_ value: Bool, at now: Date) -> [Signal] {
        guard value != asleep else { return [] }
        asleep = value
        let signals = resuspend(at: now)
        events.append(SessionEvent(value ? .sleep : .wake, at: now))
        return signals
    }

    /// "It's work: allow for this session" — allows whatever is in front now (spec 6.4).
    public mutating func allowCurrent(at now: Date) -> (entry: AllowEntry, signals: [Signal])? {
        guard let f = front else { return nil }
        let entry: AllowEntry
        if Browsers.supported.contains(f.bundleID.lowercased()), let host = f.host {
            entry = AllowEntry(.domain, host)
        } else {
            entry = AllowEntry(.app, f.bundleID)
        }
        allowAdded.append(entry)
        return (entry, record(tracker.allow(entry, at: now)))
    }

    public mutating func setExtraAllowed(_ ids: Set<String>, at now: Date) -> [Signal] {
        record(tracker.setExtraAllowed(ids, at: now))
    }

    public func totals(at now: Date) -> SessionTotals {
        sessionTotals(start: startedAt, end: now, events: events)
    }

    public func remainingSec(at now: Date) -> Int {
        max(0, plannedMin * 60 - totals(at: now).activeSec)
    }

    public mutating func finish(at now: Date, early: Bool, breakUsedEarlierTodaySec: Int, allowanceSec: Int) -> SessionResult {
        if tracker.isOffTask { events.append(SessionEvent(.offtaskEnd, at: now)) }
        if onBreak { events.append(SessionEvent(.breakEnd, at: now)) }
        if idle { events.append(SessionEvent(.idleEnd, at: now)) }
        if asleep { events.append(SessionEvent(.wake, at: now)) }
        let t = totals(at: now)
        let completed = !early && isComplete(t, plannedMin: plannedMin)
        let over = breakOverAllowance(usedEarlierSec: breakUsedEarlierTodaySec, sessionBreakSec: t.breakSec, allowanceSec: allowanceSec)
        return SessionResult(totals: t, completed: completed,
                             points: sessionPoints(totals: t, completed: completed, breakOverSec: over),
                             events: events, allowAdded: allowAdded)
    }

    private mutating func resuspend(at now: Date) -> [Signal] {
        record(tracker.setSuspended(onBreak || idle || asleep, at: now))
    }

    private mutating func record(_ outputs: [OffTaskTracker.Output]) -> [Signal] {
        var signals: [Signal] = []
        for o in outputs {
            switch o {
            case let .started(at, bundleID, host):
                events.append(SessionEvent(.offtaskStart, at: at))
                signals.append(.offTaskStarted(bundleID: bundleID, host: host))
            case let .ended(at):
                events.append(SessionEvent(.offtaskEnd, at: at))
                signals.append(.offTaskEnded)
            }
        }
        return signals
    }
}
