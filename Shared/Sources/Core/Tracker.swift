import Foundation

/// A project Stint can track: its id, its live allowlist and the off-Mac flag (spec 2026-11-26 §5.6).
public struct TrackedProject: Sendable {
    public var id: UUID
    public var allowlist: Allowlist
    public var offMac: Bool
    public init(id: UUID, allowlist: Allowlist, offMac: Bool = false) {
        self.id = id; self.allowlist = allowlist; self.offMac = offMac
    }
}

/// Raw values are `session.end_kind`.
public enum StretchEnd: String, Sendable { case switched, stopped }

public struct StretchResult: Equatable, Sendable {
    public var projectID: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var end: StretchEnd
    public var events: [SessionEvent]
    public var totals: SessionTotals
    public init(projectID: UUID, startedAt: Date, endedAt: Date, end: StretchEnd, events: [SessionEvent], totals: SessionTotals) {
        self.projectID = projectID; self.startedAt = startedAt; self.endedAt = endedAt
        self.end = end; self.events = events; self.totals = totals
    }
}

/// What is being tracked right now: one stretch on one project at a time (spec 2026-11-26 §5.1–5.3, 5.6).
/// Pure: the caller feeds switches, observations and clock ticks, and stores what comes out.
public struct Tracker: Sendable {
    public enum Output: Equatable, Sendable {
        case ended(StretchResult)
        case started(projectID: UUID, at: Date)
        case offTaskStarted(bundleID: String, host: String?)
        case offTaskEnded
    }

    public private(set) var project: TrackedProject?
    public private(set) var previousID: UUID?
    public private(set) var engine: SessionEngine?
    public private(set) var front: FrontApp?
    let calendar: PeriodCalendar
    // Mac-wide state, carried into the next stretch.
    var idle = false, asleep = false

    public init(calendar: PeriodCalendar) { self.calendar = calendar }

    public var currentID: UUID? { project?.id }
    public var isTracking: Bool { project != nil }
    public var onBreak: Bool { engine?.onBreak ?? false }
    public var isOffTask: Bool { engine?.isOffTask ?? false }

    /// Switches to `p` at `now`, or at the current stretch's start if `now` is earlier. Starts tracking when stopped.
    public mutating func switchTo(_ p: TrackedProject, at now: Date) -> [Output] {
        var out = splitAtMidnight(before: now)
        guard p.id != project?.id else { return out }
        var start = now
        if let old = project, var e = engine {
            start = max(now, e.startedAt)
            if e.isOffTask { out.append(.offTaskEnded) }
            out.append(.ended(Self.close(&e, old, at: start, .switched)))
            previousID = old.id
        }
        open(p, at: start)
        out.append(.started(projectID: p.id, at: start))
        return out
    }

    public mutating func stop(at now: Date) -> [Output] {
        splitAtMidnight(before: now) + stopNow(at: now)
    }

    private mutating func stopNow(at now: Date) -> [Output] {
        guard let p = project, var e = engine else { return [] }
        var out: [Output] = e.isOffTask ? [.offTaskEnded] : []
        out.append(.ended(Self.close(&e, p, at: max(now, e.startedAt), .stopped)))
        previousID = p.id
        project = nil; engine = nil; idle = false; asleep = false
        return out
    }

    public mutating func setBreak(_ on: Bool, at now: Date) -> [Output] {
        let split = splitAtMidnight(before: now)
        guard var e = engine else { return split }
        let out = Self.map(e.setBreak(on, at: now))
        engine = e
        return split + out
    }

    public mutating func observe(bundleID: String, host: String?, at now: Date) -> [Output] {
        let split = splitAtMidnight(before: now)
        front = FrontApp(bundleID: bundleID, host: host)
        guard var e = engine, project?.offMac == false else { return split }
        let out = Self.map(e.observe(bundleID: bundleID, host: host, at: now))
        engine = e
        return split + out
    }

    public mutating func setIdle(_ v: Bool, at now: Date) -> [Output] {
        let split = splitAtMidnight(before: now)
        idle = v
        guard var e = engine, project?.offMac == false else { return split }
        let out = Self.map(e.setIdle(v, at: now))
        engine = e
        return split + out
    }

    public mutating func setAsleep(_ v: Bool, at now: Date) -> [Output] {
        let split = splitAtMidnight(before: now)
        asleep = v
        guard var e = engine, project?.offMac == false else { return split }
        let out = Self.map(e.setAsleep(v, at: now))
        engine = e
        return split + out
    }

    /// Does not split at midnight; `tick` does.
    /// "It's work: allow": allows what's in front for the rest of this stretch. The caller makes it permanent.
    public mutating func allowCurrent(at now: Date) -> (AllowEntry, [Output])? {
        guard var e = engine, let (entry, signals) = e.allowCurrent(at: now) else { return nil }
        engine = e
        return (entry, Self.map(signals))
    }

    /// Clock tick: the midnight split (§5.2), then the engine's grace timers.
    public mutating func tick(at now: Date) -> [Output] {
        var out = splitAtMidnight(before: now)
        if var e = engine, project?.offMac == false {
            out += Self.map(e.tick(at: now))
            engine = e
        }
        return out
    }

    /// The midnight split (§5.2). Runs before every input so a night is never misplaced by a late tick.
    private mutating func splitAtMidnight(before now: Date) -> [Output] {
        var out: [Output] = []
        while let p = project, var e = engine {
            let midnight = calendar.dayInterval(containing: e.startedAt).end
            guard now >= midnight else { break }
            if p.offMac { out += stopNow(at: midnight); break }
            let wasOnBreak = e.onBreak
            if e.isOffTask { out.append(.offTaskEnded) }
            out.append(.ended(Self.close(&e, p, at: midnight, .switched)))
            open(p, at: midnight)
            if wasOnBreak { _ = engine?.setBreak(true, at: midnight) } // a break carries over midnight
            out.append(.started(projectID: p.id, at: midnight))
        }
        return out
    }

    private mutating func open(_ p: TrackedProject, at start: Date) {
        project = p
        var e = SessionEngine(startedAt: start, allowlist: p.allowlist)
        if !p.offMac {
            if idle { _ = e.setIdle(true, at: start) }
            if asleep { _ = e.setAsleep(true, at: start) }
            if let f = front { _ = e.observe(bundleID: f.bundleID, host: f.host, at: start) }
        }
        engine = e
    }

    private static func close(_ e: inout SessionEngine, _ p: TrackedProject, at end: Date, _ kind: StretchEnd) -> StretchResult {
        let (events, totals) = e.close(at: end)
        return StretchResult(projectID: p.id, startedAt: e.startedAt, endedAt: end, end: kind, events: events, totals: totals)
    }

    private static func map(_ signals: [SessionEngine.Signal]) -> [Output] {
        signals.compactMap {
            switch $0 {
            case let .offTaskStarted(bundleID, host): .offTaskStarted(bundleID: bundleID, host: host)
            case .offTaskEnded: .offTaskEnded
            case .reachedPlannedLength: nil // stretches have no planned length
            }
        }
    }
}
