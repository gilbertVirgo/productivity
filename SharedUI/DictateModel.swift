import Foundation
import Observation
import SwiftData
import Core
import StintData

/// Live Dictate: rows appear each time the speaker pauses (design 2026-11-26).
@MainActor @Observable
final class DictateModel {
    enum Phase: Equatable { case empty, listening, finishing, review, typing }

    var phase: Phase = .empty
    var transcript = ""
    var rows: [DraftTask] = []
    var sorting = false
    var message: String?
    var projects: [Project] = []
    let speech = SpeechCapture()
    /// Rows changed by hand since the last sort. Recording again re-sorts and drops those edits.
    var edited: Bool { phase == .review && rows != sorted }

    private var sorted: [DraftTask] = []
    @ObservationIgnored private let parse: @MainActor (String, [Project]) async throws -> [ParsedTask]
    @ObservationIgnored private let pause: Duration
    @ObservationIgnored private var gate = ParseGate()
    @ObservationIgnored private var signedOut = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private(set) var pending: Task<Void, Never>?

    init(parse: @escaping @MainActor (String, [Project]) async throws -> [ParsedTask], pause: Duration = .milliseconds(1200)) {
        self.parse = parse; self.pause = pause
        speech.onText = { [weak self] in self?.heard($0) }
        speech.onEnded = { [weak self] in self?.speechEnded() }
    }

    func record() async {
        message = nil; signedOut = false
        await speech.start(base: transcript)
        switch speech.mode {
        case .recording: phase = .listening
        case .unavailable: phase = .typing
        default: break
        }
    }

    func stop() { speech.stop(); if phase == .listening { phase = .finishing } }

    /// Leaving the screen mid-take: stop the mic and sort what was heard.
    func disappear() { speech.cancel(); speechEnded() }

    func toggleTyping() { phase = phase == .typing ? (rows.isEmpty ? .empty : .review) : .typing }

    func makeTasks() { launch(final: true) }

    func startOver() {
        speech.cancel(); timer?.cancel()
        gate = ParseGate(); transcript = ""; rows = []; sorted = []; message = nil; sorting = false; phase = .empty
    }

    func save(in ctx: ModelContext) throws -> Int {
        let n = try VoiceSave.save(rows, projects: projects, in: ctx)
        startOver()
        return n
    }

    func heard(_ text: String) {
        transcript = text
        guard phase == .listening, !signedOut else { return }
        timer?.cancel()
        timer = Task { [weak self, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            self.launch(final: false)
        }
    }

    func speechEnded() {
        timer?.cancel()
        guard phase == .listening || phase == .finishing else { return }
        phase = .finishing
        launch(final: true)
    }

    /// Tests: wait for the pause timer and the sort it started.
    func settled() async { await timer?.value; await pending?.value }
    func settledTimer() async { await timer?.value }

    private func launch(final: Bool) { pending = Task { await sort(final: final) } }

    private func sort(final: Bool) async {
        let text: String
        switch VoiceTasks.check(transcript) {
        case .failure(.empty):
            if final { phase = rows.isEmpty ? .empty : .review }
            return
        case .failure(.tooLong):
            message = "That's over \(VoiceTasks.maxTranscript) characters. Shorten it and try again."
            if final { phase = rows.isEmpty ? .typing : .review }
            return
        case let .success(t): text = t
        }
        guard final || !signedOut, let n = gate.begin(text, force: final) else { return }
        sorting = true
        do {
            let parsed = try await parse(text, projects)
            guard gate.isLatest(n) else { return }
            var next = VoiceTasks.drafts(parsed, projectIDs: Set(projects.map(\.id)))
            message = nil
            if final && next.isEmpty { next = VoiceTasks.fallback(text); message = "No separate tasks found. Edit the one below." }
            show(next)
        } catch {
            gate.failed(n)
            guard gate.isLatest(n) else { return }
            if error is NotSignedIn {
                signedOut = true
                message = final ? "Sign in to sort tasks automatically. Edit the task below." : "Sign in to sort tasks automatically."
            } else {
                message = final ? "Couldn't sort this automatically. Check the tasks below." : "Couldn't sort, will retry when you pause."
            }
            if final && rows.isEmpty { show(VoiceTasks.fallback(text)) }
        }
        sorting = false
        if final { phase = .review }
    }

    /// Keeps row ids by position so a re-sort updates rows in place instead of replacing them.
    private func show(_ next: [DraftTask]) {
        var next = next
        for i in next.indices where i < rows.count { next[i].id = rows[i].id }
        rows = next; sorted = next
    }
}
