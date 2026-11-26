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
}
