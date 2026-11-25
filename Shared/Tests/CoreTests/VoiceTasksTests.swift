import Testing
import Foundation
@testable import Core

@Suite struct VoiceTasksTests {
    let a = UUID(), b = UUID()

    @Test func checkTrimsAndLimitsByScalars() {
        #expect(VoiceTasks.check("  call bank \n") == .success("call bank"))
        #expect(VoiceTasks.check("   ") == .failure(.empty))
        #expect(VoiceTasks.check(String(repeating: "é", count: 4000)) == .success(String(repeating: "é", count: 4000)))
        #expect(VoiceTasks.check(String(repeating: "a", count: 4001)) == .failure(.tooLong))
    }

    @Test func decodesWireShape() throws {
        let json = #"[{"title":"Send invoice","project_id":"\#(a.uuidString)","estimate_min":15,"estimate_guessed":false},{"title":"Call bank","project_id":null,"estimate_min":null,"estimate_guessed":false}]"#
        let p = try JSONDecoder().decode([ParsedTask].self, from: Data(json.utf8))
        #expect(p == [ParsedTask(title: "Send invoice", projectID: a, estimateMin: 15, estimateGuessed: false),
                      ParsedTask(title: "Call bank", projectID: nil, estimateMin: nil, estimateGuessed: false)])
    }

    @Test func draftsAreCheckedAndDropUnknownProjectsAndEmptyTitles() {
        let d = VoiceTasks.drafts([
            ParsedTask(title: "A", projectID: a, estimateMin: 30, estimateGuessed: true),
            ParsedTask(title: " ", projectID: a, estimateMin: nil, estimateGuessed: false),
            ParsedTask(title: "B", projectID: UUID(), estimateMin: nil, estimateGuessed: false),
        ], projectIDs: [a, b])
        #expect(d.map(\.title) == ["A", "B"])
        #expect(d.map(\.projectID) == [a, nil])
        #expect(d.allSatisfy { $0.checked })
        #expect(d[0].estimateMin == 30 && d[0].estimateGuessed)
    }

    @Test func fallbackIsOneUncheckedProjectTask() {
        let d = VoiceTasks.fallback("  email Sam about the logo  ")
        #expect(d.count == 1)
        #expect(d[0].title == "email Sam about the logo" && d[0].projectID == nil && d[0].checked && d[0].estimateMin == nil)
        #expect(VoiceTasks.fallback(String(repeating: "x", count: 500))[0].title.count == 200)
    }

    @Test func canSaveNeedsACheckedTaskAndProjectsOnEveryCheckedTask() {
        var d = VoiceTasks.drafts([ParsedTask(title: "A", projectID: a, estimateMin: nil, estimateGuessed: false),
                                   ParsedTask(title: "B", projectID: nil, estimateMin: nil, estimateGuessed: false)], projectIDs: [a])
        #expect(!VoiceTasks.canSave(d))              // B has no project
        d[1].checked = false
        #expect(VoiceTasks.canSave(d) && VoiceTasks.checkedCount(d) == 1)
        d[0].title = "  "
        #expect(!VoiceTasks.canSave(d))              // empty title
        d[0].checked = false
        #expect(!VoiceTasks.canSave(d))              // nothing checked
    }
}
