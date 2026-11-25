import Foundation
import SwiftData
import Core

public protocol Syncable { var updatedAt: Date { get }; var syncedAt: Date? { get set } }
public extension Syncable {
    var isDirty: Bool { syncedAt.map { updatedAt > $0 } ?? true }
}

@Model public final class Project: Syncable {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var syncedAt: Date? = nil
    public var name: String
    public var shareAlias: String
    public var colorHex: String
    public var weeklyHoursGoal: Double?
    public var dailyHoursGoal: Double?
    public var dailyGoalDays: [Int]
    public var tasksGoal: Int?
    public var tasksGoalPeriod: String
    public var shared: Bool
    public var archivedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \AllowRule.project) public var allowRules: [AllowRule] = []
    @Relationship(deleteRule: .cascade, inverse: \TaskItem.project) public var tasks: [TaskItem] = []

    public init(name: String, shareAlias: String = "", colorHex: String = "#4F8EF7", now: Date = .now) {
        id = UUID(); createdAt = now; updatedAt = now
        self.name = name; self.shareAlias = shareAlias; self.colorHex = colorHex
        dailyGoalDays = [1, 2, 3, 4, 5]
        tasksGoalPeriod = "week"
        shared = false
    }

    public var allowEntries: [AllowEntry] {
        allowRules.compactMap { r in AllowKind(rawValue: r.kind).map { AllowEntry($0, r.value) } }
    }
}

@Model public final class AllowRule: Syncable {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var syncedAt: Date? = nil
    public var kind: String
    public var value: String
    public var label: String
    public var project: Project?

    public init(_ entry: AllowEntry, label: String = "", now: Date = .now) {
        id = UUID(); createdAt = now; updatedAt = now
        kind = entry.kind.rawValue; value = entry.value; self.label = label
    }
}

@Model public final class TaskItem: Syncable {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var syncedAt: Date? = nil
    public var title: String
    public var estimateMin: Int?
    public var estimateGuessed: Bool
    public var doneAt: Date?
    public var source: String
    public var sort: Int
    public var project: Project?

    public init(title: String, estimateMin: Int? = nil, estimateGuessed: Bool = false, source: String = "manual", sort: Int = 0, now: Date = .now) {
        id = UUID(); createdAt = now; updatedAt = now
        self.title = title; self.estimateMin = estimateMin; self.estimateGuessed = estimateGuessed
        self.source = source; self.sort = sort
    }
}

@Model public final class SessionRecord: Syncable {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var syncedAt: Date? = nil
    public var projectID: UUID
    public var firstTaskID: UUID?
    public var plannedMin: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var endKind: String?
    public var earlyReason: String?
    public var focusedSec: Int
    public var offtaskSec: Int
    public var breakSec: Int
    public var idleSec: Int
    public var sleepSec: Int
    public var eventsData: Data
    public var allowData: Data
    /// Entries added mid-session (JSON `[AllowEntry]`), index-paired with `allowReasons`. `allowData` is the start snapshot.
    public var allowAddedData: Data = Data("[]".utf8)
    public var allowReasons: [String] = []

    public init(projectID: UUID, firstTaskID: UUID?, plannedMin: Int, startedAt: Date, allowData: Data) {
        id = UUID(); createdAt = startedAt; updatedAt = startedAt
        self.projectID = projectID; self.firstTaskID = firstTaskID
        self.plannedMin = plannedMin; self.startedAt = startedAt
        focusedSec = 0; offtaskSec = 0; breakSec = 0; idleSec = 0; sleepSec = 0
        eventsData = Data("[]".utf8); self.allowData = allowData
    }

    public var summary: SessionSummary {
        SessionSummary(projectID: projectID, startedAt: startedAt, focusedSec: focusedSec, breakSec: breakSec)
    }
}

@Model public final class PointEvent: Syncable {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var syncedAt: Date? = nil
    public var at: Date
    public var delta: Int
    public var kind: String
    public var refID: UUID?
    public var note: String

    public init(at: Date, delta: Int, kind: String, refID: UUID?, note: String) {
        id = UUID(); createdAt = at; updatedAt = at
        self.at = at; self.delta = delta; self.kind = kind; self.refID = refID; self.note = note
    }
}

@Model public final class Treat: Syncable {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var syncedAt: Date? = nil
    public var name: String
    public var cost: Int
    public var archivedAt: Date?

    public init(name: String, cost: Int, now: Date = .now) {
        id = UUID(); createdAt = now; updatedAt = now
        self.name = name; self.cost = cost
    }
}

@Model public final class Tombstone {
    @Attribute(.unique) public var id: UUID
    public var table: String
    public var rowID: UUID
    public var at: Date

    public init(table: String, rowID: UUID, at: Date = .now) {
        id = UUID(); self.table = table; self.rowID = rowID; self.at = at
    }
}

@Model public final class GoalResultRecord {
    @Attribute(.unique) public var id: UUID
    public var projectID: UUID
    public var period: String
    public var periodStart: Date
    public var goalKind: String
    public var target: Double
    public var actual: Double
    public var met: Bool
    public var createdAt: Date

    public init(projectID: UUID, period: String, periodStart: Date, goalKind: String, target: Double, actual: Double, met: Bool, createdAt: Date = .now) {
        id = UUID(); self.projectID = projectID; self.period = period; self.periodStart = periodStart
        self.goalKind = goalKind; self.target = target; self.actual = actual; self.met = met; self.createdAt = createdAt
    }
}

public enum StintSchema {
    public static let models: [any PersistentModel.Type] = [
        Project.self, AllowRule.self, TaskItem.self, SessionRecord.self, PointEvent.self, Treat.self,
        Tombstone.self, GoalResultRecord.self,
    ]
}
