import Testing
import Foundation
@testable import Core

@Suite struct OffTaskTrackerTests {
    let t0 = date("2026-11-24T16:00:00Z")
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    let figma = "com.figma.desktop"
    let spotify = "com.spotify.client"

    func tracker() -> OffTaskTracker {
        OffTaskTracker(allowlist: Allowlist(entries: [AllowEntry(.app, figma), AllowEntry(.domain, "figma.com")],
                                            ownBundleID: "dev.focus.mac"))
    }

    @Test func onTaskProducesNothing() {
        var t = tracker()
        #expect(t.observe(bundleID: figma, host: nil, at: at(0)).isEmpty)
        #expect(t.tick(at: at(60)).isEmpty)
        #expect(!t.isOffTask)
    }

    @Test func startsAfterGrace() {
        var t = tracker()
        _ = t.observe(bundleID: Browsers.safari, host: "youtube.com", at: at(0))
        #expect(t.tick(at: at(10)).isEmpty)
        #expect(t.tick(at: at(16)) == [.started(at: at(15), bundleID: Browsers.safari, host: "youtube.com")])
        #expect(t.isOffTask)
        #expect(t.tick(at: at(17)).isEmpty)
    }

    @Test func returningWithinGraceLogsNothing() {
        var t = tracker()
        _ = t.observe(bundleID: spotify, host: nil, at: at(0))
        #expect(t.observe(bundleID: figma, host: nil, at: at(10)).isEmpty)
        #expect(t.tick(at: at(30)).isEmpty)
    }

    @Test func returningAfterGraceEnds() {
        var t = tracker()
        _ = t.observe(bundleID: spotify, host: nil, at: at(0))
        _ = t.tick(at: at(15))
        #expect(t.observe(bundleID: figma, host: nil, at: at(40)) == [.ended(at: at(40))])
        #expect(!t.isOffTask)
    }

    @Test func hoppingBetweenOffListAppsKeepsOriginalStart() {
        var t = tracker()
        _ = t.observe(bundleID: spotify, host: nil, at: at(0))
        _ = t.observe(bundleID: Browsers.safari, host: "youtube.com", at: at(8))
        #expect(t.tick(at: at(15)) == [.started(at: at(15), bundleID: spotify, host: nil)])
    }

    @Test func allowEndsOffTask() {
        var t = tracker()
        _ = t.observe(bundleID: Browsers.safari, host: "youtube.com", at: at(0))
        _ = t.tick(at: at(15))
        #expect(t.allow(AllowEntry(.domain, "youtube.com"), at: at(30)) == [.ended(at: at(30))])
        #expect(t.allowlist.entries.contains(AllowEntry(.domain, "youtube.com")))
    }

    @Test func suspendEndsAndResumeRestartsGrace() {
        var t = tracker()
        _ = t.observe(bundleID: spotify, host: nil, at: at(0))
        _ = t.tick(at: at(15))
        #expect(t.setSuspended(true, at: at(20)) == [.ended(at: at(20))])
        #expect(t.tick(at: at(100)).isEmpty)
        #expect(t.setSuspended(false, at: at(200)).isEmpty)
        #expect(t.tick(at: at(210)).isEmpty)
        #expect(t.tick(at: at(215)) == [.started(at: at(215), bundleID: spotify, host: nil)])
    }

    @Test func observeWhileSuspendedIsRememberedForResume() {
        var t = tracker()
        _ = t.setSuspended(true, at: at(0))
        _ = t.observe(bundleID: figma, host: nil, at: at(5))
        _ = t.setSuspended(false, at: at(10))
        #expect(t.tick(at: at(60)).isEmpty)
    }

    @Test func offListObservedWhileSuspendedStartsGraceOnResume() {
        var t = tracker()
        _ = t.setSuspended(true, at: at(0))
        _ = t.observe(bundleID: spotify, host: nil, at: at(5))
        #expect(t.setSuspended(false, at: at(10)).isEmpty)
        #expect(t.tick(at: at(24)).isEmpty)
        #expect(t.tick(at: at(25)) == [.started(at: at(25), bundleID: spotify, host: nil)])
    }
}
