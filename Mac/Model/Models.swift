import Foundation
import SwiftData
import Core

@Model final class Project {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var shareAlias: String
    var colorHex: String
    var weeklyHoursGoal: Double?
    var dailyHoursGoal: Double?
    var dailyGoalDays: [Int]
    var tasksGoal: Int?
    var tasksGoalPeriod: String
    var shared: Bool
    var archivedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \AllowRule.project) var allowRules: [AllowRule] = []
    @Relationship(deleteRule: .cascade, inverse: \TaskItem.project) var tasks: [TaskItem] = []

    init(name: String, shareAlias: String = "", colorHex: String = "#4F8EF7", now: Date = .now) {
        id = UUID(); createdAt = now; updatedAt = now
        self.name = name; self.shareAlias = shareAlias; self.colorHex = colorHex
        dailyGoalDays = [1, 2, 3, 4, 5]
        tasksGoalPeriod = "week"
        shared = false
    }

    var allowEntries: [AllowEntry] {
        allowRules.compactMap { r in AllowKind(rawValue: r.kind).map { AllowEntry($0, r.value) } }
    }
}

@Model final class AllowRule {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var kind: String
    var value: String
    var label: String
    var project: Project?

    init(_ entry: AllowEntry, label: String = "", now: Date = .now) {
        id = UUID(); createdAt = now; updatedAt = now
        kind = entry.kind.rawValue; value = entry.value; self.label = label
    }
}

@Model final class TaskItem {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var estimateMin: Int?
    var estimateGuessed: Bool
    var doneAt: Date?
    var source: String
    var sort: Int
    var project: Project?

    init(title: String, estimateMin: Int? = nil, estimateGuessed: Bool = false, source: String = "manual", sort: Int = 0, now: Date = .now) {
        id = UUID(); createdAt = now; updatedAt = now
        self.title = title; self.estimateMin = estimateMin; self.estimateGuessed = estimateGuessed
        self.source = source; self.sort = sort
    }
}

@Model final class SessionRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var projectID: UUID
    var firstTaskID: UUID?
    var plannedMin: Int
    var startedAt: Date
    var endedAt: Date?
    var endKind: String?
    var earlyReason: String?
    var focusedSec: Int
    var offtaskSec: Int
    var breakSec: Int
    var idleSec: Int
    var sleepSec: Int
    var eventsData: Data
    var allowData: Data

    init(projectID: UUID, firstTaskID: UUID?, plannedMin: Int, startedAt: Date, allowData: Data) {
        id = UUID(); createdAt = startedAt; updatedAt = startedAt
        self.projectID = projectID; self.firstTaskID = firstTaskID
        self.plannedMin = plannedMin; self.startedAt = startedAt
        focusedSec = 0; offtaskSec = 0; breakSec = 0; idleSec = 0; sleepSec = 0
        eventsData = Data("[]".utf8); self.allowData = allowData
    }

    var summary: SessionSummary {
        SessionSummary(projectID: projectID, startedAt: startedAt, focusedSec: focusedSec, breakSec: breakSec)
    }
}

@Model final class PointEvent {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var at: Date
    var delta: Int
    var kind: String
    var refID: UUID?
    var note: String

    init(at: Date, delta: Int, kind: String, refID: UUID?, note: String) {
        id = UUID(); createdAt = at; updatedAt = at
        self.at = at; self.delta = delta; self.kind = kind; self.refID = refID; self.note = note
    }
}

@Model final class Treat {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var cost: Int
    var archivedAt: Date?

    init(name: String, cost: Int, now: Date = .now) {
        id = UUID(); createdAt = now; updatedAt = now
        self.name = name; self.cost = cost
    }
}
