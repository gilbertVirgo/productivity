import Foundation
import Core

/// The Mac's open session as the phone sees it: the server row plus its events, as of the Mac's last checkpoint.
public struct RunningSession: Sendable, Equatable {
    public var id: UUID, projectID: UUID, firstTaskID: UUID?
    public var startedAt: Date
    /// The row's `updated_at`: the Mac's last checkpoint (every ~15 s while running).
    public var lastSeen: Date
    public var events: [SessionEvent]

    public init(id: UUID, projectID: UUID, firstTaskID: UUID?, startedAt: Date, lastSeen: Date, events: [SessionEvent]) {
        self.id = id; self.projectID = projectID; self.firstTaskID = firstTaskID
        self.startedAt = startedAt; self.lastSeen = lastSeen; self.events = events
    }

    public init(row: SessionRow, events: [SessionEventRow]) {
        self.init(id: row.id, projectID: row.projectID, firstTaskID: row.firstTaskID,
                  startedAt: row.startedAt, lastSeen: row.updatedAt,
                  events: events.compactMap { e in
                      SessionEventType(rawValue: e.type).map { SessionEvent($0, at: e.at, detail: e.detail.isEmpty ? nil : e.detail) }
                  })
    }

    public func totals(at now: Date) -> SessionTotals { sessionTotals(start: startedAt, end: now, events: events) }
    public func summary(at now: Date) -> SessionSummary {
        let t = totals(at: now)
        return SessionSummary(projectID: projectID, startedAt: startedAt, focusedSec: t.focusedSec, breakSec: t.breakSec)
    }

    private func isOpen(_ start: SessionEventType, _ end: SessionEventType) -> Bool {
        events.last { $0.type == start || $0.type == end }?.type == start
    }
    public var onBreak: Bool { isOpen(.breakStart, .breakEnd) }
    public var offTask: Bool { isOpen(.offtaskStart, .offtaskEnd) }
    /// Idle or asleep.
    public var paused: Bool { isOpen(.idleStart, .idleEnd) || isOpen(.sleep, .wake) }
    /// No checkpoint for 2 min: the Mac quit, slept or lost network.
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(lastSeen) > 120 }
}
