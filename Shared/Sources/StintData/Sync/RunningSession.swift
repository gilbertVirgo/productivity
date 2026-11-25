import Foundation
import Core

/// The Mac's open session as the phone sees it: the server row plus its events, as of the Mac's last checkpoint.
public struct RunningSession: Sendable, Equatable {
    public var id: UUID, projectID: UUID, firstTaskID: UUID?
    public var plannedMin: Int
    public var startedAt: Date
    /// The row's `updated_at`: the Mac's last checkpoint (every ~15 s while running).
    public var lastSeen: Date
    public var events: [SessionEvent]

    public init(id: UUID, projectID: UUID, firstTaskID: UUID?, plannedMin: Int, startedAt: Date, lastSeen: Date, events: [SessionEvent]) {
        self.id = id; self.projectID = projectID; self.firstTaskID = firstTaskID
        self.plannedMin = plannedMin; self.startedAt = startedAt; self.lastSeen = lastSeen; self.events = events
    }

    public init(row: SessionRow, events: [SessionEventRow]) {
        self.init(id: row.id, projectID: row.projectID, firstTaskID: row.firstTaskID, plannedMin: row.plannedMin,
                  startedAt: row.startedAt, lastSeen: row.updatedAt,
                  events: events.compactMap { e in
                      SessionEventType(rawValue: e.type).map { SessionEvent($0, at: e.at, detail: e.detail.isEmpty ? nil : e.detail) }
                  })
    }

    public func totals(at now: Date) -> SessionTotals { sessionTotals(start: startedAt, end: now, events: events) }
    /// Same rule as `SessionEngine.remainingSec`: breaks and sleep don't use up the planned length.
    public func remainingSec(at now: Date) -> Int { max(0, plannedMin * 60 - totals(at: now).activeSec) }
    public func summary(at now: Date) -> SessionSummary {
        let t = totals(at: now)
        return SessionSummary(projectID: projectID, startedAt: startedAt, focusedSec: t.focusedSec, breakSec: t.breakSec)
    }

    private func isOpen(_ start: SessionEventType, _ end: SessionEventType) -> Bool {
        events.last { $0.type == start || $0.type == end }?.type == start
    }
    public var onBreak: Bool { isOpen(.breakStart, .breakEnd) }
    public var offTask: Bool { isOpen(.offtaskStart, .offtaskEnd) }
    /// No checkpoint for 2 min: the Mac quit, slept or lost network.
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(lastSeen) > 120 }
}
