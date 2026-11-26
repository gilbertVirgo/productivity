import Testing
import Foundation
import SwiftData
import Supabase
import Core
@testable import StintData

private final class MemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { items[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { items[key] } }
    func remove(key: String) throws { lock.withLock { items[key] = nil } }
}

private struct IDRow: Decodable { let id: UUID }

@MainActor private func signedInClient() async throws -> (SupabaseClient, UUID) {
    let env = ProcessInfo.processInfo.environment
    let client = SupabaseClient(
        supabaseURL: URL(string: env["STINT_SUPABASE_URL"]!)!, supabaseKey: env["STINT_SUPABASE_ANON_KEY"]!,
        options: .init(db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
                       auth: .init(storage: MemoryStorage(), emitLocalSessionAsInitialSession: true)))
    let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    let password = String((0..<24).map { _ in chars.randomElement()! })
    let auth = try await client.auth.signUp(email: "sync-\(UUID())@test.local", password: password)
    return (client, auth.user.id)
}

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["STINT_SUPABASE_URL"] != nil))
struct SyncIntegrationTests {
    func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    func defaults() -> UserDefaults { UserDefaults(suiteName: "sync-test-\(UUID())")! }

    @Test func pushPullLWWAndTombstone() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = SupabaseClient(
            supabaseURL: URL(string: env["STINT_SUPABASE_URL"]!)!, supabaseKey: env["STINT_SUPABASE_ANON_KEY"]!,
            options: .init(db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
                           auth: .init(storage: MemoryStorage(), emitLocalSessionAsInitialSession: true)))
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let password = String((0..<24).map { _ in chars.randomElement()! })
        let auth = try await client.auth.signUp(email: "sync-\(UUID())@test.local", password: password)
        let uid = auth.user.id

        func countOf(_ table: String) async throws -> Int {
            let rows: [IDRow] = try await client.from(table).select("id").execute().value
            return rows.count
        }

        // Device A
        let a = try ctx()
        let now = Date.now
        let old = now.addingTimeInterval(-600)
        let project = Project(name: "Northwind", now: old)
        a.insert(project)
        let rule = AllowRule(AllowEntry(.domain, "northwind.test"), now: old); a.insert(rule); rule.project = project
        let task = TaskItem(title: "Ship", now: old); a.insert(task); task.project = project
        let enc = JSONEncoder()
        let session = SessionRecord(projectID: project.id, firstTaskID: task.id, plannedMin: 25, startedAt: old,
                                    allowData: try enc.encode([AllowEntry]()))
        session.endedAt = old.addingTimeInterval(1500); session.endKind = "completed"
        session.eventsData = try enc.encode([SessionEvent(.offtaskStart, at: old.addingTimeInterval(60), detail: ["domain": "x.test"]),
                                             SessionEvent(.offtaskEnd, at: old.addingTimeInterval(90))])
        session.allowAddedData = try enc.encode([AllowEntry(.app, "com.test.app")])
        session.allowReasons = ["needed it"]
        a.insert(session)
        a.insert(PointEvent(at: old, delta: 10, kind: "focus", refID: session.id, note: "Northwind"))
        a.insert(PointEvent(at: old, delta: 5, kind: "session_complete", refID: session.id, note: "Northwind"))
        try a.save()

        let defA = defaults(), defB = defaults()
        defA.set("Alice", forKey: "displayName"); defA.set(Date.now.timeIntervalSince1970, forKey: "profileUpdatedAt")
        let engineA = SyncEngine(client: client, context: a, defaults: defA)
        try await engineA.push(userID: uid)
        #expect(try await countOf("project") == 1)
        #expect(try await countOf("session_event") == 2)
        #expect(try await countOf("session_allow") == 1)
        #expect(try await countOf("point_event") == 2)
        try await engineA.push(userID: uid)
        #expect(try await countOf("session_event") == 2)
        #expect(try await countOf("session_allow") == 1)
        #expect(try await countOf("point_event") == 2)

        // Device B
        let b = try ctx()
        let engineB = SyncEngine(client: client, context: b, defaults: defB)
        try await engineB.push(userID: uid) // fresh defaults: must not clobber A's profile
        try await engineB.pull()
        let prof: [ProfileRow] = try await client.from("profile").select().execute().value
        #expect(prof.first?.displayName == "Alice")
        #expect(defB.string(forKey: "displayName") == "Alice")
        let bp = try b.fetch(FetchDescriptor<Project>())
        #expect(bp.count == 1 && bp[0].allowRules.count == 1 && bp[0].tasks.count == 1)
        #expect(try b.fetch(FetchDescriptor<PointEvent>()).count == 2)
        #expect(try b.fetch(FetchDescriptor<SessionRecord>()).isEmpty)

        // LWW: B renames (newer) and pushes; A's older edit is rejected server-side.
        bp[0].name = "Northwind Co"; bp[0].updatedAt = now
        try await engineB.push(userID: uid)
        project.name = "Old"; project.updatedAt = now.addingTimeInterval(-60)
        try await engineA.push(userID: uid)
        try await engineA.pull()
        #expect(project.name == "Northwind Co")

        // Tombstone
        a.delete(rule)
        a.insert(Tombstone(table: "project_allow", rowID: rule.id))
        try a.save()
        try await engineA.push(userID: uid)
        #expect(try await countOf("project_allow") == 0)

        try await client.auth.signOut()
    }

    @Test func pullPagesThroughTiedRows() async throws {
        let env = ProcessInfo.processInfo.environment
        let client = SupabaseClient(
            supabaseURL: URL(string: env["STINT_SUPABASE_URL"]!)!, supabaseKey: env["STINT_SUPABASE_ANON_KEY"]!,
            options: .init(db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
                           auth: .init(storage: MemoryStorage(), emitLocalSessionAsInitialSession: true)))
        let auth = try await client.auth.signUp(email: "page-\(UUID())@test.local", password: "pw-\(UUID().uuidString)")
        let a = try ctx(), b = try ctx()
        for i in 0..<5 { a.insert(PointEvent(at: .now.addingTimeInterval(Double(-i)), delta: 1, kind: "focus", refID: nil, note: "n\(i)")) }
        try a.save()
        try await SyncEngine(client: client, context: a, defaults: defaults()).push(userID: auth.user.id)
        let saved = SyncEngine.pageSize
        SyncEngine.pageSize = 2; defer { SyncEngine.pageSize = saved }
        try await SyncEngine(client: client, context: b, defaults: defaults()).pull()
        #expect(try b.fetch(FetchDescriptor<PointEvent>()).count == 5)
        try await client.auth.signOut()
    }

    @Test func phoneCommandsAndNoProfilePush() async throws {
        let (client, uid) = try await signedInClient()
        let d = defaults()
        d.set("Phone", forKey: "displayName"); d.set(Date.now.timeIntervalSince1970, forKey: "profileUpdatedAt")
        let phone = SyncEngine(client: client, context: try ctx(), defaults: d, pushesProfile: false)
        try await phone.push(userID: uid)
        let prof: [ProfileRow] = try await client.from("profile").select().execute().value
        #expect(prof.first?.displayName == "")

        let id = try await phone.sendCommand(.stop, userID: uid)
        let sent = try #require(try await phone.command(id))
        #expect(SessionCommand.parse(sent) == .stop)
        #expect(sent.rejectedReason == nil)
        try await phone.rejectCommand(id, reason: "No session is running on your Mac.")
        #expect(try await phone.command(id)?.rejectedReason == "No session is running on your Mac.")
        try await phone.deleteCommand(id)
        #expect(try await phone.command(id) == nil)
        try await client.auth.signOut()
    }

    @Test func phoneFeedReadsMacSessions() async throws {
        let (client, uid) = try await signedInClient()
        let mac = try ctx()
        let now = Date.now
        let p = Project(name: "Northwind", now: now.addingTimeInterval(-7200)); mac.insert(p)
        let none = try JSONEncoder().encode([AllowEntry]())
        let closed = SessionRecord(projectID: p.id, firstTaskID: nil, plannedMin: 25, startedAt: now.addingTimeInterval(-3600), allowData: none)
        closed.endedAt = now.addingTimeInterval(-2100); closed.endKind = "completed"
        let open = SessionRecord(projectID: p.id, firstTaskID: nil, plannedMin: 50, startedAt: now.addingTimeInterval(-300), allowData: none)
        open.eventsData = try JSONEncoder().encode([SessionEvent(.breakStart, at: now.addingTimeInterval(-60))])
        mac.insert(closed); mac.insert(open); try mac.save()
        try await SyncEngine(client: client, context: mac, defaults: defaults()).push(userID: uid)

        let phone = SyncEngine(client: client, context: try ctx(), defaults: defaults(), pushesProfile: false)
        let rows = try await phone.sessionTotals(since: now.addingTimeInterval(-7200))
        #expect(rows.count == 2)
        #expect(rows.first { $0.sessionID == closed.id }?.focusedSec == 1500)
        #expect(rows.first { $0.sessionID == open.id }?.endedAt == nil)
        let run = try #require(try await phone.runningSession())
        #expect(run.id == open.id && run.plannedMin == 50 && run.onBreak)
        try await client.auth.signOut()
    }

    @Test func shareLinkLifecycleAndPage() async throws {
        let (client, _) = try await signedInClient()
        let engine = SyncEngine(client: client, context: try ctx(), defaults: defaults())
        let link = try await engine.createShareLink(label: "Sam")
        #expect(link.token.count == 43 && link.friendLabel == "Sam")
        #expect(try await engine.shareLinks().map(\.id) == [link.id])

        // The page is anonymous: no session, anon key only.
        let env = ProcessInfo.processInfo.environment
        let anon = SupabaseClient(supabaseURL: URL(string: env["STINT_SUPABASE_URL"]!)!, supabaseKey: env["STINT_SUPABASE_ANON_KEY"]!,
                                  options: .init(auth: .init(storage: MemoryStorage(), emitLocalSessionAsInitialSession: true)))
        func page() async throws -> String {
            String(decoding: try await anon.rpc("share_data", params: ["p_token": link.token]).execute().data, as: UTF8.self)
        }
        #expect(try await page().contains("\"projects\""))
        #expect(!(try await page().contains("Sam")))

        try await engine.revokeShareLink(id: link.id)
        #expect(try await engine.shareLinks().isEmpty)
        #expect(try await page() == "null")
    }
}
