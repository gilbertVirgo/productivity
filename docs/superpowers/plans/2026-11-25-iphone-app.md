# Stint iPhone App and Widgets Implementation Plan (plan 5 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iPhone app (Today, Tasks, Week, Rewards) and three widgets. The app signs in to the same Supabase account as the Mac, shows this week's progress and the running Mac session, and starts, pauses, resumes and ends Mac sessions through `session_command`.

**Architecture:**
- **Shared code is reused, not copied.** The phone runs the same `SyncEngine` (push/pull/realtime) over the same SwiftData schema (`StintSchema`). New shared pieces go into the package, not the app:
  - `Core/WidgetSnapshot`: the derived numbers the Today screen and the widgets show (pure, tested);
  - `StintData/RunningSession` plus two read queries on `SyncEngine` (`sessionTotals(since:)`, `runningSession()`);
  - the phone side of `session_command`: `sendCommand`, `command(_:)`, and a 10 s outcome wait.
- **Sessions stay Mac-owned.** The phone never writes `session`, `session_event` or `session_allow`, and does not store sessions in SwiftData. Each refresh reads this week's `session_totals` and the open session with its events, then rebuilds a `WidgetSnapshot` in memory.
- **Widgets read a JSON snapshot** that the app writes into the App Group container after each refresh. Widgets link only `Core`; they have no network or auth.
- **Commands can be rejected.** The Mac marks a command it can't act on with `rejected_reason` instead of deleting it. Deleted = accepted; still there after 10 s = "Mac not reachable".

**Tech Stack:** Swift 6, SwiftUI, SwiftData, WidgetKit, supabase-swift 2.x (already a dependency), XcodeGen 2.48, Swift Testing, local Supabase.

**Spec:** `docs/superpowers/specs/2026-11-24-freelance-focus-app-design.md`: §3 (platforms), §6.3 (sessions, phone start, 10 s acknowledgement), §6.9 (iPhone surfaces), §6.11 (sync, phone end-early cooldown), §9 step 5. Plan 4 (`docs/superpowers/plans/2026-11-25-sync.md`) defines the sync engine this plan reuses.

## Global Constraints

- App name **Stint**. Bundle IDs: `dev.stint.ios` (app), `dev.stint.ios.widgets` (widget extension), `dev.stint.ios.tests`. App Group `group.dev.stint`. iOS deployment target **17.2** (spec §3: "iOS 17.2+").
- **Sessions are Mac-owned** (spec §6.3, §6.11). The phone reads `session`, `session_event` and `session_totals`, and writes only `session_command`. It never inserts or updates a session row.
- Command kinds and payload keys are exactly the ones `SessionCommand.parse` accepts: `start` (`project_id`, `planned_min`, optional `first_task_id`), `break`, `resume`, `end_early_request` (`reason`).
- "If the Mac doesn't acknowledge within 10 s, the phone shows "Mac not reachable" and deletes the command" (§6.3).
- "End-early from the phone opens the same 60 s cooldown + reason sheet **on the phone**, then sends the command" (§6.11). The phone uses the Mac's `EndEarlySheet` itself (moved to `SharedUI/`).
- Session lengths 25 / 50 / 90 min. The Start widget starts a **50 min** session "on the project furthest behind today's daily goal" (§6.9).
- "Widgets refresh on app foreground and on Realtime updates while running; otherwise via their timeline every 15 min" (§6.9).
- Points and time come only from `Core` (`sessionTotals`, `sessionPoints`, `canRedeem`, `focusedSec`). "Points today" = today's ledger rows + the running session's provisional points (§6.7), as on the Mac.
- **Logger subsystems:** shared package code uses `"dev.stint"`; the Mac keeps `"dev.stint.mac"`; the phone uses `"dev.stint.ios"`.
- **Signing:** there is no signing identity yet. Tasks 1–5 build for the simulator only, ad-hoc (`CODE_SIGN_IDENTITY: "-"`, `CODE_SIGN_STYLE: Manual`), like the Mac target. Device installs and Sign in with Apple need the user's team: Task 6, which is **blocked on the user**.
- No new package dependencies.
- **Testing:**
  - SwiftPM: `cd Shared && swift test --disable-sandbox` (the flag is mandatory).
  - Integration tests (gated on env vars): `cd Shared && STINT_SUPABASE_URL=http://127.0.0.1:54321 STINT_SUPABASE_ANON_KEY=$(cd .. && supabase status -o env | sed -n 's/^ANON_KEY="\(.*\)"/\1/p') swift test --disable-sandbox --filter SyncIntegration`
  - Mac: `xcodegen generate && xcodebuild -project Stint.xcodeproj -scheme StintMac -destination 'platform=macOS' -derivedDataPath DerivedData test`
  - iPhone: `xcodegen generate && xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath DerivedData test`. Check the name with `xcrun simctl list devices available` (iOS 27.2 runtime).
  - DB: `supabase db reset && supabase test db`.
  - If `xcodebuild` or SwiftPM fails with `other(28)` / sandbox errors, re-run that Bash command with the sandbox disabled.
- Work on `main`. Commit trailer: `Co-Authored-By: <model you run as> <noreply@anthropic.com>`.

## Decisions taken in this plan (rulings)

- **Widgets read a JSON snapshot, not SwiftData.** Spec §3 says the App Group container is shared with the widget extension; it is, but it holds `widget-snapshot.json`, not the store. Widgets need only derived numbers. A second SwiftData client in a memory-capped extension invites migration and locking trouble. The app's store stays in its default location.
- **The Start widget opens the app** through `stint://start?project=<id>` (`widgetURL`) instead of running an App Intent in the background. A background intent would run in the extension, which has no auth session (sharing the keychain needs the team) and no place to show the 10 s wait or "Mac not reachable". The app sends the command and shows the outcome. Revisit with plan 7 if a no-launch button is wanted.
- **Phone sessions are read live, not stored.** `Mapping.apply` refuses to touch a running local session (a Mac rule), and the phone needs only this week. Goal history comes from `goal_result` (already pulled into `GoalResultRecord`).
- **How the phone learns a command was rejected** (plan 4 carry-forward): new nullable column `session_command.rejected_reason`. The Mac sets it instead of deleting when it can't act, and the phone shows the text and deletes the row. The Mac deletes rejected rows the phone never read once they are older than 10 s.
- **The phone needs sign-in**: it is a remote for the Mac and has nothing to show offline. Signing out **wipes the phone's store**, since it is a cache of the account. This avoids the Mac's account-owner check.
- **The phone never pushes `profile`** (`SyncEngine(pushesProfile: false)`). The timezone stays "from the Mac" (§5).
- **The phone does not edit projects or treats**, and does not delete tasks. The Mac has no task delete and remote deletes aren't pulled, so a phone delete would leave the task on the Mac. The phone adds tasks, marks them done or not done, and redeems treats.
- **"Today" small widget**: total focused time today across all projects vs the sum of today's daily hours goals.
- **Stale running session**: if the open session's row hasn't been updated for 2 min (the Mac checkpoints every 15 s), the card shows "Mac last seen <time>" and disables its buttons. A Mac that quit mid-session leaves its row open until its next launch.
- **Dictate tab**: not in this plan (plan 6). The tab bar is Today, Tasks, Week, Rewards.
- **Release builds** get empty Supabase settings, so they show "Sync not configured" instead of pointing at 127.0.0.1 (plan 4 carry-forward). Production values go in when the hosted project exists (user).
- **Sign in with Apple is phone-only and blocked** (Task 6). The Mac stays on email codes. Both land in one account through Supabase's automatic identity linking on the same verified email, so the user picks "Share My Email", not "Hide My Email".

## Before you start

- `supabase start` (Docker running); `supabase db reset` applies migrations 0001–0005.
- Plan 4's UI smoke was not finished (screen locked). If the Mac UI can be driven, do it now: sign in through Account with a Mailpit code (http://127.0.0.1:54324), confirm projects reach `public.project`, insert a `session_command` start row via psql and watch the Mac start. If not, say so in the Task 1 report. The integration tests cover the data path either way.

## File map

```
Shared/Sources/Core/WidgetSnapshot.swift            (T2) snapshot model, build, asOf
Shared/Tests/CoreTests/WidgetSnapshotTests.swift    (T2)
Shared/Sources/StintData/
  Ledger.swift, GoalInput.swift                     (T1) logger subsystem "dev.stint"
  Sync/Rows.swift                                   (T1) rejectedReason, NewSessionCommandRow; (T2) SessionTotalsRow
  Sync/SessionCommand.swift                         (T1) wire, CommandOutcome, awaitCommandOutcome
  Sync/SyncEngine.swift                             (T1) pushesProfile, command send/read/reject; (T2) phone read queries
  Sync/RunningSession.swift                         (T2)
  Sync/SyncConfig.swift                             (T3) SupabaseClient from Info.plist
Shared/Tests/StintDataTests/
  SessionCommandTests.swift (T1), RunningSessionTests.swift (T2), SyncConfigTests.swift (T3), SyncIntegrationTests.swift (T1, T2)
supabase/migrations/20261125000006_command_rejection.sql, supabase/tests/04_session_command_test.sql   (T1)
Mac/App/SyncCoordinator.swift                       (T1) reject instead of delete; (T3) SyncConfig
Mac/App/AppState.swift                              (T3) remainingText moves to SharedUI
MacTests/SyncCoordinatorTests.swift                 (T1)
SharedUI/                                           compiled into the Mac app, the iPhone app and (some files) the widgets
  Theme.swift, EndEarlySheet.swift                  (T3) moved from Mac/UI; + remainingText, hours
  WeekBars.swift                                    (T4)
  SnapshotStore.swift, StartLink.swift              (T5)
iOS/
  Info.plist, Stint.entitlements                    (T3 generated by XcodeGen; T5 adds App Group)
  StintPhoneApp.swift, PhoneSync.swift              (T3)
  UI/RootView.swift, UI/SignInView.swift, UI/AccountView.swift   (T3; RootView gains tabs in T4)
  UI/TodayView.swift, UI/TasksView.swift, UI/WeekView.swift, UI/RewardsView.swift, Lists.swift   (T4)
  AppleNonce.swift                                  (T6)
iOSTests/PhoneSyncTests.swift (T3), ListsTests.swift (T4), WidgetPlumbingTests.swift (T5), AppleNonceTests.swift (T6)
Widgets/StintWidgets.swift, Widgets/Info.plist, Widgets/StintWidgets.entitlements   (T5)
project.yml                                         (T3 StintPhone + tests + Release override; T5 widgets; T6 team)
README.md                                           (T3)
supabase/config.jsonc                               (T6)
```

---

### Task 1: Command rejection and the phone's command API (DB, StintData, Mac)

**Files:**
- Create: `supabase/migrations/20261125000006_command_rejection.sql`, `supabase/tests/04_session_command_test.sql`
- Modify: `Shared/Sources/StintData/Sync/{Rows,SessionCommand,SyncEngine}.swift`, `Shared/Sources/StintData/{Ledger,GoalInput}.swift`, `Mac/App/SyncCoordinator.swift`
- Test: `Shared/Tests/StintDataTests/SessionCommandTests.swift`, `Shared/Tests/StintDataTests/SyncIntegrationTests.swift`, `MacTests/SyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `SessionCommandRow`, `SessionCommand.parse`, `SyncEngine.pendingCommands/deleteCommand`, `SyncCoordinator.perform`.
- Produces (StintData, public):
  - `SessionCommandRow.rejectedReason: String?` (key `rejected_reason`, default `nil`, declared last so existing memberwise inits compile).
  - `struct NewSessionCommandRow: Encodable, Sendable { id: UUID; userID: UUID; kind: String; payload: [String: String] }`, keys `id, user_id, kind, payload`. No `created_at`: the server stamps it, so the Mac's 10 s age check never sees the phone's clock.
  - `extension SessionCommand { var wire: (kind: String, payload: [String: String]) }`, the inverse of `parse`.
  - `enum CommandOutcome: Equatable, Sendable { case accepted, rejected(String), unreachable }`
  - `@MainActor func awaitCommandOutcome(attempts: Int = 10, sleep: () async -> Void, poll: () async throws -> SessionCommandRow?) async -> CommandOutcome`
  - `SyncEngine.init(client:context:defaults:pushesProfile: Bool = true)`. When false, `push` skips `pushProfile` entirely (no timezone update, no full row).
  - `SyncEngine.sendCommand(_ cmd: SessionCommand, userID: UUID) async throws -> UUID`, `command(_ id: UUID) async throws -> SessionCommandRow?`, `rejectCommand(_ id: UUID, reason: String) async throws`.
- Produces (Mac): `static func rejectionReason(_ cmd: SessionCommand?, isRunning: Bool) -> String` on `SyncCoordinator`.

- [ ] **Step 1: Migration and DB test.** `20261125000006_command_rejection.sql`:

```sql
-- The Mac marks a phone command it can't act on instead of deleting it (deleting = accepted).
-- The phone shows the reason and deletes the row; the Mac deletes unread ones after 10 s.
alter table public.session_command add column rejected_reason text;
```

`04_session_command_test.sql`:

```sql
begin;
select plan(1);
select has_column('public', 'session_command', 'rejected_reason', 'the Mac can mark a phone command rejected');
select * from finish();
rollback;
```

Run `supabase db reset && supabase test db`. Expect 5 files to pass.

- [ ] **Step 2: Failing unit tests.** Append to `SessionCommandTests`:

```swift
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
```

`row(_:_:)` is the suite's existing helper (`func row(_ kind: String, _ p: [String: String] = [:]) -> SessionCommandRow`). The `@MainActor` tests sit inside the same suite.

Append to `MacTests/SyncCoordinatorTests.swift`:

```swift
    @Test func rejectionReasons() {
        let start = SessionCommand.start(projectID: UUID(), plannedMin: 25, firstTaskID: nil)
        #expect(SyncCoordinator.rejectionReason(start, isRunning: true) == "A session is already running on your Mac.")
        #expect(SyncCoordinator.rejectionReason(start, isRunning: false) == "Your Mac doesn't have that project yet. Try again in a minute.")
        #expect(SyncCoordinator.rejectionReason(.takeBreak, isRunning: false) == "No session is running on your Mac.")
        #expect(SyncCoordinator.rejectionReason(nil, isRunning: false) == "Your Mac couldn't read that request. Update Stint on both devices.")
    }
```

- [ ] **Step 3: Failing integration test.** In `SyncIntegrationTests.swift`, add a file-scope helper (leave the existing test as is) and a test:

```swift
@MainActor private func signedInClient() async throws -> (SupabaseClient, UUID) {
    let env = ProcessInfo.processInfo.environment
    let client = SupabaseClient(
        supabaseURL: URL(string: env["STINT_SUPABASE_URL"]!)!, supabaseKey: env["STINT_SUPABASE_ANON_KEY"]!,
        options: .init(db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
                       auth: .init(storage: MemoryStorage(), emitLocalSessionAsInitialSession: true)))
    let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    let password = String((0..<24).map { _ in chars.randomElement()! })
    let auth = try await client.auth.signUp(email: "sync-\(UUID())@test.local", password: password)
    return (client, auth.user.id)
}
```

```swift
    @Test func phoneCommandsAndNoProfilePush() async throws {
        let (client, uid) = try await signedInClient()
        let d = defaults()
        d.set("Phone", forKey: "displayName"); d.set(Date.now.timeIntervalSince1970, forKey: "profileUpdatedAt")
        let phone = SyncEngine(client: client, context: try ctx(), defaults: d, pushesProfile: false)
        try await phone.push(userID: uid)
        let prof: [ProfileRow] = try await client.from("profile").select().execute().value
        #expect(prof.first?.displayName == "")

        let id = try await phone.sendCommand(.endEarly(reason: "Client call"), userID: uid)
        let sent = try #require(try await phone.command(id))
        #expect(SessionCommand.parse(sent) == .endEarly(reason: "Client call"))
        #expect(sent.rejectedReason == nil)
        try await phone.rejectCommand(id, reason: "No session is running on your Mac.")
        #expect(try await phone.command(id)?.rejectedReason == "No session is running on your Mac.")
        try await phone.deleteCommand(id)
        #expect(try await phone.command(id) == nil)
        try await client.auth.signOut()
    }
```

- [ ] **Step 4:** Run `swift test --disable-sandbox` with and without the env vars, and the Mac tests. Expect build failures (missing `wire`, `awaitCommandOutcome`, `pushesProfile`, `rejectionReason`).

- [ ] **Step 5: Implement StintData.**

`Rows.swift`: add `public var rejectedReason: String? = nil` as the last stored property of `SessionCommandRow`, and add `rejectedReason = "rejected_reason"` to its `CodingKeys`. Add:

```swift
/// Insert shape for a phone command. `created_at` is server-defaulted so the Mac ages commands by server time.
public struct NewSessionCommandRow: Encodable, Sendable {
    public var id: UUID, userID: UUID
    public var kind: String
    public var payload: [String: String]
    enum CodingKeys: String, CodingKey { case id, userID = "user_id", kind, payload }
}
```

`SessionCommand.swift`, appended:

```swift
public extension SessionCommand {
    /// Wire form for a `session_command` row; `parse` is its inverse.
    var wire: (kind: String, payload: [String: String]) {
        switch self {
        case let .start(projectID, plannedMin, firstTaskID):
            var p = ["project_id": projectID.uuidString, "planned_min": String(plannedMin)]
            if let firstTaskID { p["first_task_id"] = firstTaskID.uuidString }
            return ("start", p)
        case .takeBreak: return ("break", [:])
        case .resume: return ("resume", [:])
        case let .endEarly(reason): return ("end_early_request", ["reason": reason])
        }
    }
}

public enum CommandOutcome: Equatable, Sendable { case accepted, rejected(String), unreachable }

/// Spec §6.3: polls the sent row until the Mac deletes it (accepted) or marks it rejected; gives up after
/// `attempts` polls (10 × 1 s). A poll that throws (network) counts as still pending.
@MainActor
public func awaitCommandOutcome(attempts: Int = 10, sleep: () async -> Void,
                                poll: () async throws -> SessionCommandRow?) async -> CommandOutcome {
    for _ in 0..<attempts {
        await sleep()
        do {
            guard let row = try await poll() else { return .accepted }
            if let reason = row.rejectedReason { return .rejected(reason) }
        } catch { continue }
    }
    return .unreachable
}
```

`SyncEngine.swift`:
- Add `private let pushesProfile: Bool`, and the init parameter `pushesProfile: Bool = true`.
- In `push`, replace the first line with `if pushesProfile { try await pushProfile(userID) }`.
- Change the realtime logger to `Logger(subsystem: "dev.stint", category: "sync")`.
- Add, under `// MARK: session commands`:

```swift
    /// Phone side: insert a command. Returns its id for `command(_:)` polling.
    public func sendCommand(_ cmd: SessionCommand, userID: UUID) async throws -> UUID {
        let w = cmd.wire
        let row = NewSessionCommandRow(id: UUID(), userID: userID, kind: w.kind, payload: w.payload)
        try await client.from("session_command").insert(row, returning: .minimal).execute()
        return row.id
    }

    /// nil once the Mac has deleted it (accepted).
    public func command(_ id: UUID) async throws -> SessionCommandRow? {
        let rows: [SessionCommandRow] = try await client.from("session_command").select().eq("id", value: id).execute().value
        return rows.first
    }

    /// Mac side: leave the row for the phone to read instead of deleting it.
    public func rejectCommand(_ id: UUID, reason: String) async throws {
        try await client.from("session_command").update(["rejected_reason": reason]).eq("id", value: id).execute()
    }
```

`Ledger.swift` and `GoalInput.swift`: change `subsystem: "dev.stint.mac"` to `subsystem: "dev.stint"`. Afterwards `grep -rn 'dev.stint.mac' Shared/Sources` must print nothing.

- [ ] **Step 6: Implement the Mac side.** In `SyncCoordinator.swift`, add:

```swift
    /// What the phone shows when the Mac can't act on a command.
    static func rejectionReason(_ cmd: SessionCommand?, isRunning: Bool) -> String {
        switch cmd {
        case nil: "Your Mac couldn't read that request. Update Stint on both devices."
        case .start: isRunning ? "A session is already running on your Mac." : "Your Mac doesn't have that project yet. Try again in a minute."
        case .takeBreak, .resume, .endEarly: "No session is running on your Mac."
        }
    }
```

Replace the body of the `for row in try await engine.pendingCommands()` loop in `handlePending` with:

```swift
                    guard gen == generation else { return }
                    let age = Date.now.timeIntervalSince(row.createdAt)
                    if row.rejectedReason != nil { // waiting for the phone to read it
                        if age > 10 { try await engine.deleteCommand(row.id) }
                        continue
                    }
                    guard age <= 10 else {
                        Self.log.info("discarded stale command \(row.kind, privacy: .public), age \(Int(age))s")
                        try await engine.deleteCommand(row.id)
                        continue
                    }
                    let cmd = SessionCommand.parse(row)
                    var done = cmd.map { Self.perform($0, on: app) } ?? false
                    if !done, let cmd, case .start = cmd {
                        // The project may have been created on the phone moments ago: pull once and retry.
                        await syncNow()
                        // A pass already in flight only queues another; wait until the queued pass finishes.
                        while syncing { try? await Task.sleep(for: .milliseconds(50)) }
                        guard gen == generation else { return }
                        done = Self.perform(cmd, on: app)
                    }
                    if done {
                        try await engine.deleteCommand(row.id) // deleting is the acknowledgement
                    } else {
                        if cmd == nil { Self.log.error("unparseable command \(row.kind, privacy: .public)") }
                        try await engine.rejectCommand(row.id, reason: Self.rejectionReason(cmd, isRunning: app.isRunning))
                    }
```

- [ ] **Step 7:** Run all three suites (`swift test --disable-sandbox` with and without env vars, Mac `xcodebuild … test`, `supabase test db`). Expect all to pass.

  If the Mac app can be run signed in locally, also check by hand: with no session running, insert a `break` command via psql. Within ~2 s its `rejected_reason` is "No session is running on your Mac.", and it is gone within the next 30 s pass.

- [ ] **Step 8: Commit** `feat(sync): phone command API; Mac rejects with a reason`.

---

### Task 2: Phone read model: session feed, running session, widget snapshot

**Files:**
- Create: `Shared/Sources/Core/WidgetSnapshot.swift`, `Shared/Sources/StintData/Sync/RunningSession.swift`
- Modify: `Shared/Sources/StintData/Sync/{Rows,SyncEngine}.swift`
- Test: `Shared/Tests/CoreTests/WidgetSnapshotTests.swift`, `Shared/Tests/StintDataTests/RunningSessionTests.swift`, `Shared/Tests/StintDataTests/SyncIntegrationTests.swift`

**Interfaces:**
- Consumes: Core `sessionTotals`, `focusedSec`, `hasDailyGoal`, `PeriodCalendar`, `SessionSummary`; StintData `SessionRow`, `SessionEventRow`; Task 1's `signedInClient()` test helper and `pushesProfile`.
- Produces (Core, public):
  - `struct WidgetSnapshot: Codable, Sendable, Equatable` with `generatedAt: Date`, `lines: [Line]`, `pointsToday: Int`, plus:
    - computed `todayFocusedSec: Int`, `todayGoalSec: Int`, `startProjectID: UUID?`;
    - `static func build(projects: [ProjectGoals], sessions: [SessionSummary], pointsToday: Int, now: Date, calendar: PeriodCalendar) -> WidgetSnapshot`;
    - `func asOf(_ now: Date, calendar: PeriodCalendar) -> WidgetSnapshot`.
  - `WidgetSnapshot.Line: Codable, Sendable, Equatable, Identifiable`: `id: UUID, name: String, colorHex: String, weekFocusedSec: Int, weeklyGoalSec: Int?, todayFocusedSec: Int, dailyGoalSec: Int?, dailyTargetSec: Int?, dailyGoalDays: [Int]`.
  - `WidgetSnapshot.ProjectGoals: Sendable` with `public init(id: UUID, name: String, colorHex: String, weeklyHoursGoal: Double?, dailyHoursGoal: Double?, dailyGoalDays: [Int])`.
- Produces (StintData, public):
  - `struct SessionTotalsRow: Decodable, Sendable, Equatable { sessionID, projectID: UUID; startedAt: Date; endedAt: Date?; focusedSec, breakSec: Int }` with a public memberwise `init` and `var summary: SessionSummary`.
  - `struct RunningSession: Sendable, Equatable { id, projectID: UUID; firstTaskID: UUID?; plannedMin: Int; startedAt, lastSeen: Date; events: [SessionEvent] }`. It has:
    - a public memberwise `init`, and `init(row: SessionRow, events: [SessionEventRow])`;
    - `totals(at:) -> SessionTotals`, `remainingSec(at:) -> Int`, `summary(at:) -> SessionSummary`;
    - `onBreak: Bool`, `offTask: Bool`, `isStale(at:) -> Bool`.
  - `SyncEngine.sessionTotals(since: Date) async throws -> [SessionTotalsRow]` and `SyncEngine.runningSession() async throws -> RunningSession?`.

- [ ] **Step 1: Failing tests.** `Shared/Tests/CoreTests/WidgetSnapshotTests.swift` (2026-11-24 is a Tuesday):

```swift
import Testing
import Foundation
@testable import Core

@Suite struct WidgetSnapshotTests {
    let cal = PeriodCalendar(timeZone: TimeZone(identifier: "UTC")!)
    let a = UUID(), b = UUID()
    let now = date("2026-11-24T15:00:00Z")

    var projects: [WidgetSnapshot.ProjectGoals] {[
        .init(id: a, name: "Alpha", colorHex: "#0F7B6C", weeklyHoursGoal: 10, dailyHoursGoal: 2, dailyGoalDays: [1, 2, 3, 4, 5]),
        .init(id: b, name: "Beta", colorHex: "#B7671F", weeklyHoursGoal: nil, dailyHoursGoal: 1, dailyGoalDays: [2]),
    ]}

    func build(_ todayA: Int = 1800, _ todayB: Int = 600) -> WidgetSnapshot {
        WidgetSnapshot.build(projects: projects, sessions: [
            SessionSummary(projectID: a, startedAt: date("2026-11-23T09:00:00Z"), focusedSec: 3600, breakSec: 0), // Monday
            SessionSummary(projectID: a, startedAt: date("2026-11-24T09:00:00Z"), focusedSec: todayA, breakSec: 0),
            SessionSummary(projectID: b, startedAt: date("2026-11-24T10:00:00Z"), focusedSec: todayB, breakSec: 0),
        ], pointsToday: 42, now: now, calendar: cal)
    }

    @Test func buildsLines() {
        let s = build()
        #expect(s.lines.map(\.weekFocusedSec) == [5400, 600])
        #expect(s.lines.map(\.todayFocusedSec) == [1800, 600])
        #expect(s.lines.map(\.weeklyGoalSec) == [36000, nil])
        #expect(s.lines.map(\.dailyGoalSec) == [7200, 3600])
        #expect(s.todayFocusedSec == 2400 && s.todayGoalSec == 10800 && s.pointsToday == 42)
    }

    @Test func startPicksMostTimeLeft() {
        #expect(build().startProjectID == a)          // Alpha 5400 s left, Beta 3000 s
        #expect(build(7200, 0).startProjectID == b)   // Alpha met
        #expect(build(7200, 3600).startProjectID == nil)
    }

    @Test func nextDayZeroesTodayAndRecomputesGoals() {
        let s = build().asOf(date("2026-11-25T08:00:00Z"), calendar: cal) // Wednesday
        #expect(s.lines.map(\.todayFocusedSec) == [0, 0])
        #expect(s.pointsToday == 0)
        #expect(s.lines.map(\.weekFocusedSec) == [5400, 600])
        #expect(s.lines.map(\.dailyGoalSec) == [7200, nil]) // Beta's goal is Tuesdays only
    }

    @Test func nextWeekZeroesWeek() {
        #expect(build().asOf(date("2026-11-30T08:00:00Z"), calendar: cal).lines.map(\.weekFocusedSec) == [0, 0])
    }

    @Test func codableRoundTrip() throws {
        let s = build()
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s)) == s)
    }
}
```

`Shared/Tests/StintDataTests/RunningSessionTests.swift`:

```swift
import Testing
import Foundation
import Core
@testable import StintData

@Suite struct RunningSessionTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Int) -> Date { start.addingTimeInterval(TimeInterval(s)) }
    func make(_ events: [SessionEvent]) -> RunningSession {
        RunningSession(id: UUID(), projectID: UUID(), firstTaskID: nil, plannedMin: 25, startedAt: start, lastSeen: at(600), events: events)
    }

    @Test func countdownExcludesBreaks() {
        let r = make([SessionEvent(.breakStart, at: at(300)), SessionEvent(.breakEnd, at: at(420))])
        #expect(r.remainingSec(at: at(600)) == 25 * 60 - 480)
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
        #expect(r.lastSeen == at(30) && r.plannedMin == 50)
    }

    @Test func totalsRowDecodesNullEnd() throws {
        let json = #"[{"session_id":"\#(UUID())","project_id":"\#(UUID())","started_at":"2026-11-24T09:00:00+00:00","ended_at":null,"focused_sec":60,"break_sec":0}]"#
        let rows = try SyncCoding.decoder.decode([SessionTotalsRow].self, from: Data(json.utf8))
        #expect(rows.first?.endedAt == nil && rows.first?.summary.focusedSec == 60)
    }
}
```

The row structs' memberwise inits are internal (`Rows.swift` header), and `@testable import` reaches them. `SessionRow.serverUpdatedAt` and `SessionEventRow.detail` have defaults, so they are left out above.

Append to `SyncIntegrationTests`:

```swift
    @Test func phoneFeedReadsMacSessions() async throws {
        let (client, uid) = try await signedInClient()
        let mac = try ctx()
        let now = Date.now
        let p = Project(name: "Northwind", now: now.addingTimeInterval(-7200)); mac.insert(p)
        let none = try JSONEncoder().encode([AllowEntry]())
        let closed = SessionRecord(projectID: p.id, firstTaskID: nil, plannedMin: 25, startedAt: now.addingTimeInterval(-3600), allowData: none)
        closed.endedAt = now.addingTimeInterval(-2100); closed.endKind = "completed"
        let open = SessionRecord(projectID: p.id, firstTaskID: nil, plannedMin: 50, startedAt: now.addingTimeInterval(-300), allowData: none)
        open.eventsData = try JSONEncoder().encode([SessionEvent(.breakStart, at: now.addingTimeInterval(-60))])
        mac.insert(closed); mac.insert(open); try mac.save()
        try await SyncEngine(client: client, context: mac, defaults: defaults()).push(userID: uid)

        let phone = SyncEngine(client: client, context: try ctx(), defaults: defaults(), pushesProfile: false)
        let rows = try await phone.sessionTotals(since: now.addingTimeInterval(-7200))
        #expect(rows.count == 2)
        #expect(rows.first { $0.sessionID == closed.id }?.focusedSec == 1500)
        #expect(rows.first { $0.sessionID == open.id }?.endedAt == nil)
        let run = try #require(try await phone.runningSession())
        #expect(run.id == open.id && run.plannedMin == 50 && run.onBreak)
        try await client.auth.signOut()
    }
```

- [ ] **Step 2:** Run them. Expect build FAIL (`WidgetSnapshot`, `RunningSession`, `SessionTotalsRow` not found).

- [ ] **Step 3: Implement.** `Shared/Sources/Core/WidgetSnapshot.swift`:

```swift
import Foundation

/// What the phone's Today screen and the widgets show (spec §6.9). Built by the app; widgets get it as JSON.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var colorHex: String
        public var weekFocusedSec: Int
        public var weeklyGoalSec: Int?
        public var todayFocusedSec: Int
        /// Today's daily goal; nil when the project has none today.
        public var dailyGoalSec: Int?
        /// The daily goal and its ISO weekdays, kept so `asOf` can recompute `dailyGoalSec` for a later day.
        public var dailyTargetSec: Int?
        public var dailyGoalDays: [Int]
    }

    public struct ProjectGoals: Sendable {
        public var id: UUID, name: String, colorHex: String
        public var weeklyHoursGoal: Double?, dailyHoursGoal: Double?
        public var dailyGoalDays: [Int]
        public init(id: UUID, name: String, colorHex: String, weeklyHoursGoal: Double?, dailyHoursGoal: Double?, dailyGoalDays: [Int]) {
            self.id = id; self.name = name; self.colorHex = colorHex
            self.weeklyHoursGoal = weeklyHoursGoal; self.dailyHoursGoal = dailyHoursGoal; self.dailyGoalDays = dailyGoalDays
        }
    }

    public var generatedAt: Date
    public var lines: [Line]
    public var pointsToday: Int

    public var todayFocusedSec: Int { lines.reduce(0) { $0 + $1.todayFocusedSec } }
    public var todayGoalSec: Int { lines.compactMap(\.dailyGoalSec).reduce(0, +) }

    /// Start widget: the project with the most daily-goal time left today; ties go to the first line. nil when all are met.
    public var startProjectID: UUID? {
        lines.compactMap { l in l.dailyGoalSec.map { (l.id, $0 - l.todayFocusedSec) } }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func sec(_ hours: Double?) -> Int? { hours.map { Int(($0 * 3600).rounded()) } }

    private static func goal(_ l: Line, on now: Date, _ calendar: PeriodCalendar) -> Int? {
        hasDailyGoal(on: now, days: Set(l.dailyGoalDays), calendar: calendar) ? l.dailyTargetSec : nil
    }

    public static func build(projects: [ProjectGoals], sessions: [SessionSummary], pointsToday: Int,
                             now: Date, calendar: PeriodCalendar) -> WidgetSnapshot {
        let day = calendar.dayInterval(containing: now), week = calendar.weekInterval(containing: now)
        let lines = projects.map { p in
            var l = Line(id: p.id, name: p.name, colorHex: p.colorHex,
                         weekFocusedSec: focusedSec(sessions, projectID: p.id, in: week),
                         weeklyGoalSec: sec(p.weeklyHoursGoal),
                         todayFocusedSec: focusedSec(sessions, projectID: p.id, in: day),
                         dailyGoalSec: nil, dailyTargetSec: sec(p.dailyHoursGoal), dailyGoalDays: p.dailyGoalDays)
            l.dailyGoalSec = goal(l, on: now, calendar)
            return l
        }
        return WidgetSnapshot(generatedAt: now, lines: lines, pointsToday: pointsToday)
    }

    /// The snapshot as a widget should show it at `now`: today's numbers reset once the day it was built has
    /// ended, week numbers once the week has; daily goals follow `now`'s weekday.
    public func asOf(_ now: Date, calendar: PeriodCalendar) -> WidgetSnapshot {
        var s = self
        let sameDay = calendar.dayInterval(containing: now).contains(generatedAt)
        let sameWeek = calendar.weekInterval(containing: now).contains(generatedAt)
        for i in s.lines.indices {
            if !sameDay { s.lines[i].todayFocusedSec = 0 }
            if !sameWeek { s.lines[i].weekFocusedSec = 0 }
            s.lines[i].dailyGoalSec = Self.goal(s.lines[i], on: now, calendar)
        }
        if !sameDay { s.pointsToday = 0 }
        return s
    }
}
```

`DateInterval.contains` includes `end`. `generatedAt` is never exactly the next period's start in practice, and if it were, the numbers would just show one period late. Leave it.

`Rows.swift`, appended:

```swift
/// `session_totals` view row (read by the phone).
public struct SessionTotalsRow: Decodable, Sendable, Equatable {
    public var sessionID: UUID, projectID: UUID
    public var startedAt: Date, endedAt: Date?
    public var focusedSec: Int, breakSec: Int
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", projectID = "project_id", startedAt = "started_at", endedAt = "ended_at"
        case focusedSec = "focused_sec", breakSec = "break_sec"
    }
    public init(sessionID: UUID, projectID: UUID, startedAt: Date, endedAt: Date?, focusedSec: Int, breakSec: Int) {
        self.sessionID = sessionID; self.projectID = projectID; self.startedAt = startedAt; self.endedAt = endedAt
        self.focusedSec = focusedSec; self.breakSec = breakSec
    }
    public var summary: SessionSummary {
        SessionSummary(projectID: projectID, startedAt: startedAt, focusedSec: focusedSec, breakSec: breakSec)
    }
}
```

`Shared/Sources/StintData/Sync/RunningSession.swift`:

```swift
import Foundation
import Core

/// The Mac's open session as the phone sees it: the server row plus its events, as of the Mac's last checkpoint.
public struct RunningSession: Sendable, Equatable {
    public var id: UUID, projectID: UUID, firstTaskID: UUID?
    public var plannedMin: Int
    public var startedAt: Date
    /// The row's `updated_at`: the Mac's last checkpoint (every ~15 s while running).
    public var lastSeen: Date
    public var events: [SessionEvent]

    public init(id: UUID, projectID: UUID, firstTaskID: UUID?, plannedMin: Int, startedAt: Date, lastSeen: Date, events: [SessionEvent]) {
        self.id = id; self.projectID = projectID; self.firstTaskID = firstTaskID
        self.plannedMin = plannedMin; self.startedAt = startedAt; self.lastSeen = lastSeen; self.events = events
    }

    public init(row: SessionRow, events: [SessionEventRow]) {
        self.init(id: row.id, projectID: row.projectID, firstTaskID: row.firstTaskID, plannedMin: row.plannedMin,
                  startedAt: row.startedAt, lastSeen: row.updatedAt,
                  events: events.compactMap { e in
                      SessionEventType(rawValue: e.type).map { SessionEvent($0, at: e.at, detail: e.detail.isEmpty ? nil : e.detail) }
                  })
    }

    public func totals(at now: Date) -> SessionTotals { sessionTotals(start: startedAt, end: now, events: events) }
    /// Same rule as `SessionEngine.remainingSec`: breaks and sleep don't use up the planned length.
    public func remainingSec(at now: Date) -> Int { max(0, plannedMin * 60 - totals(at: now).activeSec) }
    public func summary(at now: Date) -> SessionSummary {
        let t = totals(at: now)
        return SessionSummary(projectID: projectID, startedAt: startedAt, focusedSec: t.focusedSec, breakSec: t.breakSec)
    }

    private func isOpen(_ start: SessionEventType, _ end: SessionEventType) -> Bool {
        events.last { $0.type == start || $0.type == end }?.type == start
    }
    public var onBreak: Bool { isOpen(.breakStart, .breakEnd) }
    public var offTask: Bool { isOpen(.offtaskStart, .offtaskEnd) }
    /// No checkpoint for 2 min: the Mac quit, slept or lost network.
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(lastSeen) > 120 }
}
```

`SessionEventRow.detail` is a non-optional `[String: String]` defaulting to `[:]`. An empty one maps to `nil`, matching the Mac's own events, so `rowInitDropsUnknownEventTypes` holds.

`SyncEngine.swift`, new section:

```swift
    // MARK: phone read model (sessions are Mac-owned: the phone reads them, never writes them)

    public func sessionTotals(since: Date) async throws -> [SessionTotalsRow] {
        try await client.from("session_totals").select("session_id,project_id,started_at,ended_at,focused_sec,break_sec")
            .gte("started_at", value: Self.iso(since)).order("started_at", ascending: true).execute().value
    }

    public func runningSession() async throws -> RunningSession? {
        let open: [SessionRow] = try await client.from("session").select().is("ended_at", value: nil)
            .order("started_at", ascending: false).limit(1).execute().value
        guard let s = open.first else { return nil }
        let events: [SessionEventRow] = try await client.from("session_event").select().eq("session_id", value: s.id)
            .order("at", ascending: true).execute().value
        return RunningSession(row: s, events: events)
    }
```

- [ ] **Step 4:** `swift test --disable-sandbox` passes with and without the env vars.
- [ ] **Step 5: Commit** `feat(sync): phone read model and widget snapshot`.

---

### Task 3: iPhone app target: sign-in, sync, shared UI, Release override

**Files:**
- Create: `Shared/Sources/StintData/Sync/SyncConfig.swift`, `Shared/Tests/StintDataTests/SyncConfigTests.swift`, `iOS/StintPhoneApp.swift`, `iOS/PhoneSync.swift`, `iOS/UI/{RootView,SignInView,AccountView}.swift`, `iOSTests/PhoneSyncTests.swift`
- Move: `Mac/UI/Theme.swift` → `SharedUI/Theme.swift`, `Mac/UI/EndEarlySheet.swift` → `SharedUI/EndEarlySheet.swift` (`git mv`)
- Modify: `Mac/App/AppState.swift` (move `remainingText` out), `Mac/App/SyncCoordinator.swift` (use `SyncConfig`), `project.yml`, `README.md`

**Interfaces:**
- Consumes: Task 1 (`pushesProfile`, `sendCommand`, `command`, `deleteCommand`, `awaitCommandOutcome`), Task 2 (`sessionTotals`, `runningSession`, `WidgetSnapshot`, `RunningSession`, `SessionTotalsRow`).
- Produces:
  - `public enum SyncConfig { public static func client(info: [String: Any]?) -> SupabaseClient? }` (StintData). Returns nil when `StintSupabaseURL` / `StintSupabaseAnonKey` are missing, empty or unexpanded (`$(`…).
  - `SharedUI`: `Color(hex:)`, `Theme`, `ProjectColor` (moved unchanged), `func remainingText(_ sec: Int) -> String` (moved from AppState.swift), `func hours(_ sec: Int) -> String` (one decimal), `EndEarlySheet(onEnd:onCancel:)` (unchanged).
  - `@MainActor @Observable final class PhoneSync` (iOS target):
    - `init(context: ModelContext, defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary)`;
    - properties `state: State` (`signedOut`, `signingIn`, `signedIn(email:)`), `lastSync: Date?`, `lastError: String?`, `running: RunningSession?`, `snapshot: WidgetSnapshot?`, `commandStatus: String?`, `waiting: Bool`, `configured: Bool`, `cal: PeriodCalendar`, `static let log`;
    - `sendCode(email:) async`, `verify(email:code:) async`, `cancelSignIn()`, `signOut() async`;
    - `setActive(_ active: Bool) async`, `syncSoon()`, `refresh() async`;
    - `apply(week: [SessionTotalsRow], running: RunningSession?, now: Date)`, `send(_ cmd: SessionCommand) async`;
    - `static func wipe(_ ctx: ModelContext, defaults: UserDefaults) throws`.
  - `RootView` (shows `SignInView` unless signed in), `AccountView`.

- [ ] **Step 1: Failing tests.** `SyncConfigTests.swift`:

```swift
import Testing
@testable import StintData

@Suite struct SyncConfigTests {
    @Test func missingEmptyOrUnexpandedIsNil() {
        #expect(SyncConfig.client(info: nil) == nil)
        #expect(SyncConfig.client(info: ["StintSupabaseURL": "", "StintSupabaseAnonKey": ""]) == nil) // Release override
        #expect(SyncConfig.client(info: ["StintSupabaseURL": "$(STINT_SUPABASE_URL)", "StintSupabaseAnonKey": "k"]) == nil)
    }
    @Test func configured() {
        #expect(SyncConfig.client(info: ["StintSupabaseURL": "http://127.0.0.1:54321", "StintSupabaseAnonKey": "k"]) != nil)
    }
}
```

`iOSTests/PhoneSyncTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct PhoneSyncTests {
    func ctx() throws -> ModelContext {
        try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true)).mainContext
    }
    func defaults() -> UserDefaults { UserDefaults(suiteName: "phone-\(UUID())")! }

    @Test func unconfiguredStaysSignedOut() throws {
        let s = PhoneSync(context: try ctx(), defaults: defaults(), info: [:])
        #expect(!s.configured && s.state == .signedOut)
    }

    @Test func wipeEmptiesStoreAndSyncKeys() throws {
        let c = try ctx(), d = defaults()
        let p = Project(name: "Northwind"); c.insert(p)
        let t = TaskItem(title: "Ship"); c.insert(t); t.project = p
        c.insert(PointEvent(at: .now, delta: 5, kind: "focus", refID: nil, note: ""))
        try c.save()
        d.set(1.0, forKey: "sync.watermark.project"); d.set(1.0, forKey: "profileUpdatedAt")
        try PhoneSync.wipe(c, defaults: d)
        #expect(try c.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try c.fetchCount(FetchDescriptor<TaskItem>()) == 0)
        #expect(try c.fetchCount(FetchDescriptor<PointEvent>()) == 0)
        #expect(d.object(forKey: "sync.watermark.project") == nil && d.object(forKey: "profileUpdatedAt") == nil)
    }

    @Test func applyCountsLiveSessionAndPoints() throws {
        let c = try ctx()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
        let p = Project(name: "Northwind"); p.dailyHoursGoal = 1; p.dailyGoalDays = [1, 2, 3, 4, 5, 6, 7]; c.insert(p)
        c.insert(PointEvent(at: noon.addingTimeInterval(-60), delta: 5, kind: "focus", refID: nil, note: ""))
        try c.save()
        let s = PhoneSync(context: c, defaults: defaults(), info: [:])
        let closed = SessionTotalsRow(sessionID: UUID(), projectID: p.id, startedAt: noon.addingTimeInterval(-7200),
                                      endedAt: noon.addingTimeInterval(-6000), focusedSec: 1200, breakSec: 0)
        let run = RunningSession(id: UUID(), projectID: p.id, firstTaskID: nil, plannedMin: 25,
                                 startedAt: noon.addingTimeInterval(-600), lastSeen: noon, events: [])
        s.apply(week: [closed], running: run, now: noon)
        let line = try #require(s.snapshot?.lines.first)
        #expect(line.todayFocusedSec == 1800 && line.dailyGoalSec == 3600)
        #expect(s.snapshot?.pointsToday == 5 + 10) // ledger + 10 provisional focused minutes
        #expect(s.running == run)
    }
}
```

- [ ] **Step 2:** Run `swift test --disable-sandbox`. Expect FAIL (`SyncConfig` missing). The iOS tests can't run yet (no target).

- [ ] **Step 3: Shared code.** `Shared/Sources/StintData/Sync/SyncConfig.swift`:

```swift
import Foundation
import Supabase

public enum SyncConfig {
    /// The app's Supabase client, from Info.plist keys `StintSupabaseURL` / `StintSupabaseAnonKey`.
    /// nil when either is missing, empty (Release until production exists) or an unexpanded `$(…)`.
    public static func client(info: [String: Any]?) -> SupabaseClient? {
        func value(_ k: String) -> String? { (info?[k] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } }
        guard let url = value("StintSupabaseURL").flatMap(URL.init(string:)), let key = value("StintSupabaseAnonKey") else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key,
                              options: .init(db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
                                             auth: .init(emitLocalSessionAsInitialSession: true)))
    }
}
```

In `SyncCoordinator.init`, replace the inline `info`/`value`/`SupabaseClient(...)` block with:

```swift
        if let c = SyncConfig.client(info: Bundle.main.infoDictionary) {
            client = c; engine = SyncEngine(client: c, context: context); configured = true
        } else {
            client = nil; engine = nil; configured = false
        }
```

Then the shared UI files:
- `git mv Mac/UI/Theme.swift SharedUI/Theme.swift` and `git mv Mac/UI/EndEarlySheet.swift SharedUI/EndEarlySheet.swift`.
- Move `func remainingText(_ sec: Int) -> String` from `AppState.swift` to the bottom of `Theme.swift`.
- Remove `import StintData` from `Theme.swift`. Nothing in it uses StintData, and the widget target (Task 5) doesn't link it.
- Add to `Theme.swift`:

```swift
/// "3.5" (hours, one decimal) from seconds.
func hours(_ sec: Int) -> String { String(format: "%.1f", Double(sec) / 3600) }
```

- [ ] **Step 4: `project.yml`.**
  - Set `StintMac.sources` to `[Mac, SharedUI]`.
  - Add `iOS: "17.2"` under `options.deploymentTarget`.
  - Under the top-level `settings`, add a Release override:

```yaml
  configs:
    Release:
      # Production values go here once the hosted project exists. Empty = "Sync not configured", never 127.0.0.1.
      STINT_SUPABASE_URL: ""
      STINT_SUPABASE_ANON_KEY: ""
```

  Add the targets:

```yaml
  StintPhone:
    type: application
    platform: iOS
    sources: [iOS, SharedUI]
    dependencies:
      - package: Core
      - package: Core
        product: StintData
      - package: Supabase
        product: Supabase
    info:
      path: iOS/Info.plist
      properties:
        CFBundleDisplayName: Stint
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        StintSupabaseURL: $(STINT_SUPABASE_URL)
        StintSupabaseAnonKey: $(STINT_SUPABASE_ANON_KEY)
        NSAppTransportSecurity:
          NSAllowsLocalNetworking: true
    settings:
      base:
        PRODUCT_NAME: Stint
        PRODUCT_BUNDLE_IDENTIFIER: dev.stint.ios
        TARGETED_DEVICE_FAMILY: "1"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
    scheme:
      testTargets: [StintPhoneTests]
  StintPhoneTests:
    type: bundle.unit-test
    platform: iOS
    sources: [iOSTests]
    dependencies:
      - target: StintPhone
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.stint.ios.tests
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Stint.app/Stint"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

  Check the override: `xcodebuild -project Stint.xcodeproj -scheme StintPhone -configuration Release -showBuildSettings | grep STINT_SUPABASE_URL` prints an empty value. With `-configuration Debug` it prints the local URL.

- [ ] **Step 5: `iOS/PhoneSync.swift`.**

```swift
import Foundation
import SwiftData
import Supabase
import StintData
import Core
import os

/// The phone's sync: auth, push/pull through the shared SyncEngine, the session feed, and commands to the Mac.
@MainActor @Observable
final class PhoneSync {
    enum State: Equatable { case signedOut, signingIn, signedIn(email: String) }
    static let log = Logger(subsystem: "dev.stint.ios", category: "sync")

    var state: State = .signedOut
    var lastSync: Date?
    var lastError: String?
    var running: RunningSession?
    var snapshot: WidgetSnapshot?
    /// "Waiting for your Mac…" while a command is pending; afterwards the rejection or "Mac not reachable".
    var commandStatus: String?
    var waiting = false
    let configured: Bool
    let cal = PeriodCalendar(timeZone: .current)

    @ObservationIgnored private let ctx: ModelContext
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: SupabaseClient?
    @ObservationIgnored private let engine: SyncEngine?
    @ObservationIgnored private var userID: UUID?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var generation = 0 // bumped on sign-out so in-flight passes discard their results

    init(context: ModelContext, defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary) {
        ctx = context; self.defaults = defaults
        client = SyncConfig.client(info: info)
        engine = client.map { SyncEngine(client: $0, context: context, defaults: defaults, pushesProfile: false) }
        configured = client != nil
        Task { await resume() }
    }

    // MARK: auth

    private func resume() async {
        guard let client, let s = try? await client.auth.session else { return }
        signedIn(s.user)
        await setActive(true)
    }

    private func signedIn(_ user: User) { state = .signedIn(email: user.email ?? ""); userID = user.id }

    func sendCode(email: String) async {
        guard let client else { return }
        lastError = nil
        do { try await client.auth.signInWithOTP(email: email); state = .signingIn }
        catch { lastError = error.localizedDescription }
    }

    func cancelSignIn() { lastError = nil; state = .signedOut }

    func verify(email: String, code: String) async {
        guard let client else { return }
        lastError = nil
        do {
            let r = try await client.auth.verifyOTP(email: email, token: code, type: .email)
            signedIn(r.user)
            await setActive(true)
        } catch { lastError = error.localizedDescription }
    }

    func signOut() async {
        generation += 1
        debounce?.cancel(); debounce = nil
        userID = nil
        await engine?.stopRealtime()
        try? await client?.auth.signOut()
        while syncing { try? await Task.sleep(for: .milliseconds(50)) }
        do { try Self.wipe(ctx, defaults: defaults) } catch { Self.log.error("wipe: \(error.localizedDescription, privacy: .public)") }
        running = nil; snapshot = nil; lastSync = nil; lastError = nil; commandStatus = nil
        state = .signedOut
    }

    /// The phone's store is a cache of the account: signing out empties it, so the next account starts clean.
    static func wipe(_ ctx: ModelContext, defaults: UserDefaults) throws {
        func clear<M: PersistentModel>(_ t: M.Type) throws { for m in try ctx.fetch(FetchDescriptor<M>()) { ctx.delete(m) } }
        for t in StintSchema.models.reversed() { try clear(t) } // children before Project, so cascades find nothing left
        try ctx.save()
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("sync.watermark.") { defaults.removeObject(forKey: k) }
        for k in ["profileUpdatedAt", "displayName", "breakAllowanceMin"] { defaults.removeObject(forKey: k) }
    }

    // MARK: sync

    /// Foreground: realtime on plus a refresh. Background: realtime off (spec §6.9: widgets refresh on foreground).
    func setActive(_ active: Bool) async {
        guard let engine, let userID else { return }
        if active {
            await engine.startRealtime(userID: userID) { [weak self] in self?.syncSoon() }
            await refresh()
        } else {
            await engine.stopRealtime()
        }
    }

    func syncSoon() {
        guard userID != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let engine, let userID else { return }
        if syncing { again = true; return }
        syncing = true; defer { syncing = false }
        let gen = generation
        repeat {
            again = false
            do {
                try await engine.push(userID: userID)
                try await engine.pull()
                let rows = try await engine.sessionTotals(since: cal.weekInterval(containing: .now).start)
                let run = try await engine.runningSession()
                guard gen == generation else { return }
                apply(week: rows, running: run, now: .now)
                lastSync = .now; lastError = nil
            } catch {
                guard gen == generation else { return }
                lastError = error.localizedDescription
                Self.log.error("sync: \(error.localizedDescription, privacy: .public)")
            }
        } while again && gen == generation
    }

    /// Rebuilds `running` and `snapshot` from the server's session feed plus local projects and points.
    func apply(week rows: [SessionTotalsRow], running run: RunningSession?, now: Date) {
        running = run
        var sessions = rows.filter { $0.endedAt != nil }.map(\.summary)
        if let run { sessions.append(run.summary(at: now)) }
        let projects = (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.archivedAt == nil },
                                                                sortBy: [SortDescriptor(\.name)]))) ?? []
        let day = cal.dayInterval(containing: now)
        let start = day.start, end = day.end
        let ledger = ((try? ctx.fetch(FetchDescriptor<PointEvent>(predicate: #Predicate { $0.at >= start && $0.at < end }))) ?? [])
            .reduce(0) { $0 + $1.delta }
        let live = run.map { sessionPoints(totals: $0.totals(at: now), completed: false, breakOverSec: 0).reduce(0) { $0 + $1.delta } } ?? 0
        snapshot = WidgetSnapshot.build(
            projects: projects.map { .init(id: $0.id, name: $0.name, colorHex: $0.colorHex, weeklyHoursGoal: $0.weeklyHoursGoal,
                                           dailyHoursGoal: $0.dailyHoursGoal, dailyGoalDays: $0.dailyGoalDays) },
            sessions: sessions, pointsToday: ledger + live, now: now, calendar: cal)
    }

    // MARK: commands (spec §6.3)

    func send(_ cmd: SessionCommand) async {
        guard let engine, let userID, !waiting else { return }
        waiting = true; defer { waiting = false }
        commandStatus = "Waiting for your Mac…"
        do {
            let id = try await engine.sendCommand(cmd, userID: userID)
            let outcome = await awaitCommandOutcome(sleep: { try? await Task.sleep(for: .seconds(1)) },
                                                    poll: { try await engine.command(id) })
            switch outcome {
            case .accepted: commandStatus = nil; syncSoon()
            case .rejected(let reason): commandStatus = reason
            case .unreachable: commandStatus = "Mac not reachable"
            }
            if outcome != .accepted { try? await engine.deleteCommand(id) }
        } catch {
            commandStatus = "Couldn't send to your Mac: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 6: App and sign-in UI.**

`iOS/StintPhoneApp.swift`:

```swift
import SwiftUI
import SwiftData
import StintData

@main
struct StintPhoneApp: App {
    let container: ModelContainer
    @State private var sync: PhoneSync
    @Environment(\.scenePhase) private var phase

    init() {
        let c: ModelContainer
        do { c = try ModelContainer(for: Schema(StintSchema.models)) } catch { fatalError("store: \(error)") }
        container = c
        _sync = State(initialValue: PhoneSync(context: c.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sync)
                .modelContainer(container)
                .onChange(of: phase) { _, p in Task { await sync.setActive(p == .active) } }
        }
    }
}
```

`iOS/UI/RootView.swift`. Task 4 replaces the signed-in branch with the tab bar.

```swift
import SwiftUI

struct RootView: View {
    @Environment(PhoneSync.self) private var sync
    var body: some View {
        if case .signedIn = sync.state { NavigationStack { AccountView() } } else { SignInView() }
    }
}
```

`iOS/UI/SignInView.swift`:
- A `Form`.
- **Not configured:** the text "Sync not configured".
- **Otherwise:** an email `TextField` (`.textContentType(.emailAddress)`, `.keyboardType(.emailAddress)`, `.textInputAutocapitalization(.never)`), then a "Send code" button that calls `sync.sendCode`.
- **When `state == .signingIn`:** a code field (`.textContentType(.oneTimeCode)`, `.keyboardType(.numberPad)`), "Verify" (calls `sync.verify`), and "Use a different email" (`sync.cancelSignIn()`).
- **Errors:** `sync.lastError` shows in `Theme.warn`.
- **Debug hint:** under `#if DEBUG`, the footer "Local dev: the code is in Mailpit at http://127.0.0.1:54324".
- **Title:** "Stint" (`.navigationTitle` inside a `NavigationStack`).

`iOS/UI/AccountView.swift`: a `Form`, titled "Account", showing:
- the signed-in email;
- "Last synced" as `lastSync.formatted(.relative(presentation: .named))`, or the error in `Theme.warn`;
- a "Sync now" button (`await sync.refresh()`);
- a "Sign out" button. It asks first through `.confirmationDialog`: "Signing out removes Stint data from this iPhone. It stays in your account." The confirm button calls `await sync.signOut()`.

- [ ] **Step 7: README.** Add an "iPhone" section:
  - Build: `xcodegen generate && xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath DerivedData build`.
  - The app is at `DerivedData/Build/Products/Debug-iphonesimulator/Stint.app`; install it with `xcrun simctl install booted <path>`.
  - The simulator reaches the local stack at 127.0.0.1.
  - Sign in with an email code from Mailpit.
  - Release builds need the production Supabase values in `project.yml`.

- [ ] **Step 8: Run everything.**
  1. `swift test --disable-sandbox`.
  2. `xcodegen generate`, then the Mac test command: still green after the SharedUI move.
  3. The iPhone test command: `PhoneSyncTests` pass.
  4. Smoke: `xcrun simctl boot "iPhone 17"` (ignore "already booted"), install the built app, `xcrun simctl launch "iPhone 17" dev.stint.ios`. Three seconds later `xcrun simctl spawn booted launchctl list | grep dev.stint.ios` still lists it.
  5. If you can drive the simulator (tap and type), sign in with a fresh `@test.local` email using the code from Mailpit (`curl -s http://127.0.0.1:54324/api/v1/messages`, then `/api/v1/message/<ID>`). Account then shows a recent "Last synced". If you can't drive it, report that UI sign-in was not exercised.
- [ ] **Step 9: Commit** `feat(ios): iPhone app target with sign-in and sync`.

---

### Task 4: iPhone screens: Today, Tasks, Week, Rewards

**Files:**
- Create: `iOS/UI/{TodayView,TasksView,WeekView,RewardsView}.swift`, `iOS/Lists.swift`, `SharedUI/WeekBars.swift`, `iOSTests/ListsTests.swift`
- Modify: `iOS/UI/RootView.swift`

**Interfaces:**
- Consumes: `PhoneSync` (`running`, `snapshot`, `commandStatus`, `waiting`, `send`, `refresh`, `syncSoon`), `RunningSession`, `WidgetSnapshot.Line`, `EndEarlySheet`, `remainingText`, `hours`, `Ledger.redeem`, `canRedeem`, `ModelContext.saveLogged()`.
- Produces:
  - `iOS/Lists.swift`:
    - `func upNext(_ tasks: [TaskItem], limit: Int) -> [TaskItem]`: open tasks of non-archived projects, sorted by `(sort, createdAt)`.
    - `func visibleTasks(_ tasks: [TaskItem], now: Date, calendar: PeriodCalendar) -> [TaskItem]`: open tasks plus those done today, sorted by `(sort, createdAt)`.
    - `struct WeekGoals: Identifiable { var weekStart: Date; var results: [GoalResultRecord]; var id: Date { weekStart } }`
    - `func goalHistory(_ records: [GoalResultRecord]) -> [WeekGoals]`: newest week first; within a week, `week` rows before `day` rows, days in date order.
  - `SharedUI/WeekBars.swift`: `struct WeekBars: View { let lines: [WidgetSnapshot.Line] }`, used by Today and the medium widget (Task 5).
  - `RootView` with `enum Tab: Hashable { case today, tasks, week, rewards }` and `@State var tab: Tab`.

- [ ] **Step 1: Failing tests.** `iOSTests/ListsTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct ListsTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func upNextSkipsDoneAndArchivedAndSorts() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true)).mainContext
        let live = Project(name: "Live"), old = Project(name: "Old"); old.archivedAt = .now
        c.insert(live); c.insert(old)
        func task(_ title: String, _ sort: Int, _ p: Project, done: Bool = false) -> TaskItem {
            let t = TaskItem(title: title, sort: sort); c.insert(t); t.project = p; if done { t.doneAt = .now }; return t
        }
        let tasks = [task("b", 2, live), task("a", 1, live), task("x", 0, live, done: true), task("z", 0, old)]
        #expect(upNext(tasks, limit: 5).map(\.title) == ["a", "b"])
        #expect(upNext(tasks, limit: 1).map(\.title) == ["a"])
    }

    @Test func visibleTasksKeepsDoneToday() throws {
        let cal = PeriodCalendar(timeZone: utc)
        let now = date("2026-11-24T15:00:00Z")
        let open = TaskItem(title: "open", sort: 1)
        let today = TaskItem(title: "today", sort: 0); today.doneAt = date("2026-11-24T09:00:00Z")
        let yesterday = TaskItem(title: "yesterday", sort: 0); yesterday.doneAt = date("2026-11-23T09:00:00Z")
        #expect(visibleTasks([open, today, yesterday], now: now, calendar: cal).map(\.title) == ["today", "open"])
    }

    @Test func goalHistoryGroupsByWeekNewestFirst() {
        let p = UUID()
        func r(_ period: String, _ day: String) -> GoalResultRecord {
            GoalResultRecord(projectID: p, period: period, periodStart: date(day), goalKind: "hours", target: 2, actual: 1, met: false)
        }
        let h = goalHistory([r("day", "2026-11-24T00:00:00Z"), r("week", "2026-11-16T00:00:00Z"),
                             r("week", "2026-11-23T00:00:00Z"), r("day", "2026-11-23T00:00:00Z")])
        #expect(h.map(\.weekStart) == [date("2026-11-23T00:00:00Z"), date("2026-11-16T00:00:00Z")])
        #expect(h[0].results.map(\.period) == ["week", "day", "day"])
        #expect(h[0].results[1].periodStart == date("2026-11-23T00:00:00Z"))
    }
}

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
```

- [ ] **Step 2:** Run the iPhone tests. Expect a build FAIL (the helpers don't exist).

- [ ] **Step 3: `iOS/Lists.swift`.**

```swift
import Foundation
import Core
import StintData

private func byOrder(_ a: TaskItem, _ b: TaskItem) -> Bool { (a.sort, a.createdAt) < (b.sort, b.createdAt) }

/// Today's "Up next": open tasks of live projects.
func upNext(_ tasks: [TaskItem], limit: Int) -> [TaskItem] {
    Array(tasks.filter { $0.doneAt == nil && $0.project != nil && $0.project?.archivedAt == nil }.sorted(by: byOrder).prefix(limit))
}

/// Tasks tab: open tasks plus those finished today (so a mis-tap can be undone).
func visibleTasks(_ tasks: [TaskItem], now: Date, calendar: PeriodCalendar) -> [TaskItem] {
    let today = calendar.dayInterval(containing: now)
    return tasks.filter { t in t.doneAt.map { $0 >= today.start && $0 < today.end } ?? true }.sorted(by: byOrder)
}

struct WeekGoals: Identifiable {
    var weekStart: Date
    var results: [GoalResultRecord]
    var id: Date { weekStart }
}

/// Week tab: goal results grouped by week. `periodStart` is stored as UTC midnight (Mapping), so group in UTC.
func goalHistory(_ records: [GoalResultRecord]) -> [WeekGoals] {
    let utc = PeriodCalendar(timeZone: TimeZone(identifier: "UTC")!)
    return Dictionary(grouping: records) { utc.weekInterval(containing: $0.periodStart).start }
        .map { week, rs in
            WeekGoals(weekStart: week, results: rs.sorted { ($0.period == "week" ? 0 : 1, $0.periodStart) < ($1.period == "week" ? 0 : 1, $1.periodStart) })
        }
        .sorted { $0.weekStart > $1.weekStart }
}
```

- [ ] **Step 4: `SharedUI/WeekBars.swift`.**

```swift
import SwiftUI
import Core

/// This week's focused hours per project against the weekly goal (Today screen and medium widget).
struct WeekBars: View {
    let lines: [WidgetSnapshot.Line]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines) { l in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(l.name).lineLimit(1)
                        Spacer()
                        Text(l.weeklyGoalSec.map { "\(hours(l.weekFocusedSec)) / \(hours($0)) h" } ?? "\(hours(l.weekFocusedSec)) h")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    if let goal = l.weeklyGoalSec, goal > 0 {
                        ProgressView(value: min(1, Double(l.weekFocusedSec) / Double(goal))).tint(Color(hex: l.colorHex))
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 5: Screens.** All views read `@Environment(PhoneSync.self) private var sync` and `@Environment(\.modelContext) private var ctx` where needed. Projects come from `@Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name)`.

`RootView`: signed in → `TabView(selection: $tab)` with:
- `TodayView` (`Label("Today", systemImage: "sun.max")`, tag `.today`);
- `TasksView` (`"Tasks"`, `"checklist"`);
- `WeekView` (`"Week"`, `"calendar"`);
- `RewardsView` (`"Rewards"`, `"gift"`).

Otherwise it shows `SignInView`. `AccountView` moves to a toolbar button on Today.

`TodayView`: a `NavigationStack` > `List`, titled "Today", with `.refreshable { await sync.refresh() }`, and a toolbar button `Button("Account", systemImage: "person.crop.circle")` that opens `.sheet { NavigationStack { AccountView() } }`. Sections:
1. **Session.** If `sync.running` is set, show `SessionCard(running:projects:)`; otherwise `StartCard(projects:)`. Below either, `sync.commandStatus` as footnote text when non-nil.
2. **"This week".** `WeekBars(lines: sync.snapshot?.lines ?? [])`. When there are no lines, show "Projects you add on your Mac show up here."
3. **"Up next".** `upNext(openTasks, limit: 5)` as `TaskRow`s. `openTasks` is `@Query(filter: #Predicate<TaskItem> { $0.doneAt == nil })`. When the list is empty, show "No open tasks."

`SessionCard` (in TodayView.swift):

```swift
struct SessionCard: View {
    let running: RunningSession
    let projects: [Project]
    @Environment(PhoneSync.self) private var sync
    @State private var endSheet = false

    var body: some View {
        let project = projects.first { $0.id == running.projectID }
        let task = running.firstTaskID.flatMap { id in project?.tasks.first { $0.id == id } }
        let stale = running.isStale(at: .now)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: project?.colorHex ?? "#8E8E93")).frame(width: 10, height: 10)
                Text(project?.name ?? "Session").font(.headline)
            }
            if let task { Text(task.title).foregroundStyle(.secondary) }
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                Text(remainingText(running.remainingSec(at: tl.date))).font(.system(size: 44, weight: .semibold).monospacedDigit())
            }
            Text(stale ? "Mac last seen \(running.lastSeen.formatted(date: .omitted, time: .shortened))"
                       : running.onBreak ? "On break" : running.offTask ? "Off task" : "Focused")
                .font(.subheadline).foregroundStyle(running.offTask || stale ? Theme.warn : .secondary)
            HStack {
                Button(running.onBreak ? "Resume" : "Take a break") {
                    Task { await sync.send(running.onBreak ? .resume : .takeBreak) }
                }.buttonStyle(.borderedProminent)
                Button("End early…") { endSheet = true }.buttonStyle(.bordered)
            }
            .disabled(sync.waiting || stale)
        }
        .sheet(isPresented: $endSheet) {
            // Spec §6.11: the same 60 s cooldown + reason, on the phone, before the command is sent.
            EndEarlySheet(onEnd: { reason in endSheet = false; Task { await sync.send(.endEarly(reason: reason)) } },
                          onCancel: { endSheet = false })
                .presentationDetents([.medium, .large])
        }
    }
}
```

`StartCard` (in TodayView.swift):
- State: `@State projectID: UUID?` (set to `projects.first?.id` in `.onAppear` when nil), `@State minutes = 50`, `@State taskID: UUID?` (reset to nil in `.onChange(of: projectID)`).
- Rows:
  - the headline "Start on your Mac";
  - a "Project" `Picker` (tags `Optional(p.id)`);
  - a segmented "Length" `Picker` over `[25, 50, 90]` showing "\(m) min";
  - a "First task" `Picker`: "None" (`UUID?.none`), then `upNext(project.tasks, limit: 50)`;
  - a `.borderedProminent` "Start" button that calls `await sync.send(.start(projectID:plannedMin:firstTaskID:))`. It is disabled when there is no project or while `sync.waiting`.

`TasksView` (`NavigationStack` > `List`, titled "Tasks"):
- One `Section(p.name)` per project, holding `visibleTasks(p.tasks, now: .now, calendar: sync.cal)` as `TaskRow`s, then an `AddTaskField(project: p)`.
- With no projects, show "Add a project on your Mac first."
- `TaskRow(task:)` is a `.plain` button:
  - the icon is `circle` or `checkmark.circle.fill`;
  - the title is struck through when done;
  - the estimate shows as "\(m)m" in secondary when set.

  Tapping it sets `task.doneAt = task.doneAt == nil ? .now : nil` and `task.updatedAt = .now`, then calls `ctx.saveLogged()` and `sync.syncSoon()`.
- `AddTaskField(project:)` is a `TextField("Add a task", text: $title)`. On submit it trims the title and ignores it if empty. Otherwise it inserts `TaskItem(title:sort: (project.tasks.map(\.sort).max() ?? -1) + 1)` with `item.project = project`, calls `ctx.saveLogged()`, clears the field and calls `sync.syncSoon()`.

`WeekView` (`NavigationStack` > `List`, titled "Week"):
- Data: `@Query(sort: \GoalResultRecord.periodStart, order: .reverse) var results` and `@Query var allProjects: [Project]` (archived ones included, for names).
- One section per `goalHistory(results)` entry, headed "Week of \(weekStart.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))".
- Each result is a `GoalLine` row:
  - "\(project name) · \(period == "week" ? "week" : weekday of periodStart, formatted in .gmt) \(goalKind)";
  - on the trailing side, "\(actual) / \(target)" with " h" for hours (`%g` formatting);
  - the icon is `checkmark.circle.fill` in green when `met`, otherwise `xmark.circle` in secondary.

  Do not name the view `GoalResultRow`; StintData already has that type.
- With no results, show "Goal results appear after each day and week closes."

`RewardsView` (`NavigationStack` > `List`, titled "Rewards"):
- Data: `@Query var events: [PointEvent]` (balance = sum of `delta`) and `@Query(filter: #Predicate<Treat> { $0.archivedAt == nil }, sort: \Treat.cost) var treats`.
- **Section 1:** `LabeledContent("Balance", value: "\(balance)")` and `LabeledContent("Today", value: "\(sync.snapshot?.pointsToday ?? 0)")`.
- **"Treats" section:** for each treat, the name plus a `.bordered` "\(cost) pts" button. The button is disabled when `!canRedeem(cost:balance:)` (spec §6.7) and otherwise sets `@State pending: Treat?`.
  - A `.confirmationDialog("Redeem \(name)?")` holds "Redeem for \(cost) points". It calls `try Ledger.redeem(ctx, treat:, at: .now)` and then `sync.syncSoon()`; on error it logs via `PhoneSync.log`.
  - With no treats, show "Add treats on your Mac."

- [ ] **Step 6:** Run the iPhone tests: `ListsTests` and `PhoneSyncTests` pass. Install and launch on the simulator as in Task 3 Step 8; the app is still running 3 s later.
- [ ] **Step 7: End-to-end check** (needs the Mac app and the phone signed in to the same local account; drive both UIs if you can, otherwise report it as not exercised):
  1. Start a 25 min session from the phone. Within ~2 s the Mac starts it, the phone's Start card turns into the session card, and the countdown matches the Mac's within a second or two.
  2. Take a break, then resume. The card shows "On break" within a few seconds and the countdown holds still while on break.
  3. Start again from the phone while a session runs. "A session is already running on your Mac." appears.
  4. End early from the phone. The sheet counts 60 s and needs a reason, then the Mac session ends early.
  5. Quit the Mac app and send a command. "Mac not reachable" appears after ~10 s and no `session_command` row is left.
  6. Add a task on the phone. It appears on the Mac within ~30 s.
- [ ] **Step 8: Commit** `feat(ios): Today, Tasks, Week and Rewards screens`.

---

### Task 5: Widgets, App Group snapshot, start link

**Files:**
- Create: `Widgets/StintWidgets.swift`, `SharedUI/SnapshotStore.swift`, `SharedUI/StartLink.swift`, `iOSTests/WidgetPlumbingTests.swift`
- Modify: `project.yml`, `iOS/PhoneSync.swift` (publish), `iOS/UI/RootView.swift` (`onOpenURL`)

**Interfaces:**
- Consumes: `WidgetSnapshot` (`asOf`, `startProjectID`, `todayFocusedSec`, `todayGoalSec`), `WeekBars`, `hours`, `PhoneSync.send/snapshot`.
- Produces:
  - `enum SnapshotStore { static let appGroup = "group.dev.stint"; static var defaultURL: URL?; static func write(_: WidgetSnapshot, to: URL) throws; static func read(from: URL) -> WidgetSnapshot? }`
  - `enum StartLink { static let plannedMin = 50; static func url(projectID: UUID) -> URL; static func parse(_ url: URL) -> UUID? }`

**Simulator and App Group:** simulator builds are ad-hoc signed and carry their entitlements, and the simulator does not check provisioning, so `containerURL(forSecurityApplicationGroupIdentifier:)` is expected to work without a team. The `appGroupAvailable` test below checks it.
- **If that test fails:** run `codesign -d --entitlements - DerivedData/Build/Products/Debug-iphonesimulator/Stint.app` and record whether `com.apple.security.application-groups` is present. Mark the test `.disabled("App Group container needs a signing team — see Task 6")` and keep the code as written. The app logs once and skips the write, and the widgets show "Open Stint". Report it as blocked on the user.
- **On a device:** the App Group always needs the team (Task 6).

- [ ] **Step 1: Failing tests.** `iOSTests/WidgetPlumbingTests.swift`:

```swift
import Foundation
import Testing
import Core
@testable import Stint

@Suite struct WidgetPlumbingTests {
    @Test func startLinkRoundTrips() {
        let id = UUID()
        #expect(StartLink.parse(StartLink.url(projectID: id)) == id)
        #expect(StartLink.parse(URL(string: "stint://today")!) == nil)
        #expect(StartLink.parse(URL(string: "https://start?project=\(id)")!) == nil)
        #expect(StartLink.parse(URL(string: "stint://start?project=nope")!) == nil)
    }

    @Test func snapshotFileRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID()).json")
        let s = WidgetSnapshot.build(projects: [], sessions: [], pointsToday: 7, now: .now, calendar: PeriodCalendar(timeZone: .current))
        try SnapshotStore.write(s, to: url)
        #expect(SnapshotStore.read(from: url) == s)
        #expect(SnapshotStore.read(from: url.appending(path: "missing")) == nil)
    }

    @Test func appGroupAvailable() {
        #expect(SnapshotStore.defaultURL != nil)
    }
}
```

- [ ] **Step 2:** Run the iPhone tests. Expect a build FAIL.

- [ ] **Step 3: Shared plumbing.** `SharedUI/SnapshotStore.swift`:

```swift
import Foundation
import Core

/// The widgets' only data: one JSON file in the App Group container, written by the app after each refresh.
enum SnapshotStore {
    static let appGroup = "group.dev.stint"

    /// nil when the App Group container isn't available (entitlement not granted).
    static var defaultURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "widget-snapshot.json")
    }

    static func write(_ s: WidgetSnapshot, to url: URL) throws { try JSONEncoder().encode(s).write(to: url, options: .atomic) }

    static func read(from url: URL) -> WidgetSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }
}
```

`SharedUI/StartLink.swift`:

```swift
import Foundation

/// Start widget → app: `stint://start?project=<uuid>`. The app sends a 50 min start (spec §6.9) and shows the outcome.
enum StartLink {
    static let plannedMin = 50

    static func url(projectID: UUID) -> URL { URL(string: "stint://start?project=\(projectID.uuidString)")! }

    static func parse(_ url: URL) -> UUID? {
        guard url.scheme == "stint", url.host() == "start",
              let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "project" })?.value
        else { return nil }
        return UUID(uuidString: v)
    }
}
```

- [ ] **Step 4: App side.** In `PhoneSync`, `import WidgetKit` and add:

```swift
    /// Hands the snapshot to the widgets (spec §6.9: refresh on foreground and on realtime updates).
    private func publish() {
        guard let url = SnapshotStore.defaultURL else {
            Self.log.notice("App Group unavailable; widgets keep their placeholder")
            return
        }
        do {
            if let s = snapshot { try SnapshotStore.write(s, to: url) } else { try? FileManager.default.removeItem(at: url) }
        } catch { Self.log.error("snapshot: \(error.localizedDescription, privacy: .public)") }
        WidgetCenter.shared.reloadAllTimelines()
    }
```

Call `publish()` in `refresh()` right after `lastSync = .now; lastError = nil`, and at the end of `signOut()`. After sign-out, the widgets go back to "Open Stint".

In `RootView`, on the outermost view:

```swift
        .onOpenURL { url in
            tab = .today
            if let id = StartLink.parse(url) {
                Task { await sync.send(.start(projectID: id, plannedMin: StartLink.plannedMin, firstTaskID: nil)) }
            }
        }
```

`send` already ignores the call when signed out.

- [ ] **Step 5: `Widgets/StintWidgets.swift`.**

```swift
import WidgetKit
import SwiftUI
import Core

struct Entry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot? }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(load()) }
    /// Spec §6.9: otherwise refresh via the timeline every 15 min. The app reloads timelines after each sync.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
    private func load() -> Entry {
        let now = Date.now
        let s = SnapshotStore.defaultURL.flatMap(SnapshotStore.read(from:))
        return Entry(date: now, snapshot: s?.asOf(now, calendar: PeriodCalendar(timeZone: .current)))
    }
}

private struct OpenStint: View {
    var body: some View { Text("Open Stint to sign in").font(.caption).foregroundStyle(.secondary) }
}

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "week", provider: Provider()) { e in
            Group {
                if let s = e.snapshot {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This week").font(.caption.bold())
                        WeekBars(lines: Array(s.lines.prefix(4)))
                        Spacer(minLength: 0)
                    }
                } else { OpenStint() }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("This week")
        .description("Hours per project against your weekly goals.")
        .supportedFamilies([.systemMedium])
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: Provider()) { e in
            Group {
                if let s = e.snapshot {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today").font(.caption.bold())
                        Text("\(hours(s.todayFocusedSec)) h").font(.title.bold()).monospacedDigit()
                        Text(s.todayGoalSec > 0 ? "of \(hours(s.todayGoalSec)) h goal" : "no daily goal today")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text("\(s.pointsToday) pts today").font(.caption.bold())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else { OpenStint() }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Focused time against today's goals, and points.")
        .supportedFamilies([.systemSmall])
    }
}

struct StartWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "start", provider: Provider()) { e in
            Group {
                if let s = e.snapshot, let id = s.startProjectID, let l = s.lines.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Furthest behind").font(.caption).foregroundStyle(.secondary)
                        Text(l.name).font(.headline).lineLimit(2)
                        Spacer(minLength: 0)
                        Label("Start \(StartLink.plannedMin) min", systemImage: "play.fill").font(.caption.bold())
                            .foregroundStyle(Color(hex: l.colorHex))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetURL(StartLink.url(projectID: id))
                } else if e.snapshot != nil {
                    Text("Daily goals done").font(.headline)
                } else { OpenStint() }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Start")
        .description("Starts a 50 min Mac session on the project furthest behind today.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct StintWidgets: WidgetBundle {
    var body: some Widget { WeekWidget(); TodayWidget(); StartWidget() }
}
```

- [ ] **Step 6: `project.yml`.**
  - In `StintPhone`, add `- target: StintWidgets` to `dependencies` (XcodeGen embeds app extensions).
  - Add to its `info.properties`:

```yaml
        CFBundleURLTypes:
          - CFBundleURLName: dev.stint.ios
            CFBundleURLSchemes: [stint]
```

  - Add to the target:

```yaml
    entitlements:
      path: iOS/Stint.entitlements
      properties:
        com.apple.security.application-groups: [group.dev.stint]
```

  New target:

```yaml
  StintWidgets:
    type: app-extension
    platform: iOS
    sources:
      - Widgets
      - SharedUI/Theme.swift
      - SharedUI/WeekBars.swift
      - SharedUI/SnapshotStore.swift
      - SharedUI/StartLink.swift
    dependencies:
      - package: Core
    info:
      path: Widgets/Info.plist
      properties:
        CFBundleDisplayName: Stint
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
    entitlements:
      path: Widgets/StintWidgets.entitlements
      properties:
        com.apple.security.application-groups: [group.dev.stint]
    settings:
      base:
        PRODUCT_NAME: StintWidgets
        PRODUCT_BUNDLE_IDENTIFIER: dev.stint.ios.widgets
        TARGETED_DEVICE_FAMILY: "1"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
```

- [ ] **Step 7:** Run `xcodegen generate` and the iPhone tests. `WidgetPlumbingTests` pass, or `appGroupAvailable` is handled as described above. Then:
  1. Install and launch the app.
  2. Confirm the extension is embedded: `ls DerivedData/Build/Products/Debug-iphonesimulator/Stint.app/PlugIns` lists `StintWidgets.appex`.
  3. Send the start link: `xcrun simctl openurl booted "stint://start?project=<a local project id>"`. The app comes forward on Today and shows "Waiting for your Mac…" and then an outcome ("Mac not reachable" if the Mac isn't running).
  4. If you can drive the simulator, add the three widgets to the home screen and check they show data after the app has synced. Otherwise report that widget rendering was not exercised.
- [ ] **Step 8: Commit** `feat(ios): week, today and start widgets`.

---

### Task 6: Sign in with Apple and device signing. BLOCKED on the user

**Do not start until the user has:**
1. Signed in to Xcode (Settings → Accounts) with the paid developer account.
2. Given the 10-character Team ID.
3. (For simulator testing) Signed in to an Apple ID in the simulator's Settings.

If any of these is missing, stop and report "Task 6 blocked: needs Team ID / Xcode sign-in". Do not commit partial work. Tasks 1–5 don't depend on this one.

**Files:**
- Create: `iOS/AppleNonce.swift`, `iOSTests/AppleNonceTests.swift`
- Modify: `project.yml`, `iOS/PhoneSync.swift`, `iOS/UI/SignInView.swift`, `supabase/config.jsonc`

**Interfaces:**
- Produces:
  - `enum AppleNonce { static func random() -> String; static func sha256(_ s: String) -> String }`: both return lowercase hex; `random()` is 32 random bytes.
  - `PhoneSync.signInWithApple(_ result: Result<ASAuthorization, Error>, nonce: String) async`.

- [ ] **Step 1: Failing test** `iOSTests/AppleNonceTests.swift`:

```swift
import Testing
@testable import Stint

@Suite struct AppleNonceTests {
    @Test func randomIs64HexAndUnique() {
        let a = AppleNonce.random(), b = AppleNonce.random()
        #expect(a.count == 64 && a.allSatisfy(\.isHexDigit) && a != b)
    }
    @Test func sha256KnownVector() {
        #expect(AppleNonce.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
```

- [ ] **Step 2: Implement.** `iOS/AppleNonce.swift`:

```swift
import Foundation
import CryptoKit

/// Sign in with Apple nonce: Apple gets the SHA-256, Supabase gets the raw value and checks they match.
enum AppleNonce {
    static func random() -> String { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    static func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
```

In `PhoneSync`, `import AuthenticationServices` and add:

```swift
    func signInWithApple(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        guard let client else { return }
        lastError = nil
        do {
            let auth = try result.get()
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else {
                lastError = "Apple didn't return an identity token."; return
            }
            let s = try await client.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: token, nonce: nonce))
            signedIn(s.user)
            await setActive(true)
        } catch { lastError = error.localizedDescription }
    }
```

In `SignInView`, put this above the email fields:

```swift
            SignInWithAppleButton(.signIn) { req in
                nonce = AppleNonce.random()
                req.requestedScopes = [.email]
                req.nonce = AppleNonce.sha256(nonce)
            } onCompletion: { result in
                Task { await sync.signInWithApple(result, nonce: nonce) }
            }
            .frame(height: 44)
```

Here `nonce` is `@State private var nonce = ""`. Add a footnote under it: "Choose Share My Email to use the same account as your Mac."

- [ ] **Step 3: Signing and backend config.**
  - `project.yml`: add `STINT_TEAM_ID: "<the user's Team ID>"` to the top-level `settings.base`. Team IDs are not secret.
  - In `StintPhone` and `StintWidgets`, replace `CODE_SIGN_IDENTITY: "-"` / `CODE_SIGN_STYLE: Manual` with `CODE_SIGN_STYLE: Automatic` and `DEVELOPMENT_TEAM: $(STINT_TEAM_ID)`. Do the same in `StintPhoneTests`.
  - Add `com.apple.developer.applesignin: [Default]` to `StintPhone`'s entitlements properties.
  - Building with `-allowProvisioningUpdates` lets Xcode register the App IDs, the App Group and the capability.
  - `supabase/config.jsonc`, `auth.external.apple`: set `"enabled": true`, `"client_id": "dev.stint.ios"` and `"secret": ""`. The native ID-token flow needs no secret.
  - Then `supabase stop && supabase start`.
- [ ] **Step 4:** Build and test:

  `xcodegen generate && xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath DerivedData -allowProvisioningUpdates test`

  `AppleNonceTests` pass. If Task 5 disabled `appGroupAvailable`, re-enable it now; it must pass.
- [ ] **Step 5: Manual check (the user or an implementer who can drive the simulator):**
  1. Tap Sign in with Apple and choose Share My Email.
  2. The app reaches Today.
  3. `select provider from auth.identities` (psql) shows `apple` for that user. If the same email was used with email codes, the identity is on the same user.
- [ ] **Step 6: Commit** `feat(ios): Sign in with Apple and team signing`.

---

## Done when

- `cd Shared && swift test --disable-sandbox` passes, with the integration tests passing when the env vars are set.
- The Mac and iPhone `xcodebuild … test` runs pass, and `supabase test db` passes (5 files).
- On the simulator, signed in to the local stack:
  - Today shows this week's bars and the running Mac session, with a live countdown and state;
  - start, break, resume and end early (after the 60 s sheet) reach the Mac;
  - a rejected command shows the Mac's reason, and an unanswered one shows "Mac not reachable" after 10 s and leaves no row;
  - tasks added or ticked on the phone reach the Mac; redeeming a treat lowers the balance on both;
  - the three widgets show the snapshot, and the Start widget opens the app and sends a 50 min start.
- Release builds show "Sync not configured" until production values are set.
- Task 6 is done, or reported as blocked on the user.

**Manual release checklist additions** (spec §8 "Widget refresh"):
- Widgets update within seconds of a Mac change while the app is open, and every 15 min otherwise.
- After sign-out they show "Open Stint".
