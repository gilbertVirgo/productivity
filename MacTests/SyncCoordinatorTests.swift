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
        let (app, _, keep) = try make(); defer { withExtendedLifetime(keep) {} }
        #expect(!SyncCoordinator.perform(.start(projectID: UUID(), plannedMin: 25, firstTaskID: nil), on: app))
        #expect(!SyncCoordinator.perform(.takeBreak, on: app))
        #expect(!SyncCoordinator.perform(.resume, on: app))
    }
}
