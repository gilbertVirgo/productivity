import Testing
import Foundation
import SwiftData
import Core
@testable import StintData

@MainActor
@Suite struct LedgerTests {
    func makeCtx() throws -> ModelContext {
        let c = try ModelContainer(
            for: Schema(StintSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func project(_ ctx: ModelContext) -> Project {
        let p = Project(name: "Northwind")
        ctx.insert(p)
        return p
    }

    @Test func redeemGuardsBalance() throws {
        let ctx = try makeCtx()
        ctx.insert(PointEvent(at: .now, delta: 100, kind: "focus", refID: nil, note: ""))
        let big = Treat(name: "Big", cost: 150), small = Treat(name: "Small", cost: 100)
        ctx.insert(big); ctx.insert(small)
        #expect(throws: LedgerError.insufficientPoints) { try Ledger.redeem(ctx, treat: big, at: .now) }
        #expect(Ledger.balance(ctx) == 100)
        try Ledger.redeem(ctx, treat: small, at: .now)
        #expect(Ledger.balance(ctx) == 0)
    }

    @Test func recoverOrphansClosesOpenSessionsEarly() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let rec = try Ledger.openStretch(ctx, projectID: p.id, startedAt: t0)
        try Ledger.checkpoint(ctx, record: rec,
                          events: [SessionEvent(.offtaskStart, at: t0 + 600), SessionEvent(.offtaskEnd, at: t0 + 900)],
                          allowAdded: [], at: t0 + 1200)
        let recovered = try Ledger.recoverOrphans(ctx, now: t0 + 99999)
        #expect(recovered == [rec.id]) // the caller ends the phone's Live Activity for these
        #expect(try Ledger.recoverOrphans(ctx, now: t0 + 99999).isEmpty)
        #expect(rec.endKind == "stopped")
        #expect(rec.earlyReason == nil)
        #expect(rec.endedAt == t0 + 1200)
        #expect(rec.focusedSec == 900)
        #expect(rec.offtaskSec == 300)
        let pts = try ctx.fetch(FetchDescriptor<PointEvent>(sortBy: [SortDescriptor(\.delta, order: .reverse)]))
        #expect(pts.map(\.delta) == [15, -10])
        #expect(pts.map(\.kind) == ["focus", "offtask"])
    }

    @Test func shortStretchesScorePointsOnTheDayTotal() throws {
        let ctx = try makeCtx()
        let p = project(ctx); try ctx.save()
        let day = PeriodCalendar(timeZone: .current).dayInterval(containing: .now)
        var t = day.start.addingTimeInterval(3600)
        var lines: [PointLine] = []
        for _ in 0..<3 {
            let r = try Ledger.openStretch(ctx, projectID: p.id, startedAt: t)
            #expect(r.plannedMin == 0)
            let res = StretchResult(projectID: p.id, startedAt: t, endedAt: t + 90, end: .switched, events: [],
                                    totals: SessionTotals(focusedSec: 90))
            lines += try Ledger.closeStretch(ctx, record: r, result: res, day: day, allowanceSec: 3600, now: t + 90)
            #expect(r.endKind == "switched")
            t += 90
        }
        #expect(lines.map(\.delta) == [1, 2, 1]) // 90 s, 180 s, 270 s → 1, 3, 4 minutes
        #expect(Ledger.balance(ctx) == 4)
    }

    @Test func recoveredOrphanIsDirty() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let rec = try Ledger.openStretch(ctx, projectID: p.id, startedAt: t0)
        try Ledger.checkpoint(ctx, record: rec, events: [], allowAdded: [], at: t0 + 1200)
        rec.syncedAt = rec.updatedAt
        #expect(!rec.isDirty)
        try Ledger.recoverOrphans(ctx, now: t0 + 99999)
        #expect(rec.endedAt != nil)
        #expect(rec.isDirty)
    }

    @Test func recoveryPreservesAllowAdded() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let added = AllowEntry(.app, "com.spotify.client")
        let rec = try Ledger.openStretch(ctx, projectID: p.id, startedAt: t0)
        rec.allowReasons.append("focus music")
        try Ledger.checkpoint(ctx, record: rec, events: [], allowAdded: [added], at: t0 + 100)
        try Ledger.recoverOrphans(ctx, now: t0 + 999)
        #expect(try JSONDecoder().decode([AllowEntry].self, from: rec.allowAddedData) == [added])
        #expect(rec.allowReasons == ["focus music"])
    }

    @Test func summariesOnlyClosedSince() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let day = DateInterval(start: t0 - 3600, end: t0 + 86_400)
        let a = try Ledger.openStretch(ctx, projectID: p.id, startedAt: t0)
        let r = StretchResult(projectID: p.id, startedAt: t0, endedAt: t0 + 600, end: .switched, events: [],
                              totals: SessionTotals(focusedSec: 600))
        try Ledger.closeStretch(ctx, record: a, result: r, day: day, allowanceSec: 3600, now: t0 + 600)
        _ = try Ledger.openStretch(ctx, projectID: p.id, startedAt: t0 + 1000)
        let s = Ledger.summaries(ctx, since: t0 - 1)
        #expect(s.count == 1)
        #expect(s[0].focusedSec == 600)
        #expect(Ledger.summaries(ctx, since: t0 + 1).isEmpty)
    }

    @Test func closeIsIdempotent() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let day = DateInterval(start: t0 - 3600, end: t0 + 86_400)
        let rec = try Ledger.openStretch(ctx, projectID: p.id, startedAt: t0)
        let r = StretchResult(projectID: p.id, startedAt: t0, endedAt: t0 + 600, end: .switched, events: [],
                              totals: SessionTotals(focusedSec: 600))
        try Ledger.closeStretch(ctx, record: rec, result: r, day: day, allowanceSec: 3600, now: t0 + 600)
        try Ledger.closeStretch(ctx, record: rec, result: r, day: day, allowanceSec: 3600, now: t0 + 700)
        #expect(try ctx.fetch(FetchDescriptor<PointEvent>()).count == 1)
    }
}
