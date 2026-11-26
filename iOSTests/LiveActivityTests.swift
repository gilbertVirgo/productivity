import Testing
import Foundation
import Core
@testable import Stint

@Suite struct LiveActivityTests {
    @Test func attributesMatchTheWireShapeTheMacSends() throws {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let a = try enc.encode(StintActivityAttributes(sessionID: "S", projectName: "Northwind", plannedMin: 25))
        let b = try enc.encode(LiveSessionInfo(sessionID: "S", projectName: "Northwind", plannedMin: 25))
        #expect(a == b)
    }

    @Test func planStartsOneActivityAndEndsTheRest() {
        let none = LiveActivities.plan(existing: [], runningSessionID: "A")
        #expect(none.start && none.end.isEmpty)
        let dupes = LiveActivities.plan(existing: [("1", "A"), ("2", "A"), ("3", "B")], runningSessionID: "A")
        #expect(!dupes.start && dupes.end == ["2", "3"])
        let over = LiveActivities.plan(existing: [("1", "A")], runningSessionID: nil)
        #expect(!over.start && over.end == ["1"])
    }

    @Test func hexToken() {
        #expect(Data([0x00, 0xab, 0x10]).hexString == "00ab10")
    }
}
