import Foundation
import SwiftData
import Core

/// Model <-> wire row conversion and last-write-wins merge. `apply` returns true only when the remote row is newer.
@MainActor
public enum Mapping {
    // MARK: local -> row
    public static func row(_ p: Project, userID: UUID) -> ProjectRow {
        ProjectRow(id: p.id, userID: userID, updatedAt: p.updatedAt, name: p.name, shareAlias: p.shareAlias, color: p.colorHex,
                   weeklyHoursGoal: p.weeklyHoursGoal, dailyHoursGoal: p.dailyHoursGoal, dailyGoalDays: p.dailyGoalDays,
                   tasksGoal: p.tasksGoal, tasksGoalPeriod: p.tasksGoalPeriod, shared: p.shared, archivedAt: p.archivedAt)
    }

    /// nil when the rule has no project (orphan).
    public static func row(_ r: AllowRule, userID: UUID) -> ProjectAllowRow? {
        guard let pid = r.project?.id else { return nil }
        return ProjectAllowRow(id: r.id, userID: userID, updatedAt: r.updatedAt, projectID: pid, kind: r.kind, value: r.value, label: r.label)
    }

    /// nil when the task has no project (orphan); the schema requires project_id.
    public static func row(_ t: TaskItem, userID: UUID) -> TaskRow? {
        guard let pid = t.project?.id else { return nil }
        return TaskRow(id: t.id, userID: userID, updatedAt: t.updatedAt, projectID: pid, title: t.title, estimateMin: t.estimateMin,
                       estimateGuessed: t.estimateGuessed, doneAt: t.doneAt, source: t.source, sort: t.sort)
    }

    public static func row(_ t: Treat, userID: UUID) -> TreatRow {
        TreatRow(id: t.id, userID: userID, updatedAt: t.updatedAt, name: t.name, cost: t.cost, archivedAt: t.archivedAt)
    }

    public static func row(_ s: SessionRecord, userID: UUID, device: String = "mac") -> SessionRow {
        SessionRow(id: s.id, userID: userID, createdAt: s.createdAt, updatedAt: s.updatedAt, projectID: s.projectID,
                   firstTaskID: s.firstTaskID, plannedMin: s.plannedMin, startedAt: s.startedAt, endedAt: s.endedAt,
                   endKind: s.endKind, earlyReason: s.earlyReason, device: device)
    }

    public static func row(_ e: PointEvent, userID: UUID) -> PointEventRow {
        PointEventRow(id: e.id, userID: userID, at: e.at, delta: e.delta, kind: e.kind, refID: e.refID, note: e.note)
    }

    public static func sessionChildren(_ s: SessionRecord, userID: UUID) -> (allow: [SessionAllowRow], events: [SessionEventRow]) {
        let snapshot = (try? JSONDecoder().decode([AllowEntry].self, from: s.allowData)) ?? []
        let added = (try? JSONDecoder().decode([AllowEntry].self, from: s.allowAddedData)) ?? []
        let events = (try? JSONDecoder().decode([SessionEvent].self, from: s.eventsData)) ?? []
        var allow: [SessionAllowRow] = []
        for (i, a) in (snapshot.map { ($0, false) } + added.map { ($0, true) }).enumerated() {
            let addedIdx = i - snapshot.count
            allow.append(SessionAllowRow(id: SyncIDs.derived(s.id, "allow", i), userID: userID, sessionID: s.id,
                                         kind: a.0.kind.rawValue, value: a.0.value, label: "", addedMidSession: a.1,
                                         reason: a.1 && s.allowReasons.indices.contains(addedIdx) ? s.allowReasons[addedIdx] : nil))
        }
        let ev = events.enumerated().map { i, e in
            SessionEventRow(id: SyncIDs.derived(s.id, "event", i), userID: userID, sessionID: s.id, at: e.at,
                            type: e.type.rawValue, detail: e.detail ?? [:])
        }
        return (allow, ev)
    }

    // MARK: row -> existing local (last-write-wins)
    public static func apply(_ r: ProjectRow, to p: Project) -> Bool {
        guard r.updatedAt > p.updatedAt else { return false }
        p.name = r.name; p.shareAlias = r.shareAlias; p.colorHex = r.color
        p.weeklyHoursGoal = r.weeklyHoursGoal; p.dailyHoursGoal = r.dailyHoursGoal; p.dailyGoalDays = r.dailyGoalDays
        p.tasksGoal = r.tasksGoal; p.tasksGoalPeriod = r.tasksGoalPeriod; p.shared = r.shared; p.archivedAt = r.archivedAt
        p.updatedAt = r.updatedAt; p.syncedAt = r.updatedAt
        return true
    }

    public static func apply(_ r: ProjectAllowRow, to a: AllowRule) -> Bool {
        guard r.updatedAt > a.updatedAt else { return false }
        a.kind = r.kind; a.value = r.value; a.label = r.label
        a.updatedAt = r.updatedAt; a.syncedAt = r.updatedAt
        return true
    }

    public static func apply(_ r: TaskRow, to t: TaskItem) -> Bool {
        guard r.updatedAt > t.updatedAt else { return false }
        t.title = r.title; t.estimateMin = r.estimateMin; t.estimateGuessed = r.estimateGuessed
        t.doneAt = r.doneAt; t.source = r.source; t.sort = r.sort
        t.updatedAt = r.updatedAt; t.syncedAt = r.updatedAt
        return true
    }

    public static func apply(_ r: TreatRow, to t: Treat) -> Bool {
        guard r.updatedAt > t.updatedAt else { return false }
        t.name = r.name; t.cost = r.cost; t.archivedAt = r.archivedAt
        t.updatedAt = r.updatedAt; t.syncedAt = r.updatedAt
        return true
    }

    /// Never overwrites a running local session: the Mac owns it. Totals and events stay local.
    public static func apply(_ r: SessionRow, to s: SessionRecord) -> Bool {
        guard s.endedAt != nil, r.updatedAt > s.updatedAt else { return false }
        s.firstTaskID = r.firstTaskID; s.plannedMin = r.plannedMin; s.startedAt = r.startedAt
        s.endedAt = r.endedAt; s.endKind = r.endKind; s.earlyReason = r.earlyReason
        s.updatedAt = r.updatedAt; s.syncedAt = r.updatedAt
        return true
    }

    // MARK: row -> new local
    private static func project(_ id: UUID, _ ctx: ModelContext) -> Project? {
        (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })))?.first
    }

    public static func insert(_ r: ProjectRow, in ctx: ModelContext) -> Project {
        let p = Project(name: r.name, now: r.updatedAt)
        p.id = r.id
        _ = apply(r, to: p) // updatedAt equal -> guard fails, so set fields directly
        p.shareAlias = r.shareAlias; p.colorHex = r.color
        p.weeklyHoursGoal = r.weeklyHoursGoal; p.dailyHoursGoal = r.dailyHoursGoal; p.dailyGoalDays = r.dailyGoalDays
        p.tasksGoal = r.tasksGoal; p.tasksGoalPeriod = r.tasksGoalPeriod; p.shared = r.shared; p.archivedAt = r.archivedAt
        p.syncedAt = r.updatedAt
        ctx.insert(p)
        return p
    }

    /// nil when the parent project is not local yet.
    public static func insert(_ r: ProjectAllowRow, in ctx: ModelContext) -> AllowRule? {
        guard let p = project(r.projectID, ctx) else { return nil }
        let a = AllowRule(AllowEntry(.app, "x"), label: r.label, now: r.updatedAt)
        a.id = r.id; a.kind = r.kind; a.value = r.value; a.syncedAt = r.updatedAt
        ctx.insert(a)
        a.project = p
        return a
    }

    public static func insert(_ r: TaskRow, in ctx: ModelContext) -> TaskItem? {
        guard let p = project(r.projectID, ctx) else { return nil }
        let t = TaskItem(title: r.title, estimateMin: r.estimateMin, estimateGuessed: r.estimateGuessed, source: r.source, sort: r.sort, now: r.updatedAt)
        t.id = r.id; t.doneAt = r.doneAt; t.syncedAt = r.updatedAt
        ctx.insert(t)
        t.project = p
        return t
    }

    public static func insert(_ r: TreatRow, in ctx: ModelContext) -> Treat {
        let t = Treat(name: r.name, cost: r.cost, now: r.updatedAt)
        t.id = r.id; t.archivedAt = r.archivedAt; t.syncedAt = r.updatedAt
        ctx.insert(t)
        return t
    }

    public static func insert(_ r: PointEventRow, in ctx: ModelContext) -> PointEvent {
        let e = PointEvent(at: r.at, delta: r.delta, kind: r.kind, refID: r.refID, note: r.note)
        e.id = r.id; e.syncedAt = r.at
        ctx.insert(e)
        return e
    }

    /// `period_start` is parsed as UTC midnight.
    public static func insert(_ r: GoalResultRow, in ctx: ModelContext) -> GoalResultRecord {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")!
        let g = GoalResultRecord(projectID: r.projectID, period: r.period, periodStart: f.date(from: r.periodStart) ?? r.createdAt,
                                 goalKind: r.goalKind, target: r.target, actual: r.actual, met: r.met, createdAt: r.createdAt)
        g.id = r.id
        ctx.insert(g)
        return g
    }
}
