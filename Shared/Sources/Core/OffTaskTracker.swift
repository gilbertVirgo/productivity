import Foundation

/// Grace-period state machine for off-task detection (spec 6.4).
/// Pure: the caller supplies every observation and clock tick.
public struct OffTaskTracker: Sendable {
    public enum Output: Equatable, Sendable {
        case started(at: Date, bundleID: String, host: String?)
        case ended(at: Date)
    }

    struct Foreground: Sendable {
        var bundleID: String
        var host: String?
    }

    public private(set) var allowlist: Allowlist
    public private(set) var isOffTask = false
    let grace: TimeInterval
    var current: Foreground?
    var pending: (since: Date, culprit: Foreground)?
    var suspended = false

    public init(allowlist: Allowlist, grace: TimeInterval = 15) {
        self.allowlist = allowlist
        self.grace = grace
    }

    public mutating func observe(bundleID: String, host: String?, at now: Date) -> [Output] {
        current = Foreground(bundleID: bundleID, host: host)
        return evaluate(at: now)
    }

    public mutating func tick(at now: Date) -> [Output] {
        guard !suspended, !isOffTask, let p = pending, now.timeIntervalSince(p.since) >= grace else { return [] }
        pending = nil
        isOffTask = true
        return [.started(at: p.since.addingTimeInterval(grace), bundleID: p.culprit.bundleID, host: p.culprit.host)]
    }

    public mutating func allow(_ entry: AllowEntry, at now: Date) -> [Output] {
        allowlist.entries.insert(entry)
        return evaluate(at: now)
    }

    public mutating func setSuspended(_ value: Bool, at now: Date) -> [Output] {
        suspended = value
        guard value else { return evaluate(at: now) }
        pending = nil
        return endIfOffTask(at: now)
    }

    private mutating func evaluate(at now: Date) -> [Output] {
        guard !suspended, let c = current else { return [] }
        if allowlist.isOnTask(bundleID: c.bundleID, host: c.host) {
            pending = nil
            return endIfOffTask(at: now)
        }
        if !isOffTask && pending == nil { pending = (now, c) }
        return []
    }

    private mutating func endIfOffTask(at now: Date) -> [Output] {
        guard isOffTask else { return [] }
        isOffTask = false
        return [.ended(at: now)]
    }
}
