import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct LivePushTests {
    @Test func oneRunStartsUpdatesOnSwitchAndBreakThenEnds() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "Northwind"), b = Project(name: "CHL")
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        var got: [LivePush] = []
        app.onLive = { got.append($0) }

        app.switchTo(a)
        let first = try #require(got.first)
        #expect(first.event == .start && first.contentState.projectName == "Northwind")
        #expect(first.attributes == LiveSessionInfo(sessionID: first.sessionID.uuidString))
        app.takeBreak()
        #expect(got.last?.event == .update && got.last?.contentState.status == .onBreak)
        app.resume()
        #expect(got.last?.event == .update && got.last?.contentState.countFrom != nil)
        app.switchTo(b)
        #expect(got.last?.event == .update && got.last?.contentState.projectName == "CHL")
        let lastID = try #require(app.record?.id)
        app.stop()
        #expect(got.last?.sessionID == lastID)
        #expect(got.last?.event == .end && got.last?.contentState.status == .ended)
        #expect(got.filter { $0.event == .start }.count == 1)
        _ = c
    }
}
