import Foundation
import Testing
@testable import Core

@Suite struct TrackerTests {
    let utc = PeriodCalendar(timeZone: TimeZone(identifier: "UTC")!)
    let t0 = ISO8601DateFormatter().date(from: "2026-11-26T10:00:00Z")!
    let a = TrackedProject(id: UUID(), allowlist: Allowlist(entries: [AllowEntry(.app, "com.microsoft.VSCode")], ownBundleID: "dev.stint.mac"))
    let b = TrackedProject(id: UUID(), allowlist: Allowlist(entries: [AllowEntry(.domain, "figma.com")], ownBundleID: "dev.stint.mac"))

    func ended(_ out: [Tracker.Output]) -> [StretchResult] {
        out.compactMap { if case let .ended(r) = $0 { r } else { nil } }
    }

    @Test func switchEndsTheOldStretchAndStartsTheNext() {
        var t = Tracker(calendar: utc)
        #expect(t.switchTo(a, at: t0) == [.started(projectID: a.id, at: t0)])
        let out = t.switchTo(b, at: t0 + 120)
        let r = ended(out)
        #expect(r.count == 1 && r[0].projectID == a.id && r[0].end == .switched && r[0].endedAt == t0 + 120)
        #expect(r[0].totals.focusedSec == 120)
        #expect(out.last == .started(projectID: b.id, at: t0 + 120))
        #expect(t.currentID == b.id && t.previousID == a.id)
    }

    @Test func switchingToTheCurrentProjectDoesNothing() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        #expect(t.switchTo(a, at: t0 + 60).isEmpty)
    }

    @Test func stopEndsWithStoppedAndRemembersThePrevious() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        let r = ended(t.stop(at: t0 + 60))
        #expect(r.first?.end == .stopped)
        #expect(!t.isTracking && t.previousID == a.id)
        #expect(t.stop(at: t0 + 70).isEmpty)
    }

    @Test func aBreakEndsWhenYouSwitch() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        _ = t.setBreak(true, at: t0 + 60)
        let r = ended(t.switchTo(b, at: t0 + 120))
        #expect(r[0].totals.breakSec == 60)
        #expect(!t.onBreak)
    }

    @Test func midnightSplitsTheStretch() {
        var t = Tracker(calendar: utc)
        let late = ISO8601DateFormatter().date(from: "2026-11-26T23:50:00Z")!
        let midnight = ISO8601DateFormatter().date(from: "2026-11-27T00:00:00Z")!
        _ = t.switchTo(a, at: late)
        let out = t.tick(at: midnight + 300)
        #expect(ended(out).first?.endedAt == midnight)
        #expect(ended(out).first?.end == .switched)
        #expect(out.contains(.started(projectID: a.id, at: midnight)))
        #expect(t.engine?.startedAt == midnight && t.previousID == nil)
    }

    @Test func offMacIgnoresIdleAndStopsAtMidnight() {
        var t = Tracker(calendar: utc)
        var books = a; books.offMac = true
        let late = ISO8601DateFormatter().date(from: "2026-11-26T23:00:00Z")!
        _ = t.switchTo(books, at: late)
        _ = t.setIdle(true, at: late + 600)
        _ = t.observe(bundleID: "com.spotify.client", host: nil, at: late + 600)
        #expect(t.engine?.idle == false && !t.isOffTask)
        let r = ended(t.tick(at: late + 7200))
        #expect(r.first?.end == .stopped && r.first?.totals.focusedSec == 3600)
        #expect(!t.isTracking)
    }

    @Test func aStretchStartedWhileIdleBeginsIdle() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        _ = t.setIdle(true, at: t0 + 10)
        _ = t.switchTo(b, at: t0 + 20)
        #expect(t.engine?.idle == true)
    }

    @Test func aBackdatedSwitchDropsLaterEvents() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        _ = t.observe(bundleID: "com.apple.safari", host: "figma.com", at: t0 + 100)
        _ = t.tick(at: t0 + 116) // off-task from t0 + 115
        let r = ended(t.switchTo(b, at: t0 + 100))
        #expect(r[0].endedAt == t0 + 100)
        #expect(r[0].events.allSatisfy { $0.at <= t0 + 100 })
        #expect(r[0].totals.offtaskSec == 0)
        #expect(t.engine?.startedAt == t0 + 100 && !t.isOffTask)
    }
}
