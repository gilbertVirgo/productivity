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
}
