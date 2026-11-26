import Testing
import Foundation
@testable import Core

@Suite struct SessionAccountingTests {
    let start = date("2026-11-24T16:00:00Z")
    func at(_ min: Double) -> Date { start.addingTimeInterval(min * 60) }

    @Test func noEventsIsAllFocused() {
        let t = sessionTotals(start: start, end: at(50), events: [])
        #expect(t == SessionTotals(focusedSec: 3000))
    }

    @Test func offTaskStretch() {
        let t = sessionTotals(start: start, end: at(50), events: [
            SessionEvent(.offtaskStart, at: at(10)), SessionEvent(.offtaskEnd, at: at(15)),
        ])
        #expect(t == SessionTotals(focusedSec: 2700, offtaskSec: 300))
    }

    @Test func breakDoesNotUseUpPlannedLength() {
        let t = sessionTotals(start: start, end: at(60), events: [
            SessionEvent(.breakStart, at: at(20)), SessionEvent(.breakEnd, at: at(30)),
        ])
        #expect(t == SessionTotals(focusedSec: 3000, breakSec: 600))
        #expect(t.focusedSec + t.offtaskSec == 3000)
    }

    @Test func idleBeatsOffTask() {
        let t = sessionTotals(start: start, end: at(50), events: [
            SessionEvent(.offtaskStart, at: at(10)),
            SessionEvent(.idleStart, at: at(12)),
            SessionEvent(.idleEnd, at: at(15)),
            SessionEvent(.offtaskEnd, at: at(15)),
        ])
        #expect(t == SessionTotals(focusedSec: 2700, offtaskSec: 120, idleSec: 180))
    }

    @Test func breakBeatsSleep() {
        let t = sessionTotals(start: start, end: at(60), events: [
            SessionEvent(.breakStart, at: at(10)),
            SessionEvent(.sleep, at: at(12)),
            SessionEvent(.wake, at: at(20)),
            SessionEvent(.breakEnd, at: at(22)),
        ])
        #expect(t == SessionTotals(focusedSec: 2880, breakSec: 720))
    }

    @Test func openStateRunsToEnd() {
        let t = sessionTotals(start: start, end: at(50), events: [SessionEvent(.offtaskStart, at: at(45))])
        #expect(t == SessionTotals(focusedSec: 2700, offtaskSec: 300))
    }

    @Test func eventsOutsideWindowIgnoredAndOrderDoesNotMatter() {
        let t = sessionTotals(start: start, end: at(50), events: [
            SessionEvent(.offtaskEnd, at: at(15)),
            SessionEvent(.offtaskStart, at: at(10)),
            SessionEvent(.breakStart, at: at(70)),
        ])
        #expect(t == SessionTotals(focusedSec: 2700, offtaskSec: 300))
    }

    @Test func fractionalSecondsStillSumExactly() {
        let t = sessionTotals(start: start, end: start.addingTimeInterval(3000), events: [
            SessionEvent(.offtaskStart, at: start.addingTimeInterval(100.3)),
            SessionEvent(.offtaskEnd, at: start.addingTimeInterval(200.6)),
        ])
        #expect(t.focusedSec + t.offtaskSec == 3000)
    }

    @Test func endBeforeStartIsEmpty() {
        #expect(sessionTotals(start: at(10), end: at(5), events: []) == SessionTotals())
    }

    @Test func sameTimestampStartSortsBeforeEnd() {
        let t = sessionTotals(start: start, end: at(50), events: [
            SessionEvent(.offtaskEnd, at: at(15)), SessionEvent(.offtaskStart, at: at(15)),
        ])
        #expect(t == SessionTotals(focusedSec: 3000))
    }

    @Test func rawValuesMatchDatabase() {
        let expected: [SessionEventType: String] = [
            .offtaskStart: "offtask_start", .offtaskEnd: "offtask_end", .breakStart: "break_start",
            .breakEnd: "break_end", .idleStart: "idle_start", .idleEnd: "idle_end", .sleep: "sleep", .wake: "wake",
        ]
        #expect(expected.count == 8)
        for (k, v) in expected { #expect(k.rawValue == v) }
    }
}
