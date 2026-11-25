import Testing
import Foundation
@testable import StintData

@Suite struct SessionCommandTests {
    func row(_ kind: String, _ p: [String: String] = [:]) -> SessionCommandRow {
        SessionCommandRow(id: UUID(), userID: UUID(), createdAt: .now, kind: kind, payload: p)
    }

    @Test func parsesAllKinds() {
        let p = UUID(), t = UUID()
        #expect(SessionCommand.parse(row("start", ["project_id": p.uuidString, "planned_min": "45", "first_task_id": t.uuidString]))
                == .start(projectID: p, plannedMin: 45, firstTaskID: t))
        #expect(SessionCommand.parse(row("start", ["project_id": p.uuidString, "planned_min": "45"]))
                == .start(projectID: p, plannedMin: 45, firstTaskID: nil))
        #expect(SessionCommand.parse(row("break")) == .takeBreak)
        #expect(SessionCommand.parse(row("resume")) == .resume)
        #expect(SessionCommand.parse(row("end_early_request", ["reason": " tired "])) == .endEarly(reason: "tired"))
    }

    @Test func rejectsBad() {
        let p = UUID().uuidString
        #expect(SessionCommand.parse(row("start", ["project_id": p])) == nil)
        #expect(SessionCommand.parse(row("start", ["project_id": p, "planned_min": "x"])) == nil)
        #expect(SessionCommand.parse(row("start", ["project_id": "nope", "planned_min": "5"])) == nil)
        #expect(SessionCommand.parse(row("end_early_request", ["reason": "  "])) == nil)
        #expect(SessionCommand.parse(row("end_early_request")) == nil)
        #expect(SessionCommand.parse(row("dance")) == nil)
    }

    @Test func wireRoundTrips() {
        let cmds: [SessionCommand] = [
            .start(projectID: UUID(), plannedMin: 50, firstTaskID: UUID()),
            .start(projectID: UUID(), plannedMin: 25, firstTaskID: nil),
            .takeBreak, .resume, .endEarly(reason: "Client call"),
        ]
        for c in cmds {
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

    @MainActor @Test func outcomeUnreachableAfterTenPolls() async {
        var polls = 0
        let pending = row("break", [:])
        #expect(await awaitCommandOutcome(sleep: {}, poll: { polls += 1; return pending }) == .unreachable)
        #expect(polls == 10)
    }

    @MainActor @Test func pollErrorsCountAsPending() async {
        struct Offline: Error {}
        var polls = 0
        let o = await awaitCommandOutcome(sleep: {}, poll: { polls += 1; if polls == 1 { throw Offline() }; return nil })
        #expect(o == .accepted && polls == 2)
    }
}
