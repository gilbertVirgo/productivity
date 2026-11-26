import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@Suite struct AppStateTests {
    @Test func remainingTextFormats() {
        #expect(remainingText(1066) == "17:46")
        #expect(remainingText(0) == "0:00")
        #expect(remainingText(-5) == "0:00")
        #expect(remainingText(1500) == "25:00")
    }

    @Test func hoursMinutesAndMenuTitle() {
        #expect(hoursMinutes(0) == "0:00")
        #expect(hoursMinutes(6120) == "1:42")
        let p = Project(name: "Christian Heritage Ltd")
        #expect(p.menuTitle == "Christian H…")
        p.shortName = "CHL"
        #expect(p.menuTitle == "CHL")
        #expect(initials("Christian Heritage") == "CH")
        #expect(initials("stint") == "S")
    }

    @MainActor @Test func switchingWritesOneRowPerStretch() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "A"), b = Project(name: "B")
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        app.switchTo(a); app.switchTo(b); app.switchToPrevious()
        #expect(app.tracker.currentID == a.id)
        let rows = try c.mainContext.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt)]))
        #expect(rows.map(\.projectID) == [a.id, b.id, a.id])
        #expect(rows.prefix(2).allSatisfy { $0.endKind == "switched" } && rows[2].endedAt == nil)
        app.stop()
    }

    @MainActor @Test func todayNumbersUseTheRealDayWhileStopped() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "A")
        c.mainContext.insert(a); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        app.switchTo(a, at: .now - 120); app.stop()
        app.now = .now - 86400 * 2 // stale clock from the last tick
        #expect(app.focusedToday(a.id) > 0)
        #expect(app.todayStats().focusedSec > 0)
    }

    @MainActor @Test func midnightStopOfAnOffMacProjectStopsMonitoring() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let books = Project(name: "Books"), b = Project(name: "B")
        books.offMac = true
        c.mainContext.insert(books); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        app.switchTo(books, at: Calendar.current.startOfDay(for: .now)) // started this morning
        #expect(app.isTracking && app.isMonitoring)
        app.tick(at: .now + 86400) // crosses midnight: the off-Mac stretch stops itself
        #expect(!app.isTracking && !app.isMonitoring)
        app.switchTo(b)
        #expect(app.isTracking && app.isMonitoring)
        app.stop()
        #expect(!app.isMonitoring)
    }
}
