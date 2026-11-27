import Foundation
import Testing
import SwiftData
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

    @Test func rowsPutCardsFirstAndCapAtNine() throws {
        let container = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let c = container.mainContext
        let ser = Project(name: "Sermon prep"), nw = Project(name: "Northwind")
        c.insert(ser); c.insert(nw)
        let card = TaskItem(title: "Outline Romans 8"); c.insert(card); card.project = ser
        let rows = Switcher.rows(cards: [card], projects: [nw, ser], query: "")
        #expect(rows.map(\.id) == [card.id, nw.id, ser.id])
        #expect(Switcher.rows(cards: [card], projects: [nw, ser], query: "north").map(\.id) == [nw.id])
        #expect(Switcher.rows(cards: [card], projects: [nw, ser], query: "sermon").map(\.id) == [card.id, ser.id]) // card matches by project
        let many = (0..<12).map { i -> Project in let p = Project(name: "P\(i)"); c.insert(p); return p }
        #expect(Switcher.rows(cards: [card], projects: many, query: "").count == 9)
        withExtendedLifetime(container) {}
    }
}
