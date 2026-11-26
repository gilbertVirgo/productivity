import Testing
import Foundation
import SwiftData
import Core
@testable import StintData

@MainActor @Suite struct MappingTests {
    let uid = UUID()
    func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    func json(_ r: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: SyncCoding.encoder.encode(r)) as! [String: Any]
    }

    @Test func projectEncodesNullAndExactKeys() throws {
        let p = Project(name: "A")
        let j = try json(Mapping.row(p, userID: uid))
        #expect(j["archived_at"] is NSNull)
        #expect(j["weekly_hours_goal"] is NSNull)
        #expect(Set(j.keys) == ["id", "user_id", "updated_at", "name", "share_alias", "color", "weekly_hours_goal",
                                "daily_hours_goal", "daily_goal_days", "tasks_goal", "tasks_goal_period", "shared", "archived_at",
                                "icon", "short_name", "off_mac"])
        #expect(j["daily_goal_days"] as? [Int] == [1, 2, 3, 4, 5])
    }

    @Test func roundTripAndServerUpdatedAtNeverEncoded() throws {
        let p = Project(name: "A", now: Date(timeIntervalSince1970: 1_800_000_000.123))
        p.archivedAt = Date(timeIntervalSince1970: 1_800_000_100.5)
        var row = Mapping.row(p, userID: uid)
        row.serverUpdatedAt = .now
        let data = try SyncCoding.encoder.encode(row)
        #expect(!String(decoding: data, as: UTF8.self).contains("server_updated_at"))
        row.serverUpdatedAt = nil
        #expect(try SyncCoding.decoder.decode(ProjectRow.self, from: data) == row)
    }

    @Test func decodesPostgresDates() throws {
        for s in ["2026-11-25T10:00:00.123456+00:00", "2026-11-25T10:00:00+00:00", "2026-11-25T10:00:00.5Z"] {
            let j = #"{"id":"\#(UUID())","user_id":"\#(uid)","created_at":"\#(s)","kind":"break","payload":{}}"#
            _ = try SyncCoding.decoder.decode(SessionCommandRow.self, from: Data(j.utf8))
        }
    }

    @Test func applyLastWriteWins() throws {
        let p = Project(name: "Local", now: Date(timeIntervalSince1970: 1000))
        var r = Mapping.row(p, userID: uid)
        r.name = "Remote"; r.updatedAt = Date(timeIntervalSince1970: 500)
        #expect(!Mapping.apply(r, to: p)); #expect(p.name == "Local"); #expect(p.syncedAt == nil)
        r.updatedAt = Date(timeIntervalSince1970: 2000)
        #expect(Mapping.apply(r, to: p)); #expect(p.name == "Remote"); #expect(p.syncedAt == r.updatedAt)
        #expect(p.updatedAt == r.updatedAt)
    }

    @Test func sessionChildren() throws {
        let s = SessionRecord(projectID: UUID(), firstTaskID: nil, plannedMin: 30, startedAt: .now,
                              allowData: try JSONEncoder().encode([AllowEntry(.app, "a.b"), AllowEntry(.domain, "x.com")]))
        s.allowAddedData = try JSONEncoder().encode([AllowEntry(.domain, "y.com")])
        s.allowReasons = ["client call"]
        s.eventsData = try JSONEncoder().encode([
            SessionEvent(.offtaskStart, at: .now, detail: ["domain": "z.com"]),
            SessionEvent(.offtaskEnd, at: .now), SessionEvent(.breakStart, at: .now)])
        let (allow, events) = Mapping.sessionChildren(s, userID: uid)
        #expect(allow.count == 3)
        #expect(allow.map(\.addedMidSession) == [false, false, true])
        #expect(allow.map(\.reason) == [nil, nil, "client call"])
        #expect(events.map(\.id) == (0..<3).map { SyncIDs.derived(s.id, "event", $0) })
        #expect(events[0].detail == ["domain": "z.com"])
        #expect(events[1].detail == [:])
        #expect(allow.map(\.id) == [SyncIDs.derived(s.id, "snap", 0), SyncIDs.derived(s.id, "snap", 1), SyncIDs.derived(s.id, "add", 0)])
    }

    @Test func sessionApplySkipsRunning() throws {
        let s = SessionRecord(projectID: UUID(), firstTaskID: nil, plannedMin: 30, startedAt: Date(timeIntervalSince1970: 100), allowData: Data("[]".utf8))
        var r = try #require(Optional(Mapping.row(s, userID: uid)))
        r.updatedAt = Date(timeIntervalSince1970: 9999)
        #expect(!Mapping.apply(r, to: s))
        s.endedAt = Date(timeIntervalSince1970: 200); s.endKind = "completed"
        r.plannedMin = 99
        #expect(Mapping.apply(r, to: s)); #expect(s.plannedMin == 99)
    }

    @Test func insertAllowAttachesToProject() throws {
        let c = try ctx()
        let p = Project(name: "A"); c.insert(p)
        let rule = AllowRule(AllowEntry(.domain, "x.com")); rule.project = p
        let row = Mapping.row(rule, userID: uid)!
        c.delete(rule)
        let made = try #require(Mapping.insert(row, in: c))
        #expect(made.project?.id == p.id)
        #expect(made.syncedAt == row.updatedAt)
        #expect(Mapping.insert(ProjectAllowRow(id: UUID(), userID: uid, updatedAt: .now, projectID: UUID(), kind: "app", value: "x", label: ""), in: c) == nil)
    }

    @Test func stretchesSendNoPlannedLengthAndProjectsCarryNewFields() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let p = Project(name: "Christian Heritage"); p.icon = "building.columns"; p.shortName = "CHL"; p.offMac = true
        c.mainContext.insert(p)
        let r = Mapping.row(p, userID: UUID())
        #expect(r.icon == "building.columns" && r.shortName == "CHL" && r.offMac)
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(json.contains("\"short_name\":\"CHL\"") && json.contains("\"off_mac\":true"))
        let s = SessionRecord(projectID: p.id, firstTaskID: nil, plannedMin: 0, startedAt: .now, allowData: Data("[]".utf8))
        #expect(Mapping.row(s, userID: UUID(), device: "mac").plannedMin == nil)
    }
}
