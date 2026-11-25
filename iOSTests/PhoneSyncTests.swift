import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct PhoneSyncTests {
    static var containers: [ModelContainer] = [] // a context doesn't retain its container; a freed one falls back to the host app's on-disk store
    func ctx() throws -> ModelContext {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.containers.append(c)
        return c.mainContext
    }
    func defaults() -> UserDefaults { UserDefaults(suiteName: "phone-\(UUID())")! }

    @Test func unconfiguredStaysSignedOut() throws {
        let s = PhoneSync(context: try ctx(), defaults: defaults(), info: [:])
        #expect(!s.configured && s.state == .signedOut)
    }

    @Test func wipeEmptiesStoreAndSyncKeys() throws {
        let c = try ctx(), d = defaults()
        let p = Project(name: "Northwind"); c.insert(p)
        let t = TaskItem(title: "Ship"); c.insert(t); t.project = p
        c.insert(PointEvent(at: .now, delta: 5, kind: "focus", refID: nil, note: ""))
        try c.save()
        d.set(1.0, forKey: "sync.watermark.project"); d.set(1.0, forKey: "profileUpdatedAt")
        try PhoneSync.wipe(c, defaults: d)
        #expect(try c.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try c.fetchCount(FetchDescriptor<TaskItem>()) == 0)
        #expect(try c.fetchCount(FetchDescriptor<PointEvent>()) == 0)
        #expect(d.object(forKey: "sync.watermark.project") == nil && d.object(forKey: "profileUpdatedAt") == nil)
    }

    @Test func applyCountsLiveSessionAndPoints() throws {
        let c = try ctx()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
        let p = Project(name: "Northwind"); p.dailyHoursGoal = 1; p.dailyGoalDays = [1, 2, 3, 4, 5, 6, 7]; c.insert(p)
        c.insert(PointEvent(at: noon.addingTimeInterval(-60), delta: 5, kind: "focus", refID: nil, note: ""))
        try c.save()
        let s = PhoneSync(context: c, defaults: defaults(), info: [:])
        let closed = SessionTotalsRow(sessionID: UUID(), projectID: p.id, startedAt: noon.addingTimeInterval(-7200),
                                      endedAt: noon.addingTimeInterval(-6000), focusedSec: 1200, breakSec: 0)
        let run = RunningSession(id: UUID(), projectID: p.id, firstTaskID: nil, plannedMin: 25,
                                 startedAt: noon.addingTimeInterval(-600), lastSeen: noon, events: [])
        s.apply(week: [closed], running: run, now: noon)
        let line = try #require(s.snapshot?.lines.first)
        #expect(line.todayFocusedSec == 1800 && line.dailyGoalSec == 3600)
        #expect(s.snapshot?.pointsToday == 5 + 10) // ledger + 10 provisional focused minutes
        #expect(s.running == run)
    }
}
