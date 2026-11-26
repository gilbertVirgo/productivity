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
        #expect(none.start && none.end.isEmpty && none.keep == nil)
        let dupes = LiveActivities.plan(existing: [("1", "A", false), ("2", "A", false), ("3", "B", false)], runningSessionID: "A")
        #expect(!dupes.start && dupes.end == ["2", "3"] && dupes.keep == "1")
        let over = LiveActivities.plan(existing: [("1", "A", false)], runningSessionID: nil)
        #expect(!over.start && over.end == ["1"] && over.keep == nil)
    }

    @Test func planLeavesYoungActivitiesAlone() {
        let young = LiveActivities.plan(existing: [("1", "A", true)], runningSessionID: nil)
        #expect(young.end.isEmpty)
        let forced = LiveActivities.plan(existing: [("1", "A", true)], runningSessionID: nil, force: true)
        #expect(forced.end == ["1"])
        let other = LiveActivities.plan(existing: [("1", "B", true)], runningSessionID: "A")
        #expect(other.start && other.end.isEmpty)
        let keep = LiveActivities.plan(existing: [("1", "B", false), ("2", "A", true), ("3", "A", false)], runningSessionID: "A")
        #expect(keep.keep == "2" && keep.end == ["1", "3"])
    }

    @Test func hexToken() {
        #expect(Data([0x00, 0xab, 0x10]).hexString == "00ab10")
    }
}
