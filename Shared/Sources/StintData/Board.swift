import Foundation
import SwiftData
import Core

public enum CardState: Equatable, Sendable { case pending, active, done }

public extension TaskItem {
    var state: CardState { doneAt != nil ? .done : activeAt != nil ? .active : .pending }
}

/// The task board (spec 2026-11-27 §3–4): one column of cards grouped by state.
public struct Board {
    public var active: [TaskItem]
    public var pending: [TaskItem]
    /// Completed since midnight, newest first.
    public var doneToday: [TaskItem]
    /// Latest-tapped card, only while it is Active and its project is the tracked one.
    public var current: TaskItem?

    public static func make(tasks: [TaskItem], trackedProjectID: UUID?, now: Date, calendar: PeriodCalendar) -> Board {
        let live = tasks.filter { $0.deletedAt == nil && $0.project != nil && $0.project?.archivedAt == nil }
        let current = currentCard(live, trackedProjectID: trackedProjectID)
        let byOrder: (TaskItem, TaskItem) -> Bool = { ($0.sort, $0.createdAt) < ($1.sort, $1.createdAt) }
        var active = live.filter { $0.state == .active }.sorted(by: byOrder)
        if let c = current, let i = active.firstIndex(where: { $0.id == c.id }) { active.insert(active.remove(at: i), at: 0) }
        let today = calendar.dayInterval(containing: now)
        let done = live.filter { t in t.doneAt.map { $0 >= today.start && $0 < today.end } ?? false }
            .sorted { $0.doneAt! > $1.doneAt! }
        return Board(active: active, pending: live.filter { $0.state == .pending }.sorted(by: byOrder), doneToday: done, current: current)
    }

    static func currentCard(_ tasks: [TaskItem], trackedProjectID: UUID?) -> TaskItem? {
        guard let tracked = trackedProjectID,
              let latest = tasks.filter({ $0.currentAt != nil }).max(by: { $0.currentAt! < $1.currentAt! }),
              latest.state == .active, latest.project?.id == tracked else { return nil }
        return latest
    }

    // MARK: mutations — each stamps updatedAt; the caller saves and syncs.

    /// Tap: the card becomes Active (reopened if completed) and the current card.
    public static func makeCurrent(_ t: TaskItem, now: Date) {
        t.doneAt = nil
        if t.activeAt == nil { t.activeAt = now }
        t.currentAt = now
        t.updatedAt = now
    }

    public static func complete(_ t: TaskItem, now: Date) { t.doneAt = now; t.updatedAt = now }

    public static func toPending(_ t: TaskItem, now: Date) { t.activeAt = nil; t.doneAt = nil; t.updatedAt = now }

    public static func delete(_ t: TaskItem, now: Date) { t.deletedAt = now; t.updatedAt = now }

    public static func retitle(_ t: TaskItem, _ title: String, now: Date) {
        let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != t.title else { return }
        t.title = s; t.updatedAt = now
    }

    public static func move(_ t: TaskItem, to p: Project, now: Date) {
        guard t.project?.id != p.id else { return }
        t.project = p; t.updatedAt = now
    }

    /// New card on top of Pending. nil for a blank title.
    @discardableResult
    public static func add(title: String, project: Project, in ctx: ModelContext, now: Date) -> TaskItem? {
        let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let all = (try? ctx.fetch(FetchDescriptor<TaskItem>())) ?? []
        let t = TaskItem(title: s, sort: (all.map(\.sort).min() ?? 1) - 1, now: now)
        ctx.insert(t)
        t.project = project
        return t
    }

    /// Reorders one group (as shown) like `Array.move(fromOffsets:toOffset:)`, rewriting `sort` for cards that moved.
    public static func reorder(_ group: [TaskItem], from: IndexSet, to: Int, now: Date) {
        var g = group.enumerated().filter { !from.contains($0.offset) }.map(\.element)
        g.insert(contentsOf: from.map { group[$0] }, at: to - from.filter { $0 < to }.count)
        let base = group.map(\.sort).min() ?? 0
        for (i, t) in g.enumerated() where t.sort != base + i { t.sort = base + i; t.updatedAt = now }
    }
}
