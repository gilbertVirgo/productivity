import Foundation
import SwiftData
import Core

enum LedgerError: Error { case insufficientPoints }

@MainActor
enum Ledger {
    private static func enc<T: Encodable>(_ v: T) -> Data { (try? JSONEncoder().encode(v)) ?? Data("[]".utf8) }
    private static func dec<T: Decodable>(_ d: Data) -> [T] { (try? JSONDecoder().decode([T].self, from: d)) ?? [] }

    static func openSession(_ ctx: ModelContext, project: Project, plannedMin: Int, firstTask: TaskItem?,
                            startedAt: Date, allow: [AllowEntry]) -> SessionRecord {
        let r = SessionRecord(projectID: project.id, firstTaskID: firstTask?.id, plannedMin: plannedMin,
                              startedAt: startedAt, allowData: enc(allow))
        ctx.insert(r)
        try? ctx.save()
        return r
    }

    static func checkpoint(_ ctx: ModelContext, record: SessionRecord, events: [SessionEvent], allow: [AllowEntry], at: Date) {
        record.eventsData = enc(events)
        record.allowData = enc(allow)
        record.updatedAt = at
        try? ctx.save()
    }

    static func close(_ ctx: ModelContext, record: SessionRecord, result: SessionResult, endedAt: Date, earlyReason: String?) {
        let t = result.totals
        record.focusedSec = t.focusedSec; record.offtaskSec = t.offtaskSec; record.breakSec = t.breakSec
        record.idleSec = t.idleSec; record.sleepSec = t.sleepSec
        record.endedAt = endedAt
        record.endKind = result.completed ? "completed" : "early"
        record.earlyReason = earlyReason
        record.eventsData = enc(result.events)
        record.allowData = enc((dec(record.allowData) as [AllowEntry]) + result.allowAdded)
        record.updatedAt = endedAt
        let note = projectName(ctx, record.projectID)
        for l in result.points {
            ctx.insert(PointEvent(at: endedAt, delta: l.delta, kind: l.kind.rawValue, refID: record.id, note: note))
        }
        try? ctx.save()
    }

    private static func projectName(_ ctx: ModelContext, _ id: UUID) -> String {
        (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })))?.first?.name ?? ""
    }

    static func recoverOrphans(_ ctx: ModelContext, now: Date) {
        let open = (try? ctx.fetch(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.endedAt == nil }))) ?? []
        for r in open {
            let end = r.updatedAt
            let events: [SessionEvent] = dec(r.eventsData)
            let t = sessionTotals(start: r.startedAt, end: end, events: events)
            let result = SessionResult(totals: t, completed: false,
                                       points: sessionPoints(totals: t, completed: false, breakOverSec: 0),
                                       events: events, allowAdded: [])
            close(ctx, record: r, result: result, endedAt: end, earlyReason: "Stint quit during session")
        }
    }

    static func balance(_ ctx: ModelContext) -> Int {
        ((try? ctx.fetch(FetchDescriptor<PointEvent>())) ?? []).reduce(0) { $0 + $1.delta }
    }

    static func redeem(_ ctx: ModelContext, treat: Treat, at: Date) throws {
        guard canRedeem(cost: treat.cost, balance: balance(ctx)) else { throw LedgerError.insufficientPoints }
        ctx.insert(PointEvent(at: at, delta: -treat.cost, kind: PointKind.redeem.rawValue, refID: treat.id, note: treat.name))
        try ctx.save()
    }

    static func summaries(_ ctx: ModelContext, since: Date) -> [SessionSummary] {
        let rows = (try? ctx.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.endedAt != nil && $0.startedAt >= since }))) ?? []
        return rows.map(\.summary)
    }

    static func breakUsedSec(_ ctx: ModelContext, in interval: DateInterval) -> Int {
        Core.breakSec(summaries(ctx, since: interval.start), in: interval)
    }
}
