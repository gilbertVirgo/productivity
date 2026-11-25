import Foundation
import Testing
import SwiftData
import StintData
@testable import Stint

@MainActor @Suite struct SyncCoordinatorTests {
    func make() throws -> (AppState, Project, ModelContainer) {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let p = Project(name: "Northwind")
        c.mainContext.insert(p)
        try c.mainContext.save()
        return (AppState(context: c.mainContext), p, c)
    }

    @Test func startRunsThenIgnoredWhileRunning() throws {
        let (app, p, keep) = try make(); defer { withExtendedLifetime(keep) {} }
        #expect(SyncCoordinator.perform(.start(projectID: p.id, plannedMin: 25, firstTaskID: nil), on: app))
        #expect(app.isRunning)
        #expect(!SyncCoordinator.perform(.start(projectID: p.id, plannedMin: 25, firstTaskID: nil), on: app))
        #expect(SyncCoordinator.perform(.endEarly(reason: "Client call"), on: app))
        #expect(!app.isRunning)
    }

    @Test func endEarlyRecordsEarly() throws {
        let (app, p, keep) = try make(); defer { withExtendedLifetime(keep) {} }
        _ = SyncCoordinator.perform(.start(projectID: p.id, plannedMin: 25, firstTaskID: nil), on: app)
        let record = try #require(app.record)
        _ = SyncCoordinator.perform(.endEarly(reason: "Client call"), on: app)
        #expect(record.endKind == "early")
    }

    @Test func unknownProjectAndNoSession() throws {
        let (app, p, keep) = try make(); defer { withExtendedLifetime(keep) {} }
        #expect(!SyncCoordinator.perform(.start(projectID: UUID(), plannedMin: 25, firstTaskID: nil), on: app))
        #expect(!SyncCoordinator.perform(.takeBreak, on: app))
        #expect(!SyncCoordinator.perform(.resume, on: app))
        p.archivedAt = .now
        #expect(!SyncCoordinator.perform(.start(projectID: p.id, plannedMin: 25, firstTaskID: nil), on: app))
    }

    @Test func ownerCheckCases() {
        let id = UUID()
        #expect(SyncCoordinator.ownerCheck(stored: nil, current: id) == .claim)
        #expect(SyncCoordinator.ownerCheck(stored: id.uuidString, current: id) == .ok)
        #expect(SyncCoordinator.ownerCheck(stored: UUID().uuidString, current: id) == .mismatch)
    }

    @Test func resetSyncStateMakesEverythingDirty() throws {
        let (_, p, keep) = try make()
        let ctx = keep.mainContext
        p.syncedAt = .now.addingTimeInterval(60)
        let t = Treat(name: "Coffee", cost: 5); t.syncedAt = .now.addingTimeInterval(60); ctx.insert(t)
        ctx.insert(Tombstone(table: "task", rowID: UUID()))
        try ctx.save()
        let d = UserDefaults(suiteName: "reset-\(UUID())")!
        d.set(1.0, forKey: "sync.watermark.project"); d.set(2.0, forKey: "profileUpdatedAt")
        #expect(!p.isDirty)
        try SyncCoordinator.resetSyncState(ctx, defaults: d)
        #expect(p.isDirty && t.isDirty)
        #expect(d.object(forKey: "sync.watermark.project") == nil && d.object(forKey: "profileUpdatedAt") == nil)
        #expect(try ctx.fetch(FetchDescriptor<Tombstone>()).isEmpty)
    }

    @Test func rejectionReasons() {
        let start = SessionCommand.start(projectID: UUID(), plannedMin: 25, firstTaskID: nil)
        #expect(SyncCoordinator.rejectionReason(start, isRunning: true) == "A session is already running on your Mac.")
        #expect(SyncCoordinator.rejectionReason(start, isRunning: false) == "Your Mac doesn't have that project yet. Try again in a minute.")
        #expect(SyncCoordinator.rejectionReason(.takeBreak, isRunning: false) == "No session is running on your Mac.")
        #expect(SyncCoordinator.rejectionReason(nil, isRunning: false) == "Your Mac couldn't read that request. Update Stint on both devices.")
    }
}
