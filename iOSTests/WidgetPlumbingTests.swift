import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@Suite struct WidgetPlumbingTests {
    @Test func startLinkRoundTrips() {
        let id = UUID()
        #expect(StartLink.parse(StartLink.url(projectID: id)) == id)
        #expect(StartLink.parse(URL(string: "stint://today")!) == nil)
        #expect(StartLink.parse(URL(string: "https://start?project=\(id)")!) == nil)
        #expect(StartLink.parse(URL(string: "stint://start?project=nope")!) == nil)
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

    /// Cold launch: the URL can arrive before sign-in resumes, so the start waits instead of being dropped.
    @MainActor @Test func startBeforeSignInStaysPending() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let s = PhoneSync(context: c.mainContext, defaults: UserDefaults(suiteName: "phone-\(UUID())")!, info: [:])
        let id = UUID()
        s.openStart(id)
        #expect(s.pendingStart == id)
    }
}
