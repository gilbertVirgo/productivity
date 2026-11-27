import Testing
import Foundation
import SwiftData
import Core
@testable import StintData

@MainActor @Suite struct BoardTests {
    let cal = PeriodCalendar(timeZone: TimeZone(identifier: "UTC")!)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000) // a UTC day, mid-morning

    func setup() throws -> (ModelContext, Project, Project) {
        let ctx = ModelContext(try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let a = Project(name: "A"), b = Project(name: "B")
        ctx.insert(a); ctx.insert(b)
        return (ctx, a, b)
    }

    func card(_ ctx: ModelContext, _ p: Project, _ title: String, sort: Int = 0) -> TaskItem {
        let t = TaskItem(title: title, sort: sort, now: t0)
        ctx.insert(t); t.project = p
        return t
    }

    @Test func statesGroupAndOrder() throws {
        let (ctx, a, _) = try setup()
        let p1 = card(ctx, a, "p1", sort: 2), p2 = card(ctx, a, "p2", sort: 1)
        let act = card(ctx, a, "act"); Board.makeCurrent(act, now: t0)
        let done = card(ctx, a, "done"); Board.complete(done, now: t0 + 10)
        let old = card(ctx, a, "old"); Board.complete(old, now: t0 - 86_400)
        let gone = card(ctx, a, "gone"); Board.delete(gone, now: t0)
        let b = Board.make(tasks: [p1, p2, act, done, old, gone], trackedProjectID: nil, now: t0 + 20, calendar: cal)
        #expect(b.pending.map(\.title) == ["p2", "p1"])
        #expect(b.active.map(\.title) == ["act"])
        #expect(b.doneToday.map(\.title) == ["done"])
        #expect(act.state == .active && p1.state == .pending && done.state == .done)
    }

    @Test func currentIsLatestTapOnTrackedProject() throws {
        let (ctx, a, bp) = try setup()
        let x = card(ctx, a, "x", sort: 0), y = card(ctx, a, "y", sort: 1), z = card(ctx, bp, "z")
        Board.makeCurrent(x, now: t0); Board.makeCurrent(y, now: t0 + 1)
        let all = [x, y, z]
        var b = Board.make(tasks: all, trackedProjectID: a.id, now: t0, calendar: cal)
        #expect(b.current?.title == "y")
        #expect(b.active.map(\.title) == ["y", "x"]) // current first
        // Tracking elsewhere or stopped: no current card.
        #expect(Board.make(tasks: all, trackedProjectID: bp.id, now: t0, calendar: cal).current == nil)
        #expect(Board.make(tasks: all, trackedProjectID: nil, now: t0, calendar: cal).current == nil)
        // Completing the current card leaves none current (not the older tap).
        Board.complete(y, now: t0 + 2)
        b = Board.make(tasks: all, trackedProjectID: a.id, now: t0 + 3, calendar: cal)
        #expect(b.current == nil)
        // Tapping a card on another project moves current there.
        Board.makeCurrent(z, now: t0 + 4)
        #expect(Board.make(tasks: all, trackedProjectID: bp.id, now: t0, calendar: cal).current?.title == "z")
        // Back to pending: none.
        Board.toPending(z, now: t0 + 5)
        #expect(Board.make(tasks: all, trackedProjectID: bp.id, now: t0, calendar: cal).current == nil)
        #expect(z.state == .pending && z.updatedAt == t0 + 5)
    }

    @Test func tapReopensCompleted() throws {
        let (ctx, a, _) = try setup()
        let t = card(ctx, a, "t")
        Board.complete(t, now: t0)
        Board.makeCurrent(t, now: t0 + 1)
        #expect(t.state == .active && t.doneAt == nil && t.currentAt == t0 + 1 && t.updatedAt == t0 + 1)
    }

    @Test func addGoesOnTopAndTrims() throws {
        let (ctx, a, _) = try setup()
        _ = card(ctx, a, "old", sort: 3)
        #expect(Board.add(title: "  ", project: a, in: ctx, now: t0) == nil)
        let n = try #require(Board.add(title: " new ", project: a, in: ctx, now: t0))
        #expect(n.title == "new" && n.sort == 2 && n.state == .pending && n.project?.id == a.id)
    }

    @Test func reorderRewritesSort() throws {
        let (ctx, a, _) = try setup()
        let g = [card(ctx, a, "a"), card(ctx, a, "b"), card(ctx, a, "c")] // all sort 0
        Board.reorder(g, from: [2], to: 0, now: t0 + 9)
        let b = Board.make(tasks: g, trackedProjectID: nil, now: t0, calendar: cal)
        #expect(b.pending.map(\.title) == ["c", "a", "b"])
        Board.reorder(b.pending, from: [0], to: 3, now: t0 + 10)
        #expect(Board.make(tasks: g, trackedProjectID: nil, now: t0, calendar: cal).pending.map(\.title) == ["a", "b", "c"])
    }

    @Test func retitleAndMove() throws {
        let (ctx, a, b) = try setup()
        let t = card(ctx, a, "t")
        Board.retitle(t, "  ", now: t0 + 1)
        #expect(t.title == "t" && t.updatedAt == t0)
        Board.retitle(t, "u", now: t0 + 2); Board.move(t, to: b, now: t0 + 3)
        #expect(t.title == "u" && t.project?.id == b.id && t.updatedAt == t0 + 3)
    }

    @Test func taskRowCarriesBoardFields() throws {
        let (ctx, a, b) = try setup()
        let t = card(ctx, a, "t")
        Board.makeCurrent(t, now: t0 + 1)
        let row = try #require(Mapping.row(t, userID: UUID()))
        let j = try JSONSerialization.jsonObject(with: SyncCoding.encoder.encode(row)) as! [String: Any]
        #expect(j["deleted_at"] is NSNull && j["active_at"] != nil && j["current_at"] != nil)
        // A pulled row moves the card and copies the board fields.
        var r = row
        r.projectID = b.id; r.updatedAt = t0 + 5; r.deletedAt = t0 + 5
        #expect(Mapping.apply(r, to: t))
        #expect(t.project?.id == b.id && t.deletedAt == t0 + 5)
    }
}
