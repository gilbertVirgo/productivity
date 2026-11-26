import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct LivePushTests {
    @Test func startBreakResumeEndPushInOrder() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let p = Project(name: "Northwind"); c.mainContext.insert(p); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        var got: [LivePush] = []
        app.onLive = { got.append($0) }

        app.start(project: p, plannedMin: 25, firstTask: nil)
        let first = try #require(got.first)
        #expect(first.event == .start)
        #expect(first.attributes == LiveSessionInfo(sessionID: first.sessionID.uuidString))

        app.takeBreak()
        let onBreak = try #require(got.last)
        #expect(onBreak.event == .update && onBreak.contentState.status == .onBreak && onBreak.contentState.countFrom == nil)

        app.resume()
        let back = try #require(got.last)
        #expect(back.event == .update && back.contentState.status != .onBreak && back.contentState.countFrom != nil)

        app.endEarly(reason: "test")
        let end = try #require(got.last)
        #expect(end.event == .end && end.contentState.status == .ended)
        #expect(got.allSatisfy { $0.sessionID == first.sessionID })
        #expect(got.filter { $0.event == .start }.count == 1)
        _ = c
    }
}
