import Foundation
import SwiftData
import Core
import os

public enum LedgerError: Error { case insufficientPoints }

@MainActor
public enum Ledger {
    private static let log = Logger(subsystem: "dev.stint", category: "ledger")
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
        record.syncedAt = nil // updatedAt may equal the last checkpoint's; force a push of the close
        let note = projectName(ctx, record.projectID)
        for l in result.points {
            ctx.insert(PointEvent(at: endedAt, delta: l.delta, kind: l.kind.rawValue, refID: record.id, note: note))
        }
        try ctx.save()
    }

    private static func projectName(_ ctx: ModelContext, _ id: UUID) -> String {
        (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })))?.first?.name ?? ""
    }

    /// Opens a stretch (spec 2026-11-26 §3): no planned length (stored as 0, sent as null), no allowlist snapshot.
    public static func openStretch(_ ctx: ModelContext, projectID: UUID, startedAt: Date) throws -> SessionRecord {
        let r = SessionRecord(projectID: projectID, firstTaskID: nil, plannedMin: 0, startedAt: startedAt, allowData: Data("[]".utf8))
        ctx.insert(r)
        try ctx.save()
        return r
    }

    /// Closes a stretch and brings `day`'s points up to date (spec §4). `now` stamps `updatedAt`: a backdated
    /// end can be earlier than the last checkpoint, and the server drops updates older than what it has.
    @discardableResult
    public static func closeStretch(_ ctx: ModelContext, record: SessionRecord, result: StretchResult,
                                    day: DateInterval, allowanceSec: Int, now: Date) throws -> [PointLine] {
        guard record.endedAt == nil else { return [] }
        let t = result.totals
        record.focusedSec = t.focusedSec; record.offtaskSec = t.offtaskSec; record.breakSec = t.breakSec
        record.idleSec = t.idleSec; record.sleepSec = t.sleepSec
        record.endedAt = result.endedAt
        record.endKind = result.end.rawValue
        record.eventsData = try enc(result.events)
        record.updatedAt = max(now, record.updatedAt)
        record.syncedAt = nil
        try ctx.save()

        let start = day.start, end = day.end
        let closed = try ctx.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.endedAt != nil && $0.startedAt >= start && $0.startedAt < end }))
        let today = closed.reduce(SessionTotals()) {
            $0 + SessionTotals(focusedSec: $1.focusedSec, offtaskSec: $1.offtaskSec, breakSec: $1.breakSec)
        }
        var written: [PointKind: Int] = [:]
        for e in try ctx.fetch(FetchDescriptor<PointEvent>(predicate: #Predicate { $0.at >= start && $0.at < end })) {
            if let k = PointKind(rawValue: e.kind), [.focus, .offtask, .breakOver].contains(k) { written[k, default: 0] += e.delta }
        }
        let lines = dayPoints(today: today, allowanceSec: allowanceSec, written: written)
        let at = min(result.endedAt, end.addingTimeInterval(-1)) // a midnight split ends at the next day's first second
        let note = projectName(ctx, record.projectID)
        for l in lines { ctx.insert(PointEvent(at: at, delta: l.delta, kind: l.kind.rawValue, refID: record.id, note: note)) }
        try ctx.save()
        return lines
    }

    /// Closes stretches left open by a quit or crash at their last checkpoint; returns their ids so the caller
    /// can end the phone's Live Activity.
    @discardableResult
    public static func recoverOrphans(_ ctx: ModelContext, now: Date, allowanceSec: Int = 3600) throws -> [UUID] {
        let open = (try? ctx.fetch(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.endedAt == nil }))) ?? []
        let cal = PeriodCalendar(timeZone: .current)
        var closed: [UUID] = []
        for r in open {
            let end = r.updatedAt
            let events = (dec(r.eventsData) as [SessionEvent]).filter { $0.at <= end }
            let result = StretchResult(projectID: r.projectID, startedAt: r.startedAt, endedAt: end, end: .stopped,
                                       events: events, totals: sessionTotals(start: r.startedAt, end: end, events: events))
            do {
                try closeStretch(ctx, record: r, result: result, day: cal.dayInterval(containing: r.startedAt),
                                 allowanceSec: allowanceSec, now: now)
                closed.append(r.id)
            } catch { log.error("recoverOrphans failed for \(r.id): \(error)") }
        }
        return closed
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
