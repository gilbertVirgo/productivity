import Testing
import Foundation
@testable import Core

@Suite struct SessionEngineTests {
    let t0 = date("2026-11-24T16:00:00Z")
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    let figma = "com.figma.desktop", spotify = "com.spotify.client"

    func engine() -> SessionEngine {
        SessionEngine(startedAt: t0,
                      allowlist: Allowlist(entries: [AllowEntry(.app, figma), AllowEntry(.domain, "figma.com")], ownBundleID: "dev.stint.mac"))
    }

    @Test func offTaskRecordedAsEvents() {
        var e = engine()
        _ = e.observe(bundleID: figma, host: nil, at: at(0))
        _ = e.observe(bundleID: spotify, host: nil, at: at(60))
        #expect(e.tick(at: at(75)) == [.offTaskStarted(bundleID: spotify, host: nil)])
        #expect(e.observe(bundleID: figma, host: nil, at: at(120)) == [.offTaskEnded])
        #expect(e.events == [SessionEvent(.offtaskStart, at: at(75), detail: ["bundle_id": spotify]), SessionEvent(.offtaskEnd, at: at(120))])
        #expect(e.lastOnTaskBundleID == figma)
    }

    @Test func breakSuspendsAndRestartsGrace() {
        var e = engine()
        _ = e.observe(bundleID: spotify, host: nil, at: at(0))
        _ = e.tick(at: at(15))
        #expect(e.setBreak(true, at: at(20)) == [.offTaskEnded])
        #expect(e.tick(at: at(100)).isEmpty)
        #expect(e.setBreak(false, at: at(200)).isEmpty)
        #expect(e.tick(at: at(215)) == [.offTaskStarted(bundleID: spotify, host: nil)])
        #expect(e.events.map(\.type) == [.offtaskStart, .offtaskEnd, .breakStart, .breakEnd, .offtaskStart])
    }

    @Test func combinedSuspensionStaysOnWhileOnBreak() {
        var e = engine()
        _ = e.observe(bundleID: spotify, host: nil, at: at(0))
        _ = e.setIdle(true, at: at(5))
        _ = e.setBreak(true, at: at(6))
        _ = e.setIdle(false, at: at(7))
        #expect(e.tick(at: at(100)).isEmpty)
        #expect(!e.isOffTask)
    }

    @Test func repeatedStateChangeRecordsNothing() {
        var e = engine()
        _ = e.setBreak(false, at: at(5))
        _ = e.setAsleep(false, at: at(5))
        #expect(e.events.isEmpty)
    }

    @Test func allowCurrentUsesDomainForBrowserElseApp() {
        var e = engine()
        _ = e.observe(bundleID: Browsers.safari, host: "www.youtube.com", at: at(0))
        _ = e.tick(at: at(15))
        let r = e.allowCurrent(at: at(30))
        #expect(r?.entry == AllowEntry(.domain, "youtube.com"))
        #expect(r?.signals == [.offTaskEnded])
        _ = e.observe(bundleID: spotify, host: nil, at: at(40))
        #expect(e.allowCurrent(at: at(41))?.entry == AllowEntry(.app, spotify))
        #expect(e.allowAdded.count == 2)
    }

    @Test func closeEndsOpenStatesAtCloseTime() {
        var e = engine()
        _ = e.observe(bundleID: figma, host: nil, at: at(0))
        _ = e.setBreak(true, at: at(1200))
        let r = e.close(at: at(1500))
        #expect(r.events.last == SessionEvent(.breakEnd, at: at(1500)))
        #expect(r.totals == SessionTotals(focusedSec: 1200, breakSec: 300))
    }

    @Test func offtaskStartDetailIncludesDomain() {
        var e = engine()
        _ = e.observe(bundleID: "com.apple.Safari", host: "reddit.com", at: at(0))
        _ = e.tick(at: at(15))
        #expect(e.events.first?.detail == ["bundle_id": "com.apple.Safari", "domain": "reddit.com"])
    }

    @Test func eventWithoutDetailDecodes() throws {
        let json = #"{"type":"break_start","at":0}"#
        let ev = try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        #expect(ev.type == .breakStart && ev.detail == nil)
    }

    @Test func backdatedIdleCountsFromStartOfInactivity() {
        var e = engine()
        _ = e.observe(bundleID: figma, host: nil, at: at(0))
        _ = e.tick(at: at(400))
        _ = e.setIdle(true, at: at(100))
        _ = e.setIdle(false, at: at(500))
        let t = e.totals(at: at(500))
        #expect(t.focusedSec == 100 && t.idleSec == 400)
    }

    @Test func allowCurrentDoesNotDuplicateAddedEntry() {
        var e = engine()
        _ = e.observe(bundleID: spotify, host: nil, at: at(0))
        _ = e.allowCurrent(at: at(1))
        _ = e.allowCurrent(at: at(2))
        #expect(e.allowAdded == [AllowEntry(.app, spotify)])
    }
}
