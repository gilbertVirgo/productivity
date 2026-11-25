import Foundation
import SwiftData
import Core
import os

public enum LedgerError: Error { case insufficientPoints }

@MainActor
public enum Ledger {
    private static let log = Logger(subsystem: "dev.stint.mac", category: "ledger")
    private static func enc<T: Encodable>(_ v: T) throws -> Data { try JSONEncoder().encode(v) }
    private static func dec<T: Decodable>(_ d: Data) -> [T] { (try? JSONDecoder().decode([T].self, from: d)) ?? [] }

    public static func openSession(_ ctx: ModelContext, project: Project, plannedMin: Int, firstTask: TaskItem?,
                            startedAt: Date, allow: [AllowEntry]) throws -> SessionRecord {
        let r = SessionRecord(projectID: project.id, firstTaskID: firstTask?.id, plannedMin: plannedMin,
                              startedAt: startedAt, allowData: try enc(allow))
        ctx.insert(r)
        try ctx.save()
        return r
    }

    public static func checkpoint(_ ctx: ModelContext, record: SessionRecord, events: [SessionEvent], allowAdded: [AllowEntry], at: Date) throws {
        let e = try enc(events), a = try enc(allowAdded)
        record.eventsData = e
        record.allowAddedData = a
        record.updatedAt = at
        try ctx.save()
    }

    public static func close(_ ctx: ModelContext, record: SessionRecord, result: SessionResult, endedAt: Date, earlyReason: String?) throws {
        guard record.endedAt == nil else { return }
        let events = try enc(result.events)
        let added = try enc(result.allowAdded)
        let t = result.totals
        record.focusedSec = t.focusedSec; record.offtaskSec = t.offtaskSec; record.breakSec = t.breakSec
        record.idleSec = t.idleSec; record.sleepSec = t.sleepSec
        record.endedAt = endedAt
        record.endKind = result.completed ? "completed" : "early"
        record.earlyReason = earlyReason
        record.eventsData = events
        record.allowAddedData = added
        record.updatedAt = endedAt
        let note = projectName(ctx, record.projectID)
        for l in result.points {
            ctx.insert(PointEvent(at: endedAt, delta: l.delta, kind: l.kind.rawValue, refID: record.id, note: note))
        }
        try ctx.save()
    }

    private static func projectName(_ ctx: ModelContext, _ id: UUID) -> String {
        (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })))?.first?.name ?? ""
    }

    public static func recoverOrphans(_ ctx: ModelContext, now: Date) throws {
        let open = (try? ctx.fetch(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.endedAt == nil }))) ?? []
        for r in open {
            let end = r.updatedAt
            let events: [SessionEvent] = dec(r.eventsData)
            let t = sessionTotals(start: r.startedAt, end: end, events: events)
            let result = SessionResult(totals: t, completed: false,
                                       points: sessionPoints(totals: t, completed: false, breakOverSec: 0),
                                       events: events, allowAdded: dec(r.allowAddedData))
            do { try close(ctx, record: r, result: result, endedAt: end, earlyReason: "Stint quit during session") }
            catch { log.error("recoverOrphans failed for \(r.id): \(error)") }
        }
    }

    public static func balance(_ ctx: ModelContext) -> Int {
        ((try? ctx.fetch(FetchDescriptor<PointEvent>())) ?? []).reduce(0) { $0 + $1.delta }
    }

    public static func redeem(_ ctx: ModelContext, treat: Treat, at: Date) throws {
        guard canRedeem(cost: treat.cost, balance: balance(ctx)) else { throw LedgerError.insufficientPoints }
        ctx.insert(PointEvent(at: at, delta: -treat.cost, kind: PointKind.redeem.rawValue, refID: treat.id, note: treat.name))
        try ctx.save()
    }

    public static func summaries(_ ctx: ModelContext, since: Date) -> [SessionSummary] {
        let rows = (try? ctx.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.endedAt != nil && $0.startedAt >= since }))) ?? []
        return rows.map(\.summary)
    }

    public static func breakUsedSec(_ ctx: ModelContext, in interval: DateInterval) -> Int {
        Core.breakSec(summaries(ctx, since: interval.start), in: interval)
    }
}
