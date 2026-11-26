import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct SuggestTests {
    @Test func acceptBackdatesAndUndoGoesBack() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "CHL"), b = Project(name: "Freelance")
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        app.switchTo(a)
        let since = Date().addingTimeInterval(-12)
        app.suggestion = SwitchSuggester.Suggestion(projectID: b.id, since: since, bundleID: "com.apple.safari", host: "figma.com")
        app.acceptSuggestion()
        #expect(app.tracker.currentID == b.id && app.suggestion == nil)
        let bRow = try #require(app.record)
        #expect(bRow.startedAt == max(since, bRow.startedAt))
        #expect(app.undo?.fromID == a.id)
        app.undoSwitch()
        #expect(app.tracker.currentID == a.id && app.undo == nil)
        app.stop()
    }

    @Test func stayDismissesWithoutSwitching() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "CHL"), b = Project(name: "Freelance")
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        app.switchTo(a)
        app.suggestion = SwitchSuggester.Suggestion(projectID: b.id, since: .now, bundleID: "com.apple.safari", host: "figma.com")
        app.staySuggestion()
        #expect(app.tracker.currentID == a.id && app.suggestion == nil)
        app.stop()
    }
}
