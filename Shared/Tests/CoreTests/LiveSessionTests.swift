import Foundation
import Testing
@testable import Core

@Suite struct LiveSessionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func focusedCountsUpFromFocusedTime() {
        let s = LiveSessionState.make(projectName: "CHL", colorHex: "#2F5FC4", icon: "building.columns", focusedSec: 600,
                                      onBreak: false, offTask: false, paused: false, now: now)
        #expect(s.status == .focused && s.countFrom == 1_800_000_000 - 600)
    }

    @Test func breakPauseAndOffTaskStopTheClock() {
        func make(_ b: Bool, _ o: Bool, _ p: Bool) -> LiveSessionState {
            .make(projectName: "CHL", colorHex: "#000000", icon: nil, focusedSec: 60, onBreak: b, offTask: o, paused: p, now: now)
        }
        #expect(make(true, false, false).status == .onBreak && make(true, false, false).countFrom == nil)
        #expect(make(false, false, true).status == .paused && make(false, false, true).countFrom == nil)
        #expect(make(false, true, false).status == .offTask && make(false, true, false).countFrom == nil)
        #expect(make(true, true, true).status == .onBreak)
    }

    @Test func differsOnProjectStatusOrClockJump() {
        let a = LiveSessionState.make(projectName: "CHL", colorHex: "#000000", icon: nil, focusedSec: 60, onBreak: false, offTask: false, paused: false, now: now)
        var b = a; b.projectName = "Freelance"
        var c = a; c.countFrom = a.countFrom! + 20
        var d = a; d.countFrom = a.countFrom! + 40
        #expect(a.differs(from: b) && !a.differs(from: c) && a.differs(from: d))
        #expect(LiveSessionState.ended(projectName: "CHL", colorHex: "#000000", icon: nil, focusedSec: 60).status == .ended)
    }

    @Test func pushBodyShape() throws {
        let p = LivePush(event: .start, sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                         attributes: LiveSessionInfo(sessionID: "S"),
                         contentState: .ended(projectName: "CHL", colorHex: "#000000", icon: nil, focusedSec: 0))
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let json = String(decoding: try enc.encode(p), as: UTF8.self)
        #expect(json.contains("\"attributes\":{\"sessionID\":\"S\"}"))
        #expect(json.contains("\"projectName\":\"CHL\""))
    }
}

@Suite struct LiveSessionTaskTitleTests {
    @Test func decodesWithoutTaskTitleAndDiffersOnIt() throws {
        let old = ##"{"status":"focused","projectName":"A","colorHex":"#000000","countFrom":100,"focusedSec":5}"##
        let s = try JSONDecoder().decode(LiveSessionState.self, from: Data(old.utf8))
        #expect(s.taskTitle == nil)
        var t = s; t.taskTitle = "Draft"
        #expect(t.differs(from: s))
    }
}
