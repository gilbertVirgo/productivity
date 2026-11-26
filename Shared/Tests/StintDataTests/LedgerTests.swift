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

    @Test func closeWritesTotalsAndPoints() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let rec = try Ledger.openSession(ctx, project: p, plannedMin: 50, firstTask: nil, startedAt: t0, allow: [])
        let result = SessionResult(
            totals: SessionTotals(focusedSec: 3000), completed: true,
            points: [PointLine(kind: .focus, delta: 50), PointLine(kind: .sessionComplete, delta: 10)],
            events: [], allowAdded: [])
        try Ledger.close(ctx, record: rec, result: result, endedAt: t0 + 3000, earlyReason: nil)
        #expect(rec.endKind == "completed")
        #expect(rec.focusedSec == 3000)
        let pts = try ctx.fetch(FetchDescriptor<PointEvent>())
        #expect(pts.count == 2)
        #expect(pts.allSatisfy { $0.refID == rec.id })
        #expect(Ledger.balance(ctx) == 60)
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
        let rec = try Ledger.openSession(ctx, project: p, plannedMin: 50, firstTask: nil, startedAt: t0, allow: [])
        try Ledger.checkpoint(ctx, record: rec,
                          events: [SessionEvent(.offtaskStart, at: t0 + 600), SessionEvent(.offtaskEnd, at: t0 + 900)],
                          allowAdded: [], at: t0 + 1200)
        let recovered = try Ledger.recoverOrphans(ctx, now: t0 + 99999)
        #expect(recovered == [rec.id]) // the caller ends the phone's Live Activity for these
        #expect(try Ledger.recoverOrphans(ctx, now: t0 + 99999).isEmpty)
        #expect(rec.endKind == "early")
        #expect(rec.earlyReason == "Stint quit during session")
        #expect(rec.endedAt == rec.updatedAt)
        #expect(rec.focusedSec == 900)
        #expect(rec.offtaskSec == 300)
        let pts = try ctx.fetch(FetchDescriptor<PointEvent>(sortBy: [SortDescriptor(\.delta, order: .reverse)]))
        #expect(pts.map(\.delta) == [15, -10])
        #expect(pts.map(\.kind) == ["focus", "offtask"])
    }

    @Test func recoveredOrphanIsDirty() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let rec = try Ledger.openSession(ctx, project: p, plannedMin: 50, firstTask: nil, startedAt: t0, allow: [])
        try Ledger.checkpoint(ctx, record: rec, events: [], allowAdded: [], at: t0 + 1200)
        rec.syncedAt = rec.updatedAt
        #expect(!rec.isDirty)
        try Ledger.recoverOrphans(ctx, now: t0 + 99999)
        #expect(rec.endedAt != nil)
        #expect(rec.isDirty)
    }

    @Test func allowAddedKeptSeparateFromSnapshotAndPairedWithReasons() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let base = AllowEntry(.app, "com.figma.desktop"), added = AllowEntry(.domain, "docs.example.com")
        let rec = try Ledger.openSession(ctx, project: p, plannedMin: 50, firstTask: nil, startedAt: t0, allow: [base])
        let snapshot = rec.allowData
        rec.allowReasons.append("needed docs")
        try Ledger.checkpoint(ctx, record: rec, events: [], allowAdded: [added], at: t0 + 100)
        let r = SessionResult(totals: SessionTotals(focusedSec: 100), completed: false, points: [], events: [], allowAdded: [added])
        try Ledger.close(ctx, record: rec, result: r, endedAt: t0 + 100, earlyReason: "x")
        #expect(rec.allowData == snapshot)
        let got = try JSONDecoder().decode([AllowEntry].self, from: rec.allowAddedData)
        #expect(got == [added])
        #expect(rec.allowReasons.count == got.count)
    }

    @Test func recoveryPreservesAllowAdded() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let added = AllowEntry(.app, "com.spotify.client")
        let rec = try Ledger.openSession(ctx, project: p, plannedMin: 50, firstTask: nil, startedAt: t0, allow: [])
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
        let a = try Ledger.openSession(ctx, project: p, plannedMin: 25, firstTask: nil, startedAt: t0, allow: [])
        let r = SessionResult(totals: SessionTotals(focusedSec: 600), completed: false, points: [], events: [], allowAdded: [])
        try Ledger.close(ctx, record: a, result: r, endedAt: t0 + 600, earlyReason: "x")
        _ = try Ledger.openSession(ctx, project: p, plannedMin: 25, firstTask: nil, startedAt: t0 + 1000, allow: [])
        let s = Ledger.summaries(ctx, since: t0 - 1)
        #expect(s.count == 1)
        #expect(s[0].focusedSec == 600)
        #expect(Ledger.summaries(ctx, since: t0 + 1).isEmpty)
    }

    @Test func closeIsIdempotent() throws {
        let ctx = try makeCtx()
        let p = project(ctx)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let rec = try Ledger.openSession(ctx, project: p, plannedMin: 25, firstTask: nil, startedAt: t0, allow: [])
        let r = SessionResult(totals: SessionTotals(focusedSec: 600), completed: false,
                              points: [PointLine(kind: .focus, delta: 10)], events: [], allowAdded: [])
        try Ledger.close(ctx, record: rec, result: r, endedAt: t0 + 600, earlyReason: nil)
        try Ledger.close(ctx, record: rec, result: r, endedAt: t0 + 700, earlyReason: nil)
        #expect(try ctx.fetch(FetchDescriptor<PointEvent>()).count == 1)
    }
}
