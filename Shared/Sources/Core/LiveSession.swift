import Foundation

/// What the Live Activity shows (spec 2026-11-26 §7.3). Same JSON on the Mac (push body), in APNs (`content-state`)
/// and in ActivityKit (`ContentState`). `countFrom` is Unix seconds, not a Date, so no date format can disagree.
public struct LiveSessionState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case focused, offTask = "off_task", onBreak = "on_break", paused, ended }
    public var status: Status
    public var projectName: String
    public var colorHex: String
    public var icon: String?
    /// The clock counts up from here (now − focused time this stretch). nil while it isn't counting.
    public var countFrom: Double?
    /// Focused seconds this stretch; shown as a still number when `countFrom` is nil.
    public var focusedSec: Int

    public init(status: Status, projectName: String, colorHex: String, icon: String?, countFrom: Double?, focusedSec: Int) {
        self.status = status; self.projectName = projectName; self.colorHex = colorHex; self.icon = icon
        self.countFrom = countFrom; self.focusedSec = focusedSec
    }

    /// `paused` = idle or asleep.
    public static func make(projectName: String, colorHex: String, icon: String?, focusedSec: Int,
                            onBreak: Bool, offTask: Bool, paused: Bool, now: Date) -> LiveSessionState {
        let status: Status = onBreak ? .onBreak : paused ? .paused : offTask ? .offTask : .focused
        return LiveSessionState(status: status, projectName: projectName, colorHex: colorHex, icon: icon,
                                countFrom: status == .focused ? (now.timeIntervalSince1970 - Double(focusedSec)).rounded() : nil,
                                focusedSec: focusedSec)
    }

    public static func ended(projectName: String, colorHex: String, icon: String?, focusedSec: Int) -> LiveSessionState {
        LiveSessionState(status: .ended, projectName: projectName, colorHex: colorHex, icon: icon, countFrom: nil, focusedSec: focusedSec)
    }

    public var countFromDate: Date? { countFrom.map { Date(timeIntervalSince1970: $0) } }

    /// Worth a push: anything visible changed, or the clock's start moved by more than 30 s.
    public func differs(from o: LiveSessionState) -> Bool {
        if status != o.status || projectName != o.projectName || colorHex != o.colorHex || icon != o.icon { return true }
        switch (countFrom, o.countFrom) {
        case let (a?, b?): return abs(a - b) > 30
        case (nil, nil): return false
        default: return true
        }
    }
}

/// Live Activity attributes on the wire. Property names must match `StintActivityAttributes` on iOS.
/// One activity per tracking run; the project lives in the content state because it changes on every switch.
public struct LiveSessionInfo: Codable, Hashable, Sendable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
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
