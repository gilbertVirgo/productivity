import Foundation

/// What the Live Activity shows (spec §6.9). Same JSON on the Mac (push body), in APNs (`content-state`)
/// and in ActivityKit (`ContentState`). `endsAt` is Unix seconds, not a Date, so no date-format can disagree.
public struct LiveSessionState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case focused, offTask = "off_task", onBreak = "on_break", ended }
    public var status: Status
    /// When the planned length runs out if nothing pauses it; nil while on a break (the countdown is paused).
    public var endsAt: Double?
    public var remainingSec: Int
    public var taskTitle: String?

    public init(status: Status, endsAt: Double?, remainingSec: Int, taskTitle: String?) {
        self.status = status; self.endsAt = endsAt; self.remainingSec = remainingSec; self.taskTitle = taskTitle
    }

    public static func make(remainingSec: Int, onBreak: Bool, offTask: Bool, taskTitle: String?, now: Date) -> LiveSessionState {
        LiveSessionState(status: onBreak ? .onBreak : offTask ? .offTask : .focused,
                         endsAt: onBreak ? nil : (now.timeIntervalSince1970 + Double(remainingSec)).rounded(),
                         remainingSec: remainingSec, taskTitle: taskTitle)
    }

    public static func ended(taskTitle: String?) -> LiveSessionState {
        LiveSessionState(status: .ended, endsAt: nil, remainingSec: 0, taskTitle: taskTitle)
    }

    public var endsDate: Date? { endsAt.map { Date(timeIntervalSince1970: $0) } }

    /// Worth a push: anything visible changed, or the end time moved by more than 30 s (a pause or sleep).
    public func differs(from o: LiveSessionState) -> Bool {
        if status != o.status || taskTitle != o.taskTitle { return true }
        switch (endsAt, o.endsAt) {
        case let (a?, b?): return abs(a - b) > 30
        case (nil, nil): return false
        default: return true
        }
    }
}

/// Live Activity attributes on the wire. Property names must match `StintActivityAttributes` on iOS.
public struct LiveSessionInfo: Codable, Hashable, Sendable {
    public var sessionID: String
    public var projectName: String
    public var plannedMin: Int
    public init(sessionID: String, projectName: String, plannedMin: Int) {
        self.sessionID = sessionID; self.projectName = projectName; self.plannedMin = plannedMin
    }
}

/// Body of `POST /functions/v1/push-activity`.
public struct LivePush: Encodable, Equatable, Sendable {
    public enum Event: String, Encodable, Sendable { case start, update, end }
    public var event: Event
    public var sessionID: UUID
    public var attributes: LiveSessionInfo?
    public var contentState: LiveSessionState
    public init(event: Event, sessionID: UUID, attributes: LiveSessionInfo?, contentState: LiveSessionState) {
        self.event = event; self.sessionID = sessionID; self.attributes = attributes; self.contentState = contentState
    }
    enum CodingKeys: String, CodingKey { case event, sessionID = "session_id", attributes, contentState = "content_state" }
}
