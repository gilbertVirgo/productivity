import Foundation
import Core
import Supabase

// Wire rows. CodingKeys match supabase/migrations/20261125000001_schema.sql.
// Nullable columns are always encoded (explicit null) so clearing a value reaches the server.
// `serverUpdatedAt` is decoded when present and never encoded. Memberwise inits are internal.

public struct ProjectRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, updatedAt: Date
    public var name: String, shareAlias: String, color: String
    public var weeklyHoursGoal: Double?, dailyHoursGoal: Double?
    public var dailyGoalDays: [Int]
    public var tasksGoal: Int?
    public var tasksGoalPeriod: String
    public var shared: Bool
    public var archivedAt: Date?
    public var serverUpdatedAt: Date? = nil
    public var createdAt: Date? = nil // receive-only
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", updatedAt = "updated_at", name, shareAlias = "share_alias", color
        case weeklyHoursGoal = "weekly_hours_goal", dailyHoursGoal = "daily_hours_goal", dailyGoalDays = "daily_goal_days"
        case tasksGoal = "tasks_goal", tasksGoalPeriod = "tasks_goal_period", shared, archivedAt = "archived_at"
        case serverUpdatedAt = "server_updated_at", createdAt = "created_at"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(name, forKey: .name); try c.encode(shareAlias, forKey: .shareAlias); try c.encode(color, forKey: .color)
        try c.encode(weeklyHoursGoal, forKey: .weeklyHoursGoal); try c.encode(dailyHoursGoal, forKey: .dailyHoursGoal)
        try c.encode(dailyGoalDays, forKey: .dailyGoalDays)
        try c.encode(tasksGoal, forKey: .tasksGoal); try c.encode(tasksGoalPeriod, forKey: .tasksGoalPeriod)
        try c.encode(shared, forKey: .shared); try c.encode(archivedAt, forKey: .archivedAt)
    }
}

public struct ProjectAllowRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, updatedAt: Date, projectID: UUID
    public var kind: String, value: String, label: String
    public var serverUpdatedAt: Date? = nil
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", updatedAt = "updated_at", projectID = "project_id", kind, value, label
        case serverUpdatedAt = "server_updated_at"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(projectID, forKey: .projectID); try c.encode(kind, forKey: .kind)
        try c.encode(value, forKey: .value); try c.encode(label, forKey: .label)
    }
}

public struct TaskRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, updatedAt: Date, projectID: UUID
    public var title: String
    public var estimateMin: Int?
    public var estimateGuessed: Bool
    public var doneAt: Date?
    public var source: String
    public var sort: Int
    public var serverUpdatedAt: Date? = nil
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", updatedAt = "updated_at", projectID = "project_id", title
        case estimateMin = "estimate_min", estimateGuessed = "estimate_guessed", doneAt = "done_at", source, sort
        case serverUpdatedAt = "server_updated_at"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(projectID, forKey: .projectID); try c.encode(title, forKey: .title)
        try c.encode(estimateMin, forKey: .estimateMin); try c.encode(estimateGuessed, forKey: .estimateGuessed)
        try c.encode(doneAt, forKey: .doneAt); try c.encode(source, forKey: .source); try c.encode(sort, forKey: .sort)
    }
}

public struct SessionRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, createdAt: Date, updatedAt: Date, projectID: UUID
    public var firstTaskID: UUID?
    public var plannedMin: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var endKind: String?, earlyReason: String?
    public var device: String
    public var serverUpdatedAt: Date? = nil
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", createdAt = "created_at", updatedAt = "updated_at", projectID = "project_id"
        case firstTaskID = "first_task_id", plannedMin = "planned_min", startedAt = "started_at", endedAt = "ended_at"
        case endKind = "end_kind", earlyReason = "early_reason", device, serverUpdatedAt = "server_updated_at"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(projectID, forKey: .projectID); try c.encode(firstTaskID, forKey: .firstTaskID)
        try c.encode(plannedMin, forKey: .plannedMin); try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt); try c.encode(endKind, forKey: .endKind)
        try c.encode(earlyReason, forKey: .earlyReason); try c.encode(device, forKey: .device)
    }
}

public struct SessionAllowRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, sessionID: UUID
    public var kind: String, value: String, label: String
    public var addedMidSession: Bool
    public var reason: String?
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", sessionID = "session_id", kind, value, label
        case addedMidSession = "added_mid_session", reason
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID); try c.encode(sessionID, forKey: .sessionID)
        try c.encode(kind, forKey: .kind); try c.encode(value, forKey: .value); try c.encode(label, forKey: .label)
        try c.encode(addedMidSession, forKey: .addedMidSession); try c.encode(reason, forKey: .reason)
    }
}

public struct SessionEventRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, sessionID: UUID
    public var at: Date
    public var type: String
    public var detail: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case id, userID = "user_id", sessionID = "session_id", at, type, detail }
}

public struct PointEventRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID
    public var at: Date
    public var delta: Int
    public var kind: String
    public var refID: UUID?
    public var note: String
    enum CodingKeys: String, CodingKey { case id, userID = "user_id", at, delta, kind, refID = "ref_id", note }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID); try c.encode(at, forKey: .at)
        try c.encode(delta, forKey: .delta); try c.encode(kind, forKey: .kind)
        try c.encode(refID, forKey: .refID); try c.encode(note, forKey: .note)
    }
}

public struct TreatRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, updatedAt: Date
    public var name: String
    public var cost: Int
    public var archivedAt: Date?
    public var serverUpdatedAt: Date? = nil
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", updatedAt = "updated_at", name, cost, archivedAt = "archived_at"
        case serverUpdatedAt = "server_updated_at"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(name, forKey: .name); try c.encode(cost, forKey: .cost); try c.encode(archivedAt, forKey: .archivedAt)
    }
}

/// Server-written (decode only).
public struct GoalResultRow: Decodable, Sendable, Equatable {
    public var id: UUID, userID: UUID, projectID: UUID
    public var period: String
    /// `yyyy-MM-dd`
    public var periodStart: String
    public var goalKind: String
    public var target: Double, actual: Double
    public var met: Bool
    public var createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", projectID = "project_id", period, periodStart = "period_start"
        case goalKind = "goal_kind", target, actual, met, createdAt = "created_at"
    }
}

public struct ProfileRow: Codable, Sendable, Equatable {
    public var userID: UUID, updatedAt: Date
    public var timezone: String
    public var breakAllowanceMin: Int
    public var displayName: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", updatedAt = "updated_at", timezone, breakAllowanceMin = "break_allowance_min", displayName = "display_name"
    }
}

public struct SessionCommandRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, createdAt: Date
    public var kind: String
    public var payload: [String: String]
    public var rejectedReason: String? = nil
    enum CodingKeys: String, CodingKey { case id, userID = "user_id", createdAt = "created_at", kind, payload, rejectedReason = "rejected_reason" }
}

extension SessionCommandRow {
    /// Lenient: a non-string payload value must not fail the whole `pendingCommands()` array and block the channel.
    /// Scalars are stringified; null/array/object values are dropped, so `parse` rejects the command instead.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); userID = try c.decode(UUID.self, forKey: .userID)
        createdAt = try c.decode(Date.self, forKey: .createdAt); kind = try c.decode(String.self, forKey: .kind)
        rejectedReason = try c.decodeIfPresent(String.self, forKey: .rejectedReason)
        let raw = (try? c.decode([String: AnyJSON].self, forKey: .payload)) ?? [:]
        payload = raw.compactMapValues {
            switch $0 {
            case .string(let s): s
            case .integer(let i): String(i)
            case .double(let d): String(d)
            case .bool(let b): String(b)
            default: nil
            }
        }
    }
}

/// Insert shape for a phone command. `created_at` is server-defaulted so the Mac ages commands by server time.
public struct NewSessionCommandRow: Encodable, Sendable {
    public var id: UUID, userID: UUID
    public var kind: String
    public var payload: [String: String]
    enum CodingKeys: String, CodingKey { case id, userID = "user_id", kind, payload }
}

/// `session_totals` view row (read by the phone).
public struct SessionTotalsRow: Decodable, Sendable, Equatable {
    public var sessionID: UUID, projectID: UUID
    public var startedAt: Date, endedAt: Date?
    public var focusedSec: Int, breakSec: Int
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", projectID = "project_id", startedAt = "started_at", endedAt = "ended_at"
        case focusedSec = "focused_sec", breakSec = "break_sec"
    }
    public init(sessionID: UUID, projectID: UUID, startedAt: Date, endedAt: Date?, focusedSec: Int, breakSec: Int) {
        self.sessionID = sessionID; self.projectID = projectID; self.startedAt = startedAt; self.endedAt = endedAt
        self.focusedSec = focusedSec; self.breakSec = breakSec
    }
    public var summary: SessionSummary {
        SessionSummary(projectID: projectID, startedAt: startedAt, focusedSec: focusedSec, breakSec: breakSec)
    }
}

/// The phone's push tokens (plan 7). Written by the phone only; read by `push-activity` through RLS.
public struct DeviceRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, updatedAt: Date
    public var platform: String
    public var pushToStartToken: String?, activityToken: String?, activitySessionID: UUID?
    public init(id: UUID, userID: UUID, updatedAt: Date, platform: String,
                pushToStartToken: String?, activityToken: String?, activitySessionID: UUID?) {
        self.id = id; self.userID = userID; self.updatedAt = updatedAt; self.platform = platform
        self.pushToStartToken = pushToStartToken; self.activityToken = activityToken; self.activitySessionID = activitySessionID
    }
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", updatedAt = "updated_at", platform
        case pushToStartToken = "push_to_start_token", activityToken = "activity_token", activitySessionID = "activity_session_id"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(platform, forKey: .platform)
        try c.encode(pushToStartToken, forKey: .pushToStartToken); try c.encode(activityToken, forKey: .activityToken)
        try c.encode(activitySessionID, forKey: .activitySessionID)
    }
}
