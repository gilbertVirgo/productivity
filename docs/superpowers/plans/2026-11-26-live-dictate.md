# Live Dictate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Dictate screen where task rows (title, project, estimate) appear on each speech pause, a level-driven listening orb, rows editable after Stop, saved with "Add N tasks".

**Architecture:** `SpeechCapture` reports text and end-of-take through callbacks and exposes mic `level`. A new `@Observable DictateModel` owns phase/rows, debounces transcript changes (1.2 s) into full-transcript `parse-tasks` calls, and keeps only the newest answer via a pure `ParseGate` (Core). `DictateView` becomes layout only.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Speech/AVFoundation, swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-26-live-dictate-design.md`

## Global Constraints

- Pause delay 1.2 s (`.milliseconds(1200)`), injectable for tests.
- `parse-tasks`, `VoiceSave`, iOS/Mac hosts unchanged. `DictateView(parse:onSaved:)` signature unchanged.
- Transcript limit: `VoiceTasks.maxTranscript` (4000 scalars).
- Copy: hint "Say what you need to do. Name the project if you can."; live failure "Couldn't sort, will retry when you pause."; re-sort note "Recording again will re-sort your tasks."
- Work on `main`, stage only own files, commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Run xcodebuild/swift with sandbox disabled; delete `/private/tmp/claude-501/dd-*` after use.

---

### Task 1: ParseGate + stable DraftTask ids (Core)

**Files:**
- Create: `Shared/Sources/Core/ParseGate.swift`
- Modify: `Shared/Sources/Core/VoiceTasks.swift` (`DraftTask.id` `let` → `var`)
- Test: `Shared/Tests/CoreTests/ParseGateTests.swift`

**Interfaces:**
- Produces: `public struct ParseGate { init(); mutating func begin(_ text: String, force: Bool = false) -> Int?; func isLatest(_ n: Int) -> Bool; mutating func failed(_ n: Int) }`; `DraftTask.id` settable (positional id reuse keeps rows from flickering on re-sort).

- [ ] **Step 1: failing tests**

```swift
import Testing
@testable import Core

@Suite struct ParseGateTests {
    @Test func sameTextSendsOnce() {
        var g = ParseGate()
        #expect(g.begin("a") == 1)
        #expect(g.begin("a") == nil)
        #expect(g.begin("a b") == 2)
        #expect(g.begin("a b", force: true) == 3)
    }

    @Test func onlyNewestIsLatest() {
        var g = ParseGate()
        let old = g.begin("a")!, new = g.begin("a b")!
        #expect(!g.isLatest(old))
        #expect(g.isLatest(new))
    }

    @Test func failedNewestCanBeResent() {
        var g = ParseGate()
        let n = g.begin("a")!
        g.failed(n)
        #expect(g.begin("a") == 2)
        let stale = 1
        g.failed(stale) // an older failure doesn't reopen the newest text
        #expect(g.begin("a") == nil)
    }
}
```

- [ ] **Step 2:** `cd Shared && swift test --disable-sandbox --filter ParseGate` → FAIL (no `ParseGate`).
- [ ] **Step 3: implement**

```swift
/// Picks which `parse-tasks` answer to show while dictating: each request gets a number, only the newest
/// is shown, and the same text isn't sent twice in a row (unless forced, e.g. the final sort on Stop).
public struct ParseGate: Sendable {
    private var sent = 0
    private var lastText: String?
    public init() {}

    public mutating func begin(_ text: String, force: Bool = false) -> Int? {
        guard force || text != lastText else { return nil }
        lastText = text; sent += 1
        return sent
    }

    public func isLatest(_ n: Int) -> Bool { n == sent }

    /// A failed newest request lets the same text be sent again.
    public mutating func failed(_ n: Int) { if n == sent { lastText = nil } }
}
```
And in `VoiceTasks.swift`: `public let id: UUID` → `public var id: UUID`.

- [ ] **Step 4:** rerun → PASS; full `swift test --disable-sandbox` green.
- [ ] **Step 5:** commit `feat(voice): ParseGate for live dictation sorting`.

### Task 2: SpeechCapture callbacks + level

**Files:** Modify `SharedUI/SpeechCapture.swift`.

**Interfaces:**
- Produces: `var level: Float` (0…1); `var onText: ((String) -> Void)?`; `var onEnded: (() -> Void)?` (called when a take ends by Stop, timeout, or recognizer ending — not by `cancel()`); `func start(base: String) async`. Removes `transcript` and `canEdit`.

- [ ] **Step 1:** Replace `var transcript` / `canEdit` with `level`, `onText`, `onEnded` (`@ObservationIgnored` for callbacks).
- [ ] **Step 2:** `start()` → `start(base: String)`; accumulator `TranscriptAccumulator(base: base)`; handler calls `self.onText?(text.text)`; done → `self.finish(notify: true)`.
- [ ] **Step 3:** tap computes level:

```swift
nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest,
                                    level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
    { buffer, _ in req.append(buffer); level(Self.level(buffer)) }
}

/// RMS mapped from -50…-10 dBFS to 0…1.
nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    let n = Int(buffer.frameLength)
    var sum: Float = 0
    for i in 0..<n { sum += ch[i] * ch[i] }
    let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-6))
    return min(1, max(0, (db + 50) / 40))
}
```
installed with `Self.tap(req) { [weak self] v in Task { @MainActor in self?.level = v } }`.
- [ ] **Step 4:** `stop()` timeout → `finish(notify: true)`; `cancel()` → `finish(notify: false)`; `finish(notify:)` sets `level = 0`, `mode = .idle`, then `if notify { onEnded?() }`.
- [ ] **Step 5:** compiles in Task 4's build (DictateView still uses old API until then — do Tasks 2–4 before building).

### Task 3: DictateModel

**Files:**
- Create: `SharedUI/DictateModel.swift`
- Test: `iOSTests/DictateModelTests.swift`

**Interfaces:**
- Consumes: `ParseGate`, `VoiceTasks.drafts/fallback/check`, `VoiceSave.save`, `SpeechCapture.start(base:)/stop()/cancel()/onText/onEnded/mode`, `NotSignedIn`.
- Produces: `@MainActor @Observable final class DictateModel { enum Phase { empty, listening, finishing, review, typing }; var phase; var transcript; var rows: [DraftTask]; var sorting; var message: String?; var projects: [Project]; let speech: SpeechCapture; var edited: Bool; init(parse:pause:); func record() async; func stop(); func disappear(); func toggleTyping(); func makeTasks(); func startOver(); func save(in: ModelContext) throws -> Int; func heard(_:); func speechEnded(); func settled() async }`.

- [ ] **Step 1: failing tests** (`iOSTests/DictateModelTests.swift`)

```swift
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
```
(`settledTimer()` awaits only the pause timer, not the sort it starts.)

- [ ] **Step 2:** iOS test run → FAIL (no `DictateModel`).
- [ ] **Step 3: implement** `SharedUI/DictateModel.swift`:

```swift
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
```

- [ ] **Step 4:** iOS tests → PASS (after Task 4 compiles the view).
- [ ] **Step 5:** commit with Task 4.

### Task 4: DictateView layout + ListeningOrb

**Files:** Rewrite `SharedUI/DictateView.swift`.

- [ ] **Step 1:** `DictateView` keeps `init(parse:onSaved:)`; `@State private var model: DictateModel` built in init. Layout: rows area (empty hint / List of live or editable rows with "Sorting…"), messages (`model.message`, unavailable reason, re-sort note when `model.edited`), caption (`transcript`, `lineLimit(2)`, `truncationMode(.head)`) or typing box (TextEditor + "Make tasks"), bottom bar (ZStack: centred `ListeningOrb`; HStack keyboard toggle left, "Add N tasks" right). "Start over" button in review. `.onAppear`/`.onChange(of: projects)` set `model.projects`; `.onDisappear { model.disappear() }`. Save: `try model.save(in: ctx)` → `onSaved(n)`, error → message.
- [ ] **Step 2:** `ListeningOrb(phase:speech:action:)` reads `speech.level` in its own body (so only the orb re-renders ~40×/s); outer circle scales `1 + level*0.6` (opacity instead under Reduce Motion); stop icon while listening, mic otherwise, spinner while finishing; label below: "Listening" / "Record more" / "Tap to talk"; accessibility labels.
- [ ] **Step 3:** Rows: live row = title + project chip (`Color(hex: colorHex)` capsule, or "Choose project" in `Theme.warn`) + "~N min" (0.6 opacity when guessed), `.transition(.move(edge: .bottom).combined(with: .opacity))`; editable row = previous confirm row (toggle, title field, project picker, minutes). `.animation(.default, value: model.rows.map(\.id))`; ScrollViewReader scrolls to last row on count change.
- [ ] **Step 4:** Build + test: Shared `swift test`; iOS `xcodebuild … test`; Mac `xcodebuild -scheme StintMac build`. All green.
- [ ] **Step 5:** commit `feat(voice): live dictate — rows appear as you pause`, push.

### Task 5: Device

- [ ] Release build to iPhone (`-allowProvisioningUpdates`), `devicectl` install `Stint.app`, delete `dd-dev`, ask user to retest.
