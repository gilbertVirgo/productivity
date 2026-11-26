import Testing
import Foundation
@testable import StintData

@Suite struct SessionCommandTests {
    func row(_ kind: String, _ p: [String: String] = [:]) -> SessionCommandRow {
        SessionCommandRow(id: UUID(), userID: UUID(), createdAt: .now, kind: kind, payload: p)
    }

    @Test func parsesSwitchFirstKinds() {
        let id = UUID()
        #expect(SessionCommand.parse(row("switch", ["project_id": id.uuidString])) == .switchTo(projectID: id))
        #expect(SessionCommand.parse(row("switch", ["project_id": "nope"])) == nil)
        #expect(SessionCommand.parse(row("stop")) == .stop)
        #expect(SessionCommand.parse(row("break_start")) == .breakStart)
        #expect(SessionCommand.parse(row("break_end")) == .breakEnd)
        for old in ["start", "break", "resume", "end_early_request"] { #expect(SessionCommand.parse(row(old)) == .legacy) }
        #expect(SessionCommand.parse(row("dance")) == nil)
        let w = SessionCommand.switchTo(projectID: id).wire
        #expect(w.kind == "switch" && w.payload == ["project_id": id.uuidString])
        for c in [SessionCommand.switchTo(projectID: id), .stop, .breakStart, .breakEnd] {
            let w = c.wire
            #expect(SessionCommand.parse(row(w.kind, w.payload)) == c)
        }
    }

    @MainActor @Test func outcomeAcceptedWhenRowGone() async {
        var polls = 0
        let pending = row("break", [:])
        let o = await awaitCommandOutcome(sleep: {}, poll: { polls += 1; return polls < 3 ? pending : nil })
        #expect(o == .accepted && polls == 3)
    }

    @MainActor @Test func outcomeRejectedCarriesReason() async {
        var r = row("break", [:]); r.rejectedReason = "No session is running on your Mac."
        #expect(await awaitCommandOutcome(sleep: {}, poll: { r }) == .rejected("No session is running on your Mac."))
    }

    @MainActor @Test func outcomeUnreachableAfterFifteenPolls() async {
        var polls = 0
        let pending = row("break", [:])
        #expect(await awaitCommandOutcome(sleep: {}, poll: { polls += 1; return pending }) == .unreachable)
        #expect(polls == 15)
    }

    @MainActor @Test func pollErrorsCountAsPending() async {
        struct Offline: Error {}
        var polls = 0
        let o = await awaitCommandOutcome(sleep: {}, poll: { polls += 1; if polls == 1 { throw Offline() }; return nil })
        #expect(o == .accepted && polls == 2)
    }

    @Test func lenientDecodeStringifiesScalars() throws {
        let p = UUID()
        let json = """
        {"id":"\(UUID())","user_id":"\(UUID())","created_at":"2026-11-25T10:00:00Z","kind":"start",
         "payload":{"project_id":"\(p)","planned_min":25,"x":null,"y":[1],"b":true}}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(SessionCommandRow.self, from: Data(json.utf8))
        #expect(r.payload["planned_min"] == "25")
        #expect(r.payload["x"] == nil && r.payload["y"] == nil)
        #expect(SessionCommand.parse(r) == .legacy)
        let arr = try dec.decode([SessionCommandRow].self, from: Data("[\(json)]".utf8))
        #expect(arr.count == 1)
    }

    @Test func ownerCheckCases() {
        let id = UUID()
        #expect(ownerCheck(stored: nil, current: id) == .claim)
        #expect(ownerCheck(stored: id.uuidString, current: id) == .ok)
        #expect(ownerCheck(stored: UUID().uuidString, current: id) == .mismatch)
    }
}
