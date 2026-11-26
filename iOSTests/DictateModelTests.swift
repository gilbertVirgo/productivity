import Foundation
import Testing
import Core
import StintData
@testable import Stint

@MainActor final class FakeParse {
    var calls: [String] = []
    var hold: Set<String> = []
    var fail: (any Error)?
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    /// One task per sentence ("A. B" → A, B).
    func run(_ text: String, _ projects: [Project]) async throws -> [ParsedTask] {
        calls.append(text)
        if hold.contains(text) { await withCheckedContinuation { waiting[text] = $0 } }
        if let fail { throw fail }
        return text.split(separator: ".").map {
            ParsedTask(title: $0.trimmingCharacters(in: .whitespaces), projectID: nil, estimateMin: 10, estimateGuessed: true)
        }
    }
    func release(_ text: String) { waiting.removeValue(forKey: text)?.resume() }
}

@MainActor @Suite struct DictateModelTests {
    let fake = FakeParse()
    let model: DictateModel

    init() {
        let fake = fake
        model = DictateModel(parse: { try await fake.run($0, $1) }, pause: .zero)
        model.phase = .listening
    }

    func titles() -> [String] { model.rows.map(\.title) }

    @Test func pauseShowsRows() async {
        model.heard("Buy milk. Call Bob")
        await model.settled()
        #expect(titles() == ["Buy milk", "Call Bob"])
        #expect(model.phase == .listening)
    }

    @Test func laterPauseReplacesRowsAndSameTextIsNotResent() async {
        model.heard("A"); await model.settled()
        model.heard("A"); await model.settled()
        #expect(fake.calls == ["A"])
        let firstID = model.rows[0].id
        model.heard("A. B"); await model.settled()
        #expect(titles() == ["A", "B"])
        #expect(model.rows[0].id == firstID) // stable ids, no flicker
    }

    @Test func staleAnswerIsIgnored() async {
        fake.hold = ["Slow"]
        model.heard("Slow"); await model.settledTimer()
        let slow = model.pending
        model.heard("Fast. Done"); await model.settled()
        fake.release("Slow"); await slow?.value
        #expect(titles() == ["Fast", "Done"])
        #expect(!model.sorting)
    }

    @Test func stopRunsFinalSortThenReview() async {
        model.heard("A"); await model.settled()
        model.speechEnded(); await model.settled()
        #expect(fake.calls == ["A", "A"])
        #expect(model.phase == .review)
    }

    @Test func failedFinalWithNoRowsFallsBack() async {
        fake.fail = URLError(.notConnectedToInternet)
        model.transcript = "Buy milk"
        model.speechEnded(); await model.settled()
        #expect(titles() == ["Buy milk"])
        #expect(model.phase == .review)
        #expect(model.message != nil)
    }

    @Test func failedLiveSortKeepsRows() async {
        model.heard("A"); await model.settled()
        fake.fail = URLError(.timedOut)
        model.heard("A. B"); await model.settled()
        #expect(titles() == ["A"])
        #expect(model.message == "Couldn't sort, will retry when you pause.")
    }

    @Test func signedOutStopsLiveSorting() async {
        fake.fail = NotSignedIn()
        model.heard("A"); await model.settled()
        model.heard("A. B"); await model.settled()
        #expect(fake.calls == ["A"])
        model.speechEnded(); await model.settled()
        #expect(titles() == ["A. B"]) // fallback row
    }

    @Test func editingInReviewSetsEdited() async {
        model.heard("A"); await model.settled()
        model.speechEnded(); await model.settled()
        #expect(!model.edited)
        model.rows[0].title = "Changed"
        #expect(model.edited)
    }
}
