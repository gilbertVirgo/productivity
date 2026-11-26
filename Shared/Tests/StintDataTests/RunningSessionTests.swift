import Testing
import Foundation
import Core
@testable import StintData

@Suite struct RunningSessionTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Int) -> Date { start.addingTimeInterval(TimeInterval(s)) }
    func make(_ events: [SessionEvent]) -> RunningSession {
        RunningSession(id: UUID(), projectID: UUID(), firstTaskID: nil, startedAt: start, lastSeen: at(600), events: events)
    }

    @Test func summaryExcludesBreakFromFocus() {
        let r = make([SessionEvent(.breakStart, at: at(300)), SessionEvent(.breakEnd, at: at(420))])
        #expect(r.summary(at: at(600)).focusedSec == 480 && r.summary(at: at(600)).breakSec == 120)
        #expect(!r.onBreak)
    }

    @Test func openStatesShow() {
        let r = make([SessionEvent(.offtaskStart, at: at(100)), SessionEvent(.breakStart, at: at(200))])
        #expect(r.onBreak && r.offTask)
        #expect(!make([SessionEvent(.offtaskStart, at: at(100)), SessionEvent(.offtaskEnd, at: at(150))]).offTask)
    }

    @Test func staleAfterTwoMinutesWithoutCheckpoint() {
        #expect(!make([]).isStale(at: at(600 + 119)))
        #expect(make([]).isStale(at: at(600 + 121)))
    }

    @Test func rowInitDropsUnknownEventTypes() {
        let row = SessionRow(id: UUID(), userID: UUID(), createdAt: start, updatedAt: at(30), projectID: UUID(), firstTaskID: nil,
                             plannedMin: 50, startedAt: start, endedAt: nil, endKind: nil, earlyReason: nil, device: "mac")
        let ev = { (t: String) in SessionEventRow(id: UUID(), userID: row.userID, sessionID: row.id, at: self.at(10), type: t) }
        let r = RunningSession(row: row, events: [ev("break_start"), ev("bogus")])
        #expect(r.events == [SessionEvent(.breakStart, at: at(10))])
        #expect(r.lastSeen == at(30))
    }

    @Test func totalsRowDecodesNullEnd() throws {
        let json = #"[{"session_id":"\#(UUID())","project_id":"\#(UUID())","started_at":"2026-11-24T09:00:00+00:00","ended_at":null,"focused_sec":60,"break_sec":0}]"#
        let rows = try SyncCoding.decoder.decode([SessionTotalsRow].self, from: Data(json.utf8))
        #expect(rows.first?.endedAt == nil && rows.first?.summary.focusedSec == 60)
    }
}
