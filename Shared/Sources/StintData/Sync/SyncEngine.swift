import Foundation
import SwiftData
import Supabase
import os

/// Push local dirty rows / pull remote changes / subscribe to realtime. Conflict rule: last-write-wins on `updated_at`
/// (server trigger rejects stale updates; `Mapping.apply` rejects stale remote rows).
@MainActor
public final class SyncEngine {
    private let client: SupabaseClient
    private let context: ModelContext
    private let defaults: UserDefaults
    private let pushesProfile: Bool
    private var channel: RealtimeChannelV2?
    private var listeners: [Task<Void, Never>] = []

    /// Re-read this far behind the watermark: transactions can commit out of `now()` order; re-applying is idempotent.
    private static let lookback: TimeInterval = 300
    private static let editableTables = ["project", "project_allow", "task", "treat", "session"]

    public init(client: SupabaseClient, context: ModelContext, defaults: UserDefaults = .standard,
                pushesProfile: Bool = true) {
        self.client = client; self.context = context; self.defaults = defaults; self.pushesProfile = pushesProfile
    }

    // MARK: push

    public func push(userID: UUID) async throws {
        if pushesProfile { try await pushProfile(userID) }
        try await pushEditable("project", Project.self) { m in (Mapping.row(m, userID: userID), m.updatedAt) }
        try await pushEditable("project_allow", AllowRule.self) { m in Mapping.row(m, userID: userID).map { ($0, m.updatedAt) } }
        try await pushEditable("task", TaskItem.self) { m in Mapping.row(m, userID: userID).map { ($0, m.updatedAt) } }
        try await pushEditable("treat", Treat.self) { m in (Mapping.row(m, userID: userID), m.updatedAt) }

        let sessions = try dirty(SessionRecord.self)
        let sent = sessions.map { ($0, Mapping.row($0, userID: userID), Mapping.sessionChildren($0, userID: userID)) }
        try await upsert("session", sent.map(\.1))
        try await upsert("session_allow", sent.flatMap(\.2.allow), ignoreDuplicates: true)
        try await upsert("session_event", sent.flatMap(\.2.events), ignoreDuplicates: true)
        for (m, row, _) in sent { m.syncedAt = row.updatedAt }
        try context.save()

        try await pushEditable("point_event", PointEvent.self, ignoreDuplicates: true) { m in (Mapping.row(m, userID: userID), m.updatedAt) }

        for t in try context.fetch(FetchDescriptor<Tombstone>()) {
            try await client.from(t.table).delete().eq("id", value: t.rowID).execute()
            context.delete(t)
            try context.save()
        }
    }

    private func pushProfile(_ userID: UUID) async throws {
        // Timezone always goes alone and without updated_at, so the stale-update trigger lets it through and
        // close_periods has the real timezone before the user edits anything.
        try await client.from("profile").update(["timezone": TimeZone.current.identifier]).eq("user_id", value: userID).execute()
        // The full row goes only once the user has edited it (or pulled a server copy): never clobber with defaults.
        guard let stamp = defaults.object(forKey: "profileUpdatedAt") as? Double else { return }
        let row = ProfileRow(userID: userID, updatedAt: Date(timeIntervalSince1970: stamp),
                             timezone: TimeZone.current.identifier,
                             breakAllowanceMin: defaults.object(forKey: "breakAllowanceMin") as? Int ?? 60,
                             displayName: defaults.string(forKey: "displayName") ?? "")
        try await upsert("profile", [row], onConflict: "user_id")
    }

    private func dirty<M: PersistentModel & Syncable & AnyObject>(_ type: M.Type) throws -> [M] {
        try context.fetch(FetchDescriptor<M>()).filter(\.isDirty)
    }

    private func upsert<R: Encodable>(_ table: String, _ rows: [R], onConflict: String = "id", ignoreDuplicates: Bool = false) async throws {
        guard !rows.isEmpty else { return }
        try await client.from(table).upsert(rows, onConflict: onConflict, returning: .minimal, ignoreDuplicates: ignoreDuplicates).execute()
    }

    /// `build` returns the wire row plus the `updatedAt` captured at build time. syncedAt takes that value, not the
    /// model's current one, so an edit made during the await stays dirty.
    private func pushEditable<M: PersistentModel & Syncable & AnyObject, R: Encodable>(
        _ table: String, _ type: M.Type, ignoreDuplicates: Bool = false, build: (M) -> (R, Date)?
    ) async throws {
        let sent = try dirty(type).compactMap { m in build(m).map { (m, $0.0, $0.1) } }
        try await upsert(table, sent.map(\.1), ignoreDuplicates: ignoreDuplicates)
        for (var m, _, at) in sent { m.syncedAt = at } // `var` is required: Syncable is not class-bound, so the compiler rejects assigning through a `let`
        try context.save()
    }

    // MARK: pull

    private func watermark(_ table: String) -> Date {
        Date(timeIntervalSince1970: defaults.double(forKey: "sync.watermark.\(table)"))
    }

    /// Page size for pulls. PostgREST caps a response at 1000 rows; rows can tie on the cursor (a first push gives every row
    /// the same server timestamp), so we page by offset over a stable (cursor, id) order instead of trusting the watermark.
    static var pageSize = 1000

    private func fetchAll<R: Decodable>(_ table: String, column: String) async throws -> [R] {
        let since = Self.iso(watermark(table).addingTimeInterval(-Self.lookback))
        var all: [R] = []
        while true {
            let from = all.count
            let page: [R] = try await client.from(table).select().gt(column, value: since)
                .order(column, ascending: true).order("id", ascending: true)
                .range(from: from, to: from + Self.pageSize - 1).execute().value
            all += page
            if page.count < Self.pageSize { return all }
        }
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private struct Stamped<R: Decodable>: Decodable {
        let row: R, createdAt: Date
        init(from d: Decoder) throws {
            row = try R(from: d)
            createdAt = try d.container(keyedBy: Key.self).decode(Date.self, forKey: .createdAt)
        }
        enum Key: String, CodingKey { case createdAt = "created_at" }
    }

    public func pull() async throws {
        // Built after each network await, so edits made meanwhile are seen; deleted models are skipped.
        func byID<M: PersistentModel>(_ type: M.Type, _ id: (M) -> UUID) throws -> [UUID: M] {
            Dictionary(try context.fetch(FetchDescriptor<M>()).filter { !$0.isDeleted }.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        }
        func deadIDs() throws -> Set<UUID> { Set(try context.fetch(FetchDescriptor<Tombstone>()).map(\.rowID)) }
        // Watermarks are written only after the save succeeds, so a failed pull is retried in full.
        var marks: [(String, Date)] = []
        func advance(_ table: String, _ dates: [Date]) {
            if let m = dates.max(), m > watermark(table) { marks.append((table, m)) }
        }

        let prs: [ProjectRow] = try await fetchAll("project", column: "server_updated_at")
        var projects = try byID(Project.self, \.id), dead = try deadIDs()
        for r in prs where !dead.contains(r.id) {
            if let p = projects[r.id] { _ = Mapping.apply(r, to: p) } else { projects[r.id] = Mapping.insert(r, in: context) }
        }
        advance("project", prs.compactMap(\.serverUpdatedAt))

        let ars: [ProjectAllowRow] = try await fetchAll("project_allow", column: "server_updated_at")
        var rules = try byID(AllowRule.self, \.id); dead = try deadIDs()
        for r in ars where !dead.contains(r.id) {
            if let a = rules[r.id] { _ = Mapping.apply(r, to: a) } else if let a = Mapping.insert(r, in: context) { rules[r.id] = a }
        }
        advance("project_allow", ars.compactMap(\.serverUpdatedAt))

        let trs: [TaskRow] = try await fetchAll("task", column: "server_updated_at")
        var tasks = try byID(TaskItem.self, \.id); dead = try deadIDs()
        for r in trs where !dead.contains(r.id) {
            if let t = tasks[r.id] { _ = Mapping.apply(r, to: t) } else if let t = Mapping.insert(r, in: context) { tasks[r.id] = t }
        }
        advance("task", trs.compactMap(\.serverUpdatedAt))

        let tr: [TreatRow] = try await fetchAll("treat", column: "server_updated_at")
        var treats = try byID(Treat.self, \.id); dead = try deadIDs()
        for r in tr where !dead.contains(r.id) {
            if let t = treats[r.id] { _ = Mapping.apply(r, to: t) } else { treats[r.id] = Mapping.insert(r, in: context) }
        }
        advance("treat", tr.compactMap(\.serverUpdatedAt))

        // Sessions are Mac-owned: update existing local rows only, never insert.
        let srs: [SessionRow] = try await fetchAll("session", column: "server_updated_at")
        let sessions = try byID(SessionRecord.self, \.id)
        for r in srs { if let s = sessions[r.id] { _ = Mapping.apply(r, to: s) } }
        advance("session", srs.compactMap(\.serverUpdatedAt))

        let pes: [Stamped<PointEventRow>] = try await fetchAll("point_event", column: "created_at")
        var events = try byID(PointEvent.self, \.id)
        for s in pes where events[s.row.id] == nil { events[s.row.id] = Mapping.insert(s.row, in: context) }
        advance("point_event", pes.map(\.createdAt))

        let grs: [GoalResultRow] = try await fetchAll("goal_result", column: "created_at")
        let goals = try byID(GoalResultRecord.self, \.id)
        for r in grs where goals[r.id] == nil { _ = Mapping.insert(r, in: context) }
        advance("goal_result", grs.map(\.createdAt))

        let profiles: [ProfileRow] = try await client.from("profile").select().limit(1).execute().value
        try context.save()
        for (t, d) in marks { defaults.set(d.timeIntervalSince1970, forKey: "sync.watermark.\(t)") }
        if let p = profiles.first {
            let local = defaults.object(forKey: "profileUpdatedAt") as? Double
            if local == nil || p.updatedAt.timeIntervalSince1970 > local! {
                defaults.set(p.displayName, forKey: "displayName")
                defaults.set(p.breakAllowanceMin, forKey: "breakAllowanceMin")
                defaults.set(p.updatedAt.timeIntervalSince1970, forKey: "profileUpdatedAt")
            }
        }
    }

    // MARK: realtime

    public func startRealtime(userID: UUID, onChange: @escaping @MainActor () -> Void) async {
        await stopRealtime()
        let ch = client.channel("stint-sync")
        let tables = Self.editableTables + ["point_event", "goal_result", "session_command"]
        // Not DELETE: delete events cannot be RLS-filtered, so they would fan out across users. Tombstones are pulled by timer.
        let f = RealtimePostgresFilter.eq("user_id", value: userID)
        for t in tables {
            let i = ch.postgresChange(InsertAction.self, schema: "public", table: t, filter: f)
            let u = ch.postgresChange(UpdateAction.self, schema: "public", table: t, filter: f)
            listeners.append(Task { @MainActor in for await _ in i { onChange() } })
            listeners.append(Task { @MainActor in for await _ in u { onChange() } })
        }
        channel = ch
        do { try await ch.subscribeWithError() }
        catch { Logger(subsystem: "dev.stint", category: "sync").error("realtime subscribe failed: \(error.localizedDescription, privacy: .public)") }
    }

    public func stopRealtime() async {
        listeners.forEach { $0.cancel() }
        listeners = []
        if let ch = channel { await client.removeChannel(ch) }
        channel = nil
    }

    // MARK: session commands

    public func pendingCommands() async throws -> [SessionCommandRow] {
        try await client.from("session_command").select().order("created_at", ascending: true).execute().value
    }

    public func deleteCommand(_ id: UUID) async throws {
        try await client.from("session_command").delete().eq("id", value: id).execute()
    }

    /// Phone side: insert a command. Returns its id for `command(_:)` polling.
    public func sendCommand(_ cmd: SessionCommand, userID: UUID) async throws -> UUID {
        let w = cmd.wire
        let row = NewSessionCommandRow(id: UUID(), userID: userID, kind: w.kind, payload: w.payload)
        try await client.from("session_command").insert(row, returning: .minimal).execute()
        return row.id
    }

    /// nil once the Mac has deleted it (accepted).
    public func command(_ id: UUID) async throws -> SessionCommandRow? {
        let rows: [SessionCommandRow] = try await client.from("session_command").select().eq("id", value: id).execute().value
        return rows.first
    }

    /// Mac side: leave the row for the phone to read instead of deleting it.
    public func rejectCommand(_ id: UUID, reason: String) async throws {
        try await client.from("session_command").update(["rejected_reason": reason]).eq("id", value: id).execute()
    }
}
