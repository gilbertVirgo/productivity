import Foundation
import Testing
import StintData
@testable import Stint

@MainActor @Suite struct SwitcherTests {
    @Test func previousFirstThenByName() {
        let a = Project(name: "Admin"), c = Project(name: "Christian Heritage"), f = Project(name: "Freelance")
        let rows = Switcher.order([a, c, f], current: c.id, previous: f.id)
        #expect(rows.map(\.name) == ["Freelance", "Admin", "Christian Heritage"])
        #expect(Switcher.order([a, c, f], current: nil, previous: nil).map(\.name) == ["Admin", "Christian Heritage", "Freelance"])
    }

    @Test func filterMatchesNameOrShortName() {
        let c = Project(name: "Christian Heritage"); c.shortName = "CHL"
        let s = Project(name: "Sermon prep")
        #expect(Switcher.filter([c, s], query: "chl").map(\.name) == ["Christian Heritage"])
        #expect(Switcher.filter([c, s], query: "SER").map(\.name) == ["Sermon prep"])
        #expect(Switcher.filter([c, s], query: " ").count == 2)
    }

    @Test func doublePressFlipsBack() {
        #expect(Switcher.pressAction(sinceLast: nil, isOpen: false) == .open)
        #expect(Switcher.pressAction(sinceLast: 0.3, isOpen: true) == .flipBack)
        #expect(Switcher.pressAction(sinceLast: 0.6, isOpen: true) == .close)
        #expect(Switcher.pressAction(sinceLast: 0.3, isOpen: false) == .open)
    }
}
