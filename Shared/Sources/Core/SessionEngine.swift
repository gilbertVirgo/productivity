import Foundation

public struct FrontApp: Equatable, Sendable {
    public var bundleID: String
    public var host: String?
    public init(bundleID: String, host: String?) { self.bundleID = bundleID; self.host = host }
}

/// Rules for one running session (spec 6.3–6.7). Pure: the caller feeds observations and clock ticks.
public struct SessionEngine: Sendable {
    public enum Signal: Equatable, Sendable {
        case offTaskStarted(bundleID: String, host: String?)
        case offTaskEnded
    }

    public let startedAt: Date
    public private(set) var events: [SessionEvent] = []
    public private(set) var onBreak = false
    public private(set) var idle = false
    public private(set) var asleep = false
    public private(set) var front: FrontApp?
    public private(set) var lastOnTaskBundleID: String?
    public private(set) var allowAdded: [AllowEntry] = []
    var tracker: OffTaskTracker

    public init(startedAt: Date, allowlist: Allowlist) {
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
        record(tracker.tick(at: now))
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
        // `now` may be backdated (idle is detected after the threshold); never before the last recorded event.
        let now = max(now, startedAt, events.last?.at ?? startedAt)
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
        if !allowAdded.contains(entry) { allowAdded.append(entry) }
        return (entry, record(tracker.allow(entry, at: now)))
    }

    public mutating func setExtraAllowed(_ ids: Set<String>, at now: Date) -> [Signal] {
        record(tracker.setExtraAllowed(ids, at: now))
    }

    public func totals(at now: Date) -> SessionTotals {
        sessionTotals(start: startedAt, end: now, events: events)
    }

    /// Ends the stretch at `now`: drops events after `now` (a backdated switch), closes open states,
    /// and returns what the ledger stores.
    public mutating func close(at now: Date) -> (events: [SessionEvent], totals: SessionTotals) {
        events.removeAll { $0.at > now }
        // Close what is open in the events we kept, not in the live flags (which may postdate `now`).
        for (start, end) in [(SessionEventType.offtaskStart, SessionEventType.offtaskEnd), (.breakStart, .breakEnd),
                             (.idleStart, .idleEnd), (.sleep, .wake)] {
            let s = events.lastIndex { $0.type == start }
            let e = events.lastIndex { $0.type == end }
            if let s, e.map({ $0 < s }) ?? true { events.append(SessionEvent(end, at: now)) }
        }
        return (events, totals(at: now))
    }

    private mutating func resuspend(at now: Date) -> [Signal] {
        record(tracker.setSuspended(onBreak || idle || asleep, at: now))
    }

    private mutating func record(_ outputs: [OffTaskTracker.Output]) -> [Signal] {
        var signals: [Signal] = []
        for o in outputs {
            switch o {
            case let .started(at, bundleID, host):
                var detail = ["bundle_id": bundleID]
                if let host { detail["domain"] = host }
                events.append(SessionEvent(.offtaskStart, at: at, detail: detail))
                signals.append(.offTaskStarted(bundleID: bundleID, host: host))
            case let .ended(at):
                events.append(SessionEvent(.offtaskEnd, at: at))
                signals.append(.offTaskEnded)
            }
        }
        return signals
    }
}
