import Foundation

/// What the progress views need from one finished session.
public struct SessionSummary: Sendable, Equatable {
    public var projectID: UUID
    public var startedAt: Date
    public var focusedSec: Int
    public var breakSec: Int

    public init(projectID: UUID, startedAt: Date, focusedSec: Int, breakSec: Int) {
        self.projectID = projectID
        self.startedAt = startedAt
        self.focusedSec = focusedSec
        self.breakSec = breakSec
    }
}

/// A session counts toward the period it started in (spec 6.1).
func startedIn(_ s: SessionSummary, _ interval: DateInterval) -> Bool {
    s.startedAt >= interval.start && s.startedAt < interval.end
}

public func focusedSec(_ sessions: [SessionSummary], projectID: UUID, in interval: DateInterval) -> Int {
    sessions.filter { $0.projectID == projectID && startedIn($0, interval) }.reduce(0) { $0 + $1.focusedSec }
}

public func breakSec(_ sessions: [SessionSummary], in interval: DateInterval) -> Int {
    sessions.filter { startedIn($0, interval) }.reduce(0) { $0 + $1.breakSec }
}
