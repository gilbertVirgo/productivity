import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@Suite struct WidgetPlumbingTests {
    @Test func deskLinkMatches() {
        #expect(DeskLink.matches(DeskLink.url))
        #expect(DeskLink.url.absoluteString == "stint://desk")
        #expect(!DeskLink.matches(URL(string: "stint://start?project=\(UUID())")!))
        #expect(!DeskLink.matches(URL(string: "https://desk")!))
    }

    @Test func snapshotFileRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID()).json")
        let s = WidgetSnapshot.build(projects: [], sessions: [], pointsToday: 7, now: .now, calendar: PeriodCalendar(timeZone: .current))
        try SnapshotStore.write(s, to: url)
        #expect(SnapshotStore.read(from: url) == s)
        #expect(SnapshotStore.read(from: url.appending(path: "missing")) == nil)
    }

    @Test func appGroupAvailable() {
        #expect(SnapshotStore.defaultURL != nil)
    }
}
