import Testing
import Foundation
import Core
@testable import Stint

@Suite struct LiveActivityTests {
    @Test func attributesMatchTheWireShapeTheMacSends() throws {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let a = try enc.encode(StintActivityAttributes(sessionID: "S"))
        let b = try enc.encode(LiveSessionInfo(sessionID: "S"))
        #expect(a == b)
    }

    @Test func planStartsOneActivityAndEndsTheRest() {
        let none = LiveActivities.plan(existing: [], running: true)
        #expect(none.start && none.end.isEmpty && none.keep == nil)
        let dupes = LiveActivities.plan(existing: [("1", false), ("2", false)], running: true)
        #expect(!dupes.start && dupes.end == ["2"] && dupes.keep == "1")
        let over = LiveActivities.plan(existing: [("1", false), ("2", false)], running: false)
        #expect(!over.start && over.end == ["1", "2"] && over.keep == nil)
    }

    @Test func planLeavesYoungActivitiesAlone() {
        let young = LiveActivities.plan(existing: [("1", true)], running: false)
        #expect(young.end.isEmpty)
        let forced = LiveActivities.plan(existing: [("1", true)], running: false, force: true)
        #expect(forced.end == ["1"])
    }

    @Test func deadKeptActivityIsNotPreferred() {
        #expect(LiveActivities.tokenID(kept: "1", arrived: "2", active: ["2"]) == "2")
        #expect(LiveActivities.tokenID(kept: "1", arrived: "2", active: ["1", "2"]) == "1")
        #expect(LiveActivities.tokenID(kept: nil, arrived: "2", active: ["2"]) == "2")
    }

    @Test func hexToken() {
        #expect(Data([0x00, 0xab, 0x10]).hexString == "00ab10")
    }
}
