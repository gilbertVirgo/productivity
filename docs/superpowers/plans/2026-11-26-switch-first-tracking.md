# Switch-first Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Pomodoro sessions with one always-current project that you switch between in one hotkey chord or one click. Switch suggestions, off-Mac projects and an iPhone Desk mode come with it.

**Architecture:**
- A `session` row becomes one *stretch* on one project. Switching closes the open row and inserts a new one at the same second.
- A pure Core `Tracker` owns the current stretch: switching, stopping, breaks, idle and sleep, the midnight split, and off-Mac projects.
- A pure Core `SwitchSuggester` decides when the app in front belongs to another project.
- The Mac `AppState` drives both, and writes rows through `Ledger.openStretch`/`closeStretch`.
- Points are written from running daily totals (`dayPoints`).
- The server's goal maths (`session_totals`, `close_periods`, `share_data`) is unchanged, because stretches are still sessions.
- The phone switches by inserting `session_command` rows (`switch`, `stop`, `break_start`, `break_end`).
- The Live Activity lasts one tracking run. Each switch is a push update.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftData, AppKit + Carbon `RegisterEventHotKey`, ActivityKit/WidgetKit (iOS 17.2+), Postgres + pgTAP, Deno 2 edge function.

**Spec:** `docs/superpowers/specs/2026-11-26-switch-first-tracking-design.md`. Mockups: https://claude.ai/artifact/9EpTZaSDz5HDYc3vqtAeUh

## Global Constraints

- Work on `main`. Commit after each task. Never create branches or worktrees.
- SwiftPM tests: `cd Shared && swift test --disable-sandbox`. The flag is mandatory.
- Mac tests: `xcodebuild -scheme StintMac -derivedDataPath /private/tmp/claude-501/dd2 PRODUCT_BUNDLE_IDENTIFIER=dev.stint.mac.alt test 2>&1 | grep -E 'error:|Test run with|\*\* '`
- iOS tests: `xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /private/tmp/claude-501/dd-ios test 2>&1 | grep -E 'error:|Test run with|\*\* '`
- Disk is tight. Delete `/private/tmp/claude-501/dd*` build folders when a task is done.
- After adding, deleting or renaming any Swift file, run `xcodegen generate` before building. The widget target lists its `SharedUI` files by name in `project.yml`.
- pgTAP: `supabase test db` against the local stack. If realtime loops on `ReplicationSlotBeingUsed`, run `supabase stop && supabase start`.
- Deno: `cd supabase/functions/push-activity && deno test`.
- Never read or create `supabase/functions/.env`. Never handle the APNs key.
- Hosted Supabase CLI commands need `--remote` and `--yes`. Never run `supabase config push`.
- Copy and names come from the spec:
  - hotkey `⌃⌥Space`;
  - dwell 10 s;
  - off-task grace 15 s (unchanged);
  - double-press window 0.4 s;
  - Undo shows for 10 s;
  - help line "Idle and off-task checks are off while this project is current.";
  - "Update Stint on your phone." for old phone commands;
  - Desk deep link `stint://desk`.
- Tasks stay in the database and in code. Only their UI entry points go (spec §2 "Hidden").

**Ruling baked into this plan (spec deviation):**
- **Switcher shortcuts are ⌘S (stop) and ⌘B (break), not bare S and B.** Spec §6.3 asks for typing to filter, and a bare S would stop tracking while you type "Sermon".
- **`SessionRecord.plannedMin` stays non-optional.** A stretch stores `0`, and the wire maps `0` to `null`. Changing a SwiftData property to optional risks a store migration, for no user benefit.
- **`push-activity` sends updates and ends to every activity token the user has, ignoring `session_id`.** There is only ever one tracking run. A phone-started activity carries a stretch id that the Mac's pushes would never match.
- **The Live Activity clock counts focused time *this stretch*.** That's the spec's "stretch start", and both sides can compute it from the session feed alone.

---

### Task 1: Migration and pgTAP

**Files:**
- Create: `supabase/migrations/20261126000011_switch_first.sql`
- Create: `supabase/tests/07_switch_first_test.sql`

**Interfaces:**
- Produces:
  - `session.planned_min` nullable;
  - `session.end_kind` in (`completed`, `early`, `switched`, `stopped`);
  - `project.icon text null`, `project.short_name text null`, `project.off_mac boolean not null default false`;
  - `session_command.kind` also accepts `switch`, `stop`, `break_start`, `break_end`.

- [ ] **Step 1: Write the failing test** `supabase/tests/07_switch_first_test.sql`:

```sql
begin;
select plan(9);
select col_is_null('public', 'session', 'planned_min', 'stretches have no planned length');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'session_end_kind_check') like '%switched%',
          'end_kind allows switched');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'session_end_kind_check') like '%stopped%',
          'end_kind allows stopped');
select has_column('public', 'project', 'icon', 'project icon');
select has_column('public', 'project', 'short_name', 'project short name');
select col_not_null('public', 'project', 'off_mac', 'off_mac is required');
select col_default_is('public', 'project', 'off_mac', 'false', 'off_mac defaults to false');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'session_command_kind_check') like '%''switch''%',
          'phone can send switch');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'session_command_kind_check') like '%''break_end''%',
          'phone can send break_end');
select * from finish();
rollback;
```

- [ ] **Step 2: Run it and check it fails.** Run `supabase test db`. Expected: `07_switch_first_test.sql` fails at test 1 (`planned_min` is not null).

- [ ] **Step 3: Write the migration** `supabase/migrations/20261126000011_switch_first.sql`:

```sql
-- Switch-first tracking (docs/superpowers/specs/2026-11-26-switch-first-tracking-design.md §3).
-- A session row is now one stretch on one project. Old Pomodoro rows keep their planned_min and end_kind.
alter table public.session alter column planned_min drop not null;
alter table public.session drop constraint session_end_kind_check;
alter table public.session add constraint session_end_kind_check
  check (end_kind in ('completed', 'early', 'switched', 'stopped'));

alter table public.project
  add column icon text,
  add column short_name text,
  add column off_mac boolean not null default false;

-- Old kinds stay valid so an old phone's insert doesn't fail; the Mac rejects them with "Update Stint on your phone."
alter table public.session_command drop constraint session_command_kind_check;
alter table public.session_command add constraint session_command_kind_check
  check (kind in ('start', 'break', 'resume', 'end_early_request', 'switch', 'stop', 'break_start', 'break_end'));
```

- [ ] **Step 4: Apply it and run the tests.**
  - Run `supabase migration up`, then `supabase test db`.
  - Expected: all suites pass, including `00`–`06` unchanged. That proves `session_totals` and `close_periods` still hold.

- [ ] **Step 5: Push to hosted.** The apps decode `off_mac`, so the hosted DB must have it before any app build from Task 5 runs against it.
  - Run `supabase db push --remote --yes`.
  - Then run `supabase db query --remote --read-only "select column_name from information_schema.columns where table_name='project' and column_name='off_mac'"`.
  - Expected: one row.

- [ ] **Step 6: Commit.**

```bash
git add supabase/migrations/20261126000011_switch_first.sql supabase/tests/07_switch_first_test.sql
git commit -m "feat(db): stretches, project icon/short name/off-Mac, switch commands

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `SwitchSuggester` (Core)

**Files:**
- Modify: `Shared/Sources/Core/Allowlist.swift` (add two methods to `Allowlist`)
- Create: `Shared/Sources/Core/SwitchSuggester.swift`
- Test: `Shared/Tests/CoreTests/SwitchSuggesterTests.swift`

**Interfaces:**
- Produces:
  - `Allowlist.listsApp(_ bundleID: String) -> Bool`
  - `Allowlist.listsDomain(of host: String) -> Bool`
  - `SwitchSuggester` with:
    - `init(dwell: TimeInterval = 10)`
    - `static func owners(bundleID: String, host: String?, among: [Candidate]) -> [UUID]`
    - `mutating func observe(bundleID: String, host: String?, current: UUID?, projects: [Candidate], at: Date) -> Suggestion?`
    - `mutating func tick(at: Date) -> Suggestion?`
    - `mutating func mute(_ s: Suggestion)`
    - `mutating func reset()`
    - `private(set) var pending: Suggestion?`
  - `SwitchSuggester.Candidate(id: UUID, allowlist: Allowlist)`
  - `SwitchSuggester.Suggestion { projectID: UUID; since: Date; bundleID: String; host: String? }` (Equatable)

- [ ] **Step 1: Write the failing test** `Shared/Tests/CoreTests/SwitchSuggesterTests.swift`:

```swift
import Foundation
import Testing
@testable import Core

@Suite struct SwitchSuggesterTests {
    let a = UUID(), b = UUID()
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    var projects: [SwitchSuggester.Candidate] {
        [.init(id: a, allowlist: Allowlist(entries: [AllowEntry(.app, "com.apple.Safari"), AllowEntry(.app, "com.microsoft.VSCode"),
                                                       AllowEntry(.app, "com.anthropic.claude")], ownBundleID: "dev.stint.mac")),
         .init(id: b, allowlist: Allowlist(entries: [AllowEntry(.domain, "figma.com"), AllowEntry(.app, "com.anthropic.claude")],
                                           ownBundleID: "dev.stint.mac"))]
    }

    @Test func suggestsTheSingleOwnerAfterDwellOnce() {
        var s = SwitchSuggester()
        #expect(s.observe(bundleID: "com.apple.Safari", host: "www.figma.com", current: a, projects: projects, at: t0) == nil)
        #expect(s.tick(at: t0 + 9) == nil)
        let got = s.tick(at: t0 + 10)
        #expect(got?.projectID == b)
        #expect(got?.since == t0)
        #expect(s.tick(at: t0 + 30) == nil)
    }

    @Test func aGlanceShorterThanDwellIsForgotten() {
        var s = SwitchSuggester()
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: a, projects: projects, at: t0)
        _ = s.observe(bundleID: "com.microsoft.VSCode", host: nil, current: a, projects: projects, at: t0 + 5)
        #expect(s.tick(at: t0 + 20) == nil)
        #expect(s.pending == nil)
    }

    @Test func aSharedAppIsSilent() {
        var s = SwitchSuggester()
        _ = s.observe(bundleID: "com.anthropic.claude", host: nil, current: a, projects: projects, at: t0)
        #expect(s.tick(at: t0 + 60) == nil)
    }

    @Test func theCurrentProjectsOwnAppIsSilent() {
        var s = SwitchSuggester()
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: b, projects: projects, at: t0)
        #expect(s.tick(at: t0 + 60) == nil)
    }

    @Test func aDomainMatchBeatsAnAppMatch() {
        #expect(SwitchSuggester.owners(bundleID: "com.apple.Safari", host: "www.figma.com", among: projects) == [b])
        #expect(SwitchSuggester.owners(bundleID: "com.apple.Safari", host: "github.com", among: projects) == [a])
        #expect(SwitchSuggester.owners(bundleID: "com.apple.Safari", host: nil, among: projects) == [a])
    }

    @Test func alwaysAllowedAndUnlistedAppsHaveNoOwner() {
        #expect(SwitchSuggester.owners(bundleID: "dev.stint.mac", host: nil, among: projects).isEmpty)
        #expect(SwitchSuggester.owners(bundleID: "com.apple.loginwindow", host: nil, among: projects).isEmpty)
        #expect(SwitchSuggester.owners(bundleID: "com.spotify.client", host: nil, among: projects).isEmpty)
    }

    @Test func stayMutesThatSiteUntilReset() throws {
        var s = SwitchSuggester()
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: a, projects: projects, at: t0)
        let got = try #require(s.tick(at: t0 + 10))
        s.mute(got)
        _ = s.observe(bundleID: "com.microsoft.VSCode", host: nil, current: a, projects: projects, at: t0 + 20)
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: a, projects: projects, at: t0 + 30)
        #expect(s.tick(at: t0 + 60) == nil)
        s.reset()
        _ = s.observe(bundleID: "com.apple.Safari", host: "figma.com", current: a, projects: projects, at: t0 + 70)
        #expect(s.tick(at: t0 + 80)?.projectID == b)
    }
}
```

- [ ] **Step 2: Run it and check it fails.** Run `cd Shared && swift test --disable-sandbox --filter SwitchSuggesterTests`. Expected: FAIL, `cannot find 'SwitchSuggester' in scope`.

- [ ] **Step 3: Add the `Allowlist` helpers.** Put these inside `public struct Allowlist`, after `isOnTask`:

```swift
    /// The app is on the list by bundle ID. Always-allowed apps (Stint, loginwindow, screen saver) don't count.
    public func listsApp(_ bundleID: String) -> Bool { entries.contains(AllowEntry(.app, bundleID)) }

    /// `host` equals, or is a subdomain of, a listed domain.
    public func listsDomain(of host: String) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return entries.contains { $0.kind == .domain && !$0.value.isEmpty && (h == $0.value || h.hasSuffix("." + $0.value)) }
    }
```

- [ ] **Step 4: Write** `Shared/Sources/Core/SwitchSuggester.swift`:

```swift
import Foundation

/// Spec 2026-11-26 §5.4: when the app or site in front belongs to exactly one other project, suggest switching to it
/// once it has been in front for `dwell` seconds. Pure: the caller feeds observations and clock ticks.
public struct SwitchSuggester: Sendable {
    public struct Candidate: Sendable {
        public var id: UUID
        public var allowlist: Allowlist
        public init(id: UUID, allowlist: Allowlist) { self.id = id; self.allowlist = allowlist }
    }

    public struct Suggestion: Equatable, Sendable {
        public var projectID: UUID
        /// When the app came to the front. An accepted switch is backdated to here.
        public var since: Date
        public var bundleID: String
        public var host: String?
    }

    let dwell: TimeInterval
    public private(set) var pending: Suggestion?
    var fired = false
    var muted: Set<String> = []

    public init(dwell: TimeInterval = 10) { self.dwell = dwell }

    /// Projects that own what's in front. A domain match beats an app match; apps nobody lists have no owner.
    public static func owners(bundleID: String, host: String?, among projects: [Candidate]) -> [UUID] {
        if Browsers.supported.contains(bundleID.lowercased()), let host {
            let byDomain = projects.filter { $0.allowlist.listsDomain(of: host) }.map(\.id)
            if !byDomain.isEmpty { return byDomain }
        }
        return projects.filter { $0.allowlist.listsApp(bundleID) }.map(\.id)
    }

    /// Call when the app or tab in front changes. Returns a suggestion only once it is due.
    public mutating func observe(bundleID: String, host: String?, current: UUID?, projects: [Candidate], at now: Date) -> Suggestion? {
        let owners = Self.owners(bundleID: bundleID, host: host, among: projects)
        guard owners.count == 1, let owner = owners.first, owner != current,
              !muted.contains(Self.key(bundleID: bundleID, host: host)) else {
            pending = nil; fired = false
            return nil
        }
        if let p = pending, p.projectID == owner, p.bundleID == bundleID, p.host == host { return tick(at: now) }
        pending = Suggestion(projectID: owner, since: now, bundleID: bundleID, host: host)
        fired = false
        return tick(at: now)
    }

    public mutating func tick(at now: Date) -> Suggestion? {
        guard let p = pending, !fired, now.timeIntervalSince(p.since) >= dwell else { return nil }
        fired = true
        return p
    }

    /// "Stay on X": don't suggest for this app or site again until `reset()`.
    public mutating func mute(_ s: Suggestion) {
        muted.insert(Self.key(bundleID: s.bundleID, host: s.host))
        pending = nil
    }

    /// A new stretch began: forget mutes and anything pending.
    public mutating func reset() { muted = []; pending = nil; fired = false }

    static func key(bundleID: String, host: String?) -> String {
        if Browsers.supported.contains(bundleID.lowercased()), let host { return "domain:" + host.lowercased() }
        return "app:" + bundleID.lowercased()
    }
}
```

- [ ] **Step 5: Run the tests.** Run `cd Shared && swift test --disable-sandbox --filter SwitchSuggesterTests`. Expected: 7 tests pass. Then run `cd Shared && swift test --disable-sandbox`. Expected: everything passes.

- [ ] **Step 6: Commit.**

```bash
git add Shared/Sources/Core/Allowlist.swift Shared/Sources/Core/SwitchSuggester.swift Shared/Tests/CoreTests/SwitchSuggesterTests.swift
git commit -m "feat(core): SwitchSuggester for apps another project owns

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `dayPoints` (Core)

**Files:**
- Modify: `Shared/Sources/Core/Points.swift`
- Modify: `Shared/Sources/Core/SessionAccounting.swift` (add `+` for `SessionTotals`)
- Test: `Shared/Tests/CoreTests/PointsTests.swift` (append)

**Interfaces:**
- Produces:
  - `func dayPoints(today: SessionTotals, allowanceSec: Int, written: [PointKind: Int]) -> [PointLine]`
  - `static func + (SessionTotals, SessionTotals) -> SessionTotals`

- [ ] **Step 1: Append the failing tests** to `PointsTests.swift`, inside its suite:

```swift
    @Test func thirtyShortStretchesScoreLikeOneLongOne() {
        var written: [PointKind: Int] = [:]
        var today = SessionTotals()
        var total = 0
        for _ in 0..<30 {
            today = today + SessionTotals(focusedSec: 90)
            for l in dayPoints(today: today, allowanceSec: 3600, written: written) {
                written[l.kind, default: 0] += l.delta; total += l.delta
            }
        }
        #expect(total == 45)
        #expect(dayPoints(today: SessionTotals(focusedSec: 2700), allowanceSec: 3600, written: [:]) == [PointLine(kind: .focus, delta: 45)])
    }

    @Test func dayPointsPenaltiesAndNoRepeats() {
        let t = SessionTotals(focusedSec: 600, offtaskSec: 150, breakSec: 3725)
        let lines = dayPoints(today: t, allowanceSec: 3600, written: [:])
        #expect(lines == [PointLine(kind: .focus, delta: 10), PointLine(kind: .offtask, delta: -4), PointLine(kind: .breakOver, delta: -2)])
        #expect(dayPoints(today: t, allowanceSec: 3600, written: [.focus: 10, .offtask: -4, .breakOver: -2]).isEmpty)
    }
```

- [ ] **Step 2: Run them and check they fail.** Run `cd Shared && swift test --disable-sandbox --filter PointsTests`. Expected: FAIL, `cannot find 'dayPoints' in scope`.

- [ ] **Step 3: Implement.** Append to `SessionAccounting.swift`:

```swift
public extension SessionTotals {
    static func + (l: SessionTotals, r: SessionTotals) -> SessionTotals {
        SessionTotals(focusedSec: l.focusedSec + r.focusedSec, offtaskSec: l.offtaskSec + r.offtaskSec,
                      breakSec: l.breakSec + r.breakSec, idleSec: l.idleSec + r.idleSec, sleepSec: l.sleepSec + r.sleepSec)
    }
}
```

Append to `Points.swift`:

```swift
/// Ledger lines that bring today's focus, off-task and over-break points up to date (spec 2026-11-26 §4).
/// `today` sums all of today's stretches, including the one just closed. `written` is what today's ledger already
/// holds per kind. Rounding happens on the day total, so short stretches lose nothing.
public func dayPoints(today: SessionTotals, allowanceSec: Int, written: [PointKind: Int]) -> [PointLine] {
    let targets: [(PointKind, Int)] = [
        (.focus, today.focusedSec / 60 * PointRules.perFocusedMinute),
        (.offtask, today.offtaskSec / 60 * PointRules.perOfftaskMinute),
        (.breakOver, max(0, today.breakSec - allowanceSec) / 60 * PointRules.perOverBreakMinute),
    ]
    return targets.map { PointLine(kind: $0.0, delta: $0.1 - (written[$0.0] ?? 0)) }.filter { $0.delta != 0 }
}
```

- [ ] **Step 4: Run the tests.** Run `cd Shared && swift test --disable-sandbox --filter PointsTests`. Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Shared/Sources/Core/Points.swift Shared/Sources/Core/SessionAccounting.swift Shared/Tests/CoreTests/PointsTests.swift
git commit -m "feat(core): dayPoints from running daily totals

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `Tracker` (Core)

**Files:**
- Modify: `Shared/Sources/Core/SessionEngine.swift`
- Create: `Shared/Sources/Core/Tracker.swift`
- Test: `Shared/Tests/CoreTests/TrackerTests.swift`

**Interfaces:**
- Consumes: `SessionEngine`, `PeriodCalendar`, `Allowlist`, `SessionTotals`.
- Produces:
  - `SessionEngine.init(plannedMin: Int? = nil, startedAt:allowlist:)`
  - `SessionEngine.close(at:) -> (events: [SessionEvent], totals: SessionTotals)`
  - `TrackedProject(id: UUID, allowlist: Allowlist, offMac: Bool = false)`
  - `StretchEnd` (`.switched`, `.stopped`; raw values match `end_kind`)
  - `StretchResult { projectID, startedAt, endedAt, end: StretchEnd, events, totals }`
  - `Tracker` with:
    - `init(calendar:)`
    - `currentID: UUID?`, `previousID: UUID?`, `project: TrackedProject?`, `engine: SessionEngine?`, `front: FrontApp?`
    - `isTracking`, `onBreak`, `isOffTask`
    - `switchTo(_:at:)`, `stop(at:)`, `setBreak(_:at:)`, `observe(bundleID:host:at:)`, `tick(at:)`, `setIdle(_:at:)`, `setAsleep(_:at:)`, `allowCurrent(at:)`. Each returns `[Tracker.Output]` (`allowCurrent` returns `(AllowEntry, [Output])?`).
  - `Tracker.Output`: `.ended(StretchResult)`, `.started(projectID: UUID, at: Date)`, `.offTaskStarted(bundleID: String, host: String?)`, `.offTaskEnded`

- [ ] **Step 1: Write the failing test** `Shared/Tests/CoreTests/TrackerTests.swift`:

```swift
import Foundation
import Testing
@testable import Core

@Suite struct TrackerTests {
    let utc = PeriodCalendar(timeZone: TimeZone(identifier: "UTC")!)
    let t0 = ISO8601DateFormatter().date(from: "2026-11-26T10:00:00Z")!
    let a = TrackedProject(id: UUID(), allowlist: Allowlist(entries: [AllowEntry(.app, "com.microsoft.VSCode")], ownBundleID: "dev.stint.mac"))
    let b = TrackedProject(id: UUID(), allowlist: Allowlist(entries: [AllowEntry(.domain, "figma.com")], ownBundleID: "dev.stint.mac"))

    func ended(_ out: [Tracker.Output]) -> [StretchResult] {
        out.compactMap { if case let .ended(r) = $0 { r } else { nil } }
    }

    @Test func switchEndsTheOldStretchAndStartsTheNext() {
        var t = Tracker(calendar: utc)
        #expect(t.switchTo(a, at: t0) == [.started(projectID: a.id, at: t0)])
        let out = t.switchTo(b, at: t0 + 120)
        let r = ended(out)
        #expect(r.count == 1 && r[0].projectID == a.id && r[0].end == .switched && r[0].endedAt == t0 + 120)
        #expect(r[0].totals.focusedSec == 120)
        #expect(out.last == .started(projectID: b.id, at: t0 + 120))
        #expect(t.currentID == b.id && t.previousID == a.id)
    }

    @Test func switchingToTheCurrentProjectDoesNothing() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        #expect(t.switchTo(a, at: t0 + 60).isEmpty)
    }

    @Test func stopEndsWithStoppedAndRemembersThePrevious() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        let r = ended(t.stop(at: t0 + 60))
        #expect(r.first?.end == .stopped)
        #expect(!t.isTracking && t.previousID == a.id)
        #expect(t.stop(at: t0 + 70).isEmpty)
    }

    @Test func aBreakEndsWhenYouSwitch() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        _ = t.setBreak(true, at: t0 + 60)
        let r = ended(t.switchTo(b, at: t0 + 120))
        #expect(r[0].totals.breakSec == 60)
        #expect(!t.onBreak)
    }

    @Test func midnightSplitsTheStretch() {
        var t = Tracker(calendar: utc)
        let late = ISO8601DateFormatter().date(from: "2026-11-26T23:50:00Z")!
        let midnight = ISO8601DateFormatter().date(from: "2026-11-27T00:00:00Z")!
        _ = t.switchTo(a, at: late)
        let out = t.tick(at: midnight + 300)
        #expect(ended(out).first?.endedAt == midnight)
        #expect(ended(out).first?.end == .switched)
        #expect(out.contains(.started(projectID: a.id, at: midnight)))
        #expect(t.engine?.startedAt == midnight && t.previousID == nil)
    }

    @Test func offMacIgnoresIdleAndStopsAtMidnight() {
        var t = Tracker(calendar: utc)
        var books = a; books.offMac = true
        let late = ISO8601DateFormatter().date(from: "2026-11-26T23:00:00Z")!
        _ = t.switchTo(books, at: late)
        _ = t.setIdle(true, at: late + 600)
        _ = t.observe(bundleID: "com.spotify.client", host: nil, at: late + 600)
        #expect(t.engine?.idle == false && !t.isOffTask)
        let r = ended(t.tick(at: late + 7200))
        #expect(r.first?.end == .stopped && r.first?.totals.focusedSec == 3600)
        #expect(!t.isTracking)
    }

    @Test func aStretchStartedWhileIdleBeginsIdle() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        _ = t.setIdle(true, at: t0 + 10)
        _ = t.switchTo(b, at: t0 + 20)
        #expect(t.engine?.idle == true)
    }

    @Test func aBackdatedSwitchDropsLaterEvents() {
        var t = Tracker(calendar: utc)
        _ = t.switchTo(a, at: t0)
        _ = t.observe(bundleID: "com.apple.safari", host: "figma.com", at: t0 + 100)
        _ = t.tick(at: t0 + 116) // off-task from t0 + 115
        let r = ended(t.switchTo(b, at: t0 + 100))
        #expect(r[0].endedAt == t0 + 100)
        #expect(r[0].events.allSatisfy { $0.at <= t0 + 100 })
        #expect(r[0].totals.offtaskSec == 0)
        #expect(t.engine?.startedAt == t0 + 100 && !t.isOffTask)
    }
}
```

- [ ] **Step 2: Run it and check it fails.** Run `cd Shared && swift test --disable-sandbox --filter TrackerTests`. Expected: FAIL, `cannot find 'Tracker' in scope`.

- [ ] **Step 3: Make planned length optional and add `close(at:)` in `SessionEngine.swift`.**
  - Change `public let plannedMin: Int` to `public let plannedMin: Int?`.
  - Change the init signature to `public init(plannedMin: Int? = nil, startedAt: Date, allowlist: Allowlist)`.
  - In `tick`, guard the completion check:

```swift
        if let plannedMin, !completionSignalled && isComplete(totals(at: now), plannedMin: plannedMin) {
```

  - In `remainingSec`, use `max(0, (plannedMin ?? 0) * 60 - totals(at: now).activeSec)`.
  - In `finish`, use `let completed = !early && (plannedMin.map { isComplete(t, plannedMin: $0) } ?? false)`.
  - Add, after `finish`:

```swift
    /// Ends the stretch at `now`: drops events after `now` (a backdated switch), closes open states,
    /// and returns what the ledger stores.
    public mutating func close(at now: Date) -> (events: [SessionEvent], totals: SessionTotals) {
        events.removeAll { $0.at > now }
        if tracker.isOffTask { events.append(SessionEvent(.offtaskEnd, at: now)) }
        if onBreak { events.append(SessionEvent(.breakEnd, at: now)) }
        if idle { events.append(SessionEvent(.idleEnd, at: now)) }
        if asleep { events.append(SessionEvent(.wake, at: now)) }
        return (events, totals(at: now))
    }
```

- [ ] **Step 4: Write** `Shared/Sources/Core/Tracker.swift`:

```swift
import Foundation

/// A project Stint can track: its id, its live allowlist and the off-Mac flag (spec 2026-11-26 §5.6).
public struct TrackedProject: Sendable {
    public var id: UUID
    public var allowlist: Allowlist
    public var offMac: Bool
    public init(id: UUID, allowlist: Allowlist, offMac: Bool = false) {
        self.id = id; self.allowlist = allowlist; self.offMac = offMac
    }
}

/// Raw values are `session.end_kind`.
public enum StretchEnd: String, Sendable { case switched, stopped }

public struct StretchResult: Equatable, Sendable {
    public var projectID: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var end: StretchEnd
    public var events: [SessionEvent]
    public var totals: SessionTotals
}

/// What is being tracked right now: one stretch on one project at a time (spec 2026-11-26 §5.1–5.3, 5.6).
/// Pure: the caller feeds switches, observations and clock ticks, and stores what comes out.
public struct Tracker: Sendable {
    public enum Output: Equatable, Sendable {
        case ended(StretchResult)
        case started(projectID: UUID, at: Date)
        case offTaskStarted(bundleID: String, host: String?)
        case offTaskEnded
    }

    public private(set) var project: TrackedProject?
    public private(set) var previousID: UUID?
    public private(set) var engine: SessionEngine?
    public private(set) var front: FrontApp?
    let calendar: PeriodCalendar
    // Mac-wide state, carried into the next stretch.
    var idle = false, asleep = false

    public init(calendar: PeriodCalendar) { self.calendar = calendar }

    public var currentID: UUID? { project?.id }
    public var isTracking: Bool { project != nil }
    public var onBreak: Bool { engine?.onBreak ?? false }
    public var isOffTask: Bool { engine?.isOffTask ?? false }

    /// Switches to `p` at `now`, or at the current stretch's start if `now` is earlier. Starts tracking when stopped.
    public mutating func switchTo(_ p: TrackedProject, at now: Date) -> [Output] {
        guard p.id != project?.id else { return [] }
        var out: [Output] = []
        var start = now
        if let old = project, var e = engine {
            start = max(now, e.startedAt)
            if e.isOffTask { out.append(.offTaskEnded) }
            out.append(.ended(Self.close(&e, old, at: start, .switched)))
            previousID = old.id
        }
        open(p, at: start)
        out.append(.started(projectID: p.id, at: start))
        return out
    }

    public mutating func stop(at now: Date) -> [Output] {
        guard let p = project, var e = engine else { return [] }
        var out: [Output] = e.isOffTask ? [.offTaskEnded] : []
        out.append(.ended(Self.close(&e, p, at: max(now, e.startedAt), .stopped)))
        previousID = p.id
        project = nil; engine = nil; idle = false; asleep = false
        return out
    }

    public mutating func setBreak(_ on: Bool, at now: Date) -> [Output] {
        guard var e = engine else { return [] }
        let out = Self.map(e.setBreak(on, at: now))
        engine = e
        return out
    }

    public mutating func observe(bundleID: String, host: String?, at now: Date) -> [Output] {
        front = FrontApp(bundleID: bundleID, host: host)
        guard var e = engine, project?.offMac == false else { return [] }
        let out = Self.map(e.observe(bundleID: bundleID, host: host, at: now))
        engine = e
        return out
    }

    public mutating func setIdle(_ v: Bool, at now: Date) -> [Output] {
        idle = v
        guard var e = engine, project?.offMac == false else { return [] }
        let out = Self.map(e.setIdle(v, at: now))
        engine = e
        return out
    }

    public mutating func setAsleep(_ v: Bool, at now: Date) -> [Output] {
        asleep = v
        guard var e = engine, project?.offMac == false else { return [] }
        let out = Self.map(e.setAsleep(v, at: now))
        engine = e
        return out
    }

    /// "It's work: allow": allows what's in front for the rest of this stretch. The caller makes it permanent.
    public mutating func allowCurrent(at now: Date) -> (AllowEntry, [Output])? {
        guard var e = engine, let (entry, signals) = e.allowCurrent(at: now) else { return nil }
        engine = e
        return (entry, Self.map(signals))
    }

    /// Clock tick: the midnight split (§5.2), then the engine's grace timers.
    public mutating func tick(at now: Date) -> [Output] {
        var out: [Output] = []
        while let p = project, var e = engine {
            let midnight = calendar.dayInterval(containing: e.startedAt).end
            guard now >= midnight else { break }
            if p.offMac { out += stop(at: midnight); break }
            let wasOnBreak = e.onBreak
            if e.isOffTask { out.append(.offTaskEnded) }
            out.append(.ended(Self.close(&e, p, at: midnight, .switched)))
            open(p, at: midnight)
            if wasOnBreak { _ = engine?.setBreak(true, at: midnight) } // a break carries over midnight
            out.append(.started(projectID: p.id, at: midnight))
        }
        if var e = engine, project?.offMac == false {
            out += Self.map(e.tick(at: now))
            engine = e
        }
        return out
    }

    private mutating func open(_ p: TrackedProject, at start: Date) {
        project = p
        var e = SessionEngine(startedAt: start, allowlist: p.allowlist)
        if !p.offMac {
            if idle { _ = e.setIdle(true, at: start) }
            if asleep { _ = e.setAsleep(true, at: start) }
            if let f = front { _ = e.observe(bundleID: f.bundleID, host: f.host, at: start) }
        }
        engine = e
    }

    private static func close(_ e: inout SessionEngine, _ p: TrackedProject, at end: Date, _ kind: StretchEnd) -> StretchResult {
        let (events, totals) = e.close(at: end)
        return StretchResult(projectID: p.id, startedAt: e.startedAt, endedAt: end, end: kind, events: events, totals: totals)
    }

    private static func map(_ signals: [SessionEngine.Signal]) -> [Output] {
        signals.compactMap {
            switch $0 {
            case let .offTaskStarted(bundleID, host): .offTaskStarted(bundleID: bundleID, host: host)
            case .offTaskEnded: .offTaskEnded
            case .reachedPlannedLength: nil // stretches have no planned length
            }
        }
    }
}
```

- [ ] **Step 5: Run the tests.** Run `cd Shared && swift test --disable-sandbox`. Expected: all pass, including `TrackerTests` (8) and the existing `SessionEngineTests`, which still pass an `Int` planned length.

- [ ] **Step 6: Commit.**

```bash
git add Shared/Sources/Core/SessionEngine.swift Shared/Sources/Core/Tracker.swift Shared/Tests/CoreTests/TrackerTests.swift
git commit -m "feat(core): Tracker for one current project, midnight split, off-Mac

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: StintData: project fields, nullable planned length, stretch ledger

**Files:**
- Modify: `Shared/Sources/StintData/Models.swift` (`Project`)
- Modify: `Shared/Sources/StintData/Sync/Rows.swift` (`ProjectRow`, `SessionRow`)
- Modify: `Shared/Sources/StintData/Sync/Mapping.swift`
- Modify: `Shared/Sources/StintData/Sync/RunningSession.swift`
- Modify: `Shared/Sources/StintData/Ledger.swift`
- Test: `Shared/Tests/StintDataTests/MappingTests.swift`, `Shared/Tests/StintDataTests/LedgerTests.swift` (append; update the `recoverOrphans` expectation)

**Interfaces:**
- Consumes: `StretchResult`, `dayPoints`, `SessionTotals.+` (Tasks 3–4).
- Produces:
  - `Project.icon: String?`, `Project.shortName: String?`, `Project.offMac: Bool`
  - `ProjectRow.icon/shortName/offMac`
  - `SessionRow.plannedMin: Int?`
  - `Ledger.openStretch(_:projectID:startedAt:) throws -> SessionRecord`
  - `Ledger.closeStretch(_:record:result:day:allowanceSec:now:) throws -> [PointLine]` (discardable)
  - `Ledger.recoverOrphans(_:now:allowanceSec:)`, which now closes orphans as `stopped` stretches.

- [ ] **Step 1: Write the failing tests.** Append to `LedgerTests.swift`, inside its suite. Reuse the suite's in-memory container helper if it has one; otherwise create a container the same way `SyncCoordinatorTests.make()` does.

```swift
    @Test func shortStretchesScorePointsOnTheDayTotal() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = c.mainContext
        let p = Project(name: "CHL"); ctx.insert(p); try ctx.save()
        let day = PeriodCalendar(timeZone: .current).dayInterval(containing: .now)
        var t = day.start.addingTimeInterval(3600)
        var lines: [PointLine] = []
        for _ in 0..<3 {
            let r = try Ledger.openStretch(ctx, projectID: p.id, startedAt: t)
            #expect(r.plannedMin == 0)
            let res = StretchResult(projectID: p.id, startedAt: t, endedAt: t + 90, end: .switched, events: [],
                                    totals: SessionTotals(focusedSec: 90))
            lines += try Ledger.closeStretch(ctx, record: r, result: res, day: day, allowanceSec: 3600, now: t + 90)
            #expect(r.endKind == "switched")
            t += 90
        }
        #expect(lines.map(\.delta) == [1, 2, 1]) // 90 s, 180 s, 270 s → 1, 3, 4 minutes
        #expect(Ledger.balance(ctx) == 4)
    }
```

Append to `MappingTests.swift`, inside its suite:

```swift
    @Test func stretchesSendNoPlannedLengthAndProjectsCarryNewFields() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let p = Project(name: "Christian Heritage"); p.icon = "building.columns"; p.shortName = "CHL"; p.offMac = true
        c.mainContext.insert(p)
        let r = Mapping.row(p, userID: UUID())
        #expect(r.icon == "building.columns" && r.shortName == "CHL" && r.offMac)
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(json.contains("\"short_name\":\"CHL\"") && json.contains("\"off_mac\":true"))
        let s = SessionRecord(projectID: p.id, firstTaskID: nil, plannedMin: 0, startedAt: .now, allowData: Data("[]".utf8))
        #expect(Mapping.row(s, userID: UUID(), device: "mac").plannedMin == nil)
    }
```

If `Mapping.row` for sessions has a different signature, use the one in `Mapping.swift` around line 34, and keep the assertion.

- [ ] **Step 2: Run them and check they fail.** Run `cd Shared && swift test --disable-sandbox --filter "LedgerTests|MappingTests"`. Expected: FAIL, `value of type 'Project' has no member 'icon'`.

- [ ] **Step 3: Add the model fields.** In `Project` (`Models.swift`), after `archivedAt`:

```swift
    /// SF Symbol name; nil shows initials on the colour (spec 2026-11-26 §3).
    public var icon: String? = nil
    /// Menu bar name; nil uses the name, truncated.
    public var shortName: String? = nil
    /// Idle, sleep and off-task checks are off while this project is current (spec §5.6).
    public var offMac: Bool = false
```

- [ ] **Step 4: Update the rows.**
  - In `ProjectRow`:
    - Add `public var icon: String? = nil, shortName: String? = nil` and `public var offMac: Bool = false` after `archivedAt`.
    - Add the coding keys `icon, shortName = "short_name", offMac = "off_mac"` to the second `case` line.
    - In `encode`, add `try c.encode(icon, forKey: .icon); try c.encode(shortName, forKey: .shortName); try c.encode(offMac, forKey: .offMac)`.
  - In `SessionRow`, change `public var plannedMin: Int` to `public var plannedMin: Int?`. The existing `encode` line still works: it encodes nil as null.

- [ ] **Step 5: Update the mapping.**
  - `Mapping.row(_ p: Project…)`: pass `icon: p.icon, shortName: p.shortName, offMac: p.offMac` (append them after `archivedAt:`).
  - `fill(_ p:, _ r:)`: add `p.icon = r.icon; p.shortName = r.shortName; p.offMac = r.offMac`.
  - The session row (line ~34): `plannedMin: s.plannedMin > 0 ? s.plannedMin : nil`.
  - The session pull (line ~98): `s.plannedMin = r.plannedMin ?? 0`.
  - `RunningSession.init(row:events:)`: `plannedMin: row.plannedMin ?? 0`.
  - Build. Fix any other `SessionRow.plannedMin` use the compiler flags with `?? 0`.

- [ ] **Step 6: Add the stretch ledger** to `Ledger`, after `close`:

```swift
    /// Opens a stretch (spec 2026-11-26 §3): no planned length (stored as 0, sent as null), no allowlist snapshot.
    public static func openStretch(_ ctx: ModelContext, projectID: UUID, startedAt: Date) throws -> SessionRecord {
        let r = SessionRecord(projectID: projectID, firstTaskID: nil, plannedMin: 0, startedAt: startedAt, allowData: Data("[]".utf8))
        ctx.insert(r)
        try ctx.save()
        return r
    }

    /// Closes a stretch and brings `day`'s points up to date (spec §4). `now` stamps `updatedAt`: a backdated
    /// end can be earlier than the last checkpoint, and the server drops updates older than what it has.
    @discardableResult
    public static func closeStretch(_ ctx: ModelContext, record: SessionRecord, result: StretchResult,
                                    day: DateInterval, allowanceSec: Int, now: Date) throws -> [PointLine] {
        guard record.endedAt == nil else { return [] }
        let t = result.totals
        record.focusedSec = t.focusedSec; record.offtaskSec = t.offtaskSec; record.breakSec = t.breakSec
        record.idleSec = t.idleSec; record.sleepSec = t.sleepSec
        record.endedAt = result.endedAt
        record.endKind = result.end.rawValue
        record.eventsData = try enc(result.events)
        record.updatedAt = max(now, record.updatedAt)
        record.syncedAt = nil
        try ctx.save()

        let start = day.start, end = day.end
        let closed = try ctx.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.endedAt != nil && $0.startedAt >= start && $0.startedAt < end }))
        let today = closed.reduce(SessionTotals()) {
            $0 + SessionTotals(focusedSec: $1.focusedSec, offtaskSec: $1.offtaskSec, breakSec: $1.breakSec)
        }
        var written: [PointKind: Int] = [:]
        for e in try ctx.fetch(FetchDescriptor<PointEvent>(predicate: #Predicate { $0.at >= start && $0.at < end })) {
            if let k = PointKind(rawValue: e.kind), [.focus, .offtask, .breakOver].contains(k) { written[k, default: 0] += e.delta }
        }
        let lines = dayPoints(today: today, allowanceSec: allowanceSec, written: written)
        let at = min(result.endedAt, end.addingTimeInterval(-1)) // a midnight split ends at the next day's first second
        let note = projectName(ctx, record.projectID)
        for l in lines { ctx.insert(PointEvent(at: at, delta: l.delta, kind: l.kind.rawValue, refID: record.id, note: note)) }
        try ctx.save()
        return lines
    }
```

- [ ] **Step 7: Make `recoverOrphans` stretch-aware.** Replace its body:

```swift
    /// Closes stretches left open by a quit or crash at their last checkpoint; returns their ids so the caller
    /// can end the phone's Live Activity.
    @discardableResult
    public static func recoverOrphans(_ ctx: ModelContext, now: Date, allowanceSec: Int = 3600) throws -> [UUID] {
        let open = (try? ctx.fetch(FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.endedAt == nil }))) ?? []
        let cal = PeriodCalendar(timeZone: .current)
        var closed: [UUID] = []
        for r in open {
            let end = r.updatedAt
            let events = (dec(r.eventsData) as [SessionEvent]).filter { $0.at <= end }
            let result = StretchResult(projectID: r.projectID, startedAt: r.startedAt, endedAt: end, end: .stopped,
                                       events: events, totals: sessionTotals(start: r.startedAt, end: end, events: events))
            do {
                try closeStretch(ctx, record: r, result: result, day: cal.dayInterval(containing: r.startedAt),
                                 allowanceSec: allowanceSec, now: now)
                closed.append(r.id)
            } catch { log.error("recoverOrphans failed for \(r.id): \(error)") }
        }
        return closed
    }
```

Then update the existing `recoverOrphans` test in `LedgerTests.swift`:
  - it now expects `endKind == "stopped"` and `earlyReason == nil`;
  - it expects points from `dayPoints`, not `sessionPoints`;
  - keep the rest of what it checks.

- [ ] **Step 8: Run the tests.** Run `cd Shared && swift test --disable-sandbox`. Expected: all pass.

- [ ] **Step 9: Commit.**

```bash
git add Shared/Sources/StintData Shared/Tests/StintDataTests
git commit -m "feat(data): project icon/short name/off-Mac, stretch ledger with day points

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Live state v2 (Core, push function, phone, widget)

**Files:**
- Modify: `Shared/Sources/Core/LiveSession.swift`
- Test: `Shared/Tests/CoreTests/LiveSessionTests.swift` (rewrite)
- Modify: `supabase/functions/push-activity/push.ts`, `supabase/functions/push-activity/push_test.ts`
- Modify: `SharedUI/StintActivity.swift`, `iOS/LiveActivities.swift`, `iOS/PhoneSync.swift` (the two `reconcile` calls), `Widgets/LiveSessionWidget.swift`
- Modify: `Shared/Sources/StintData/Sync/RunningSession.swift` (add `paused`)
- Modify: `Mac/App/AppState.swift` (`liveState`, the start push, the end push, the update condition in `run`)
- Test: `iOSTests/LiveActivityTests.swift`, `MacTests/LivePushTests.swift`

**Interfaces:**
- Produces:
  - `LiveSessionState { status: Status (.focused, .offTask, .onBreak, .paused, .ended); projectName: String; colorHex: String; icon: String?; countFrom: Double?; focusedSec: Int }`
  - `LiveSessionState.make(projectName:colorHex:icon:focusedSec:onBreak:offTask:paused:now:)`
  - `LiveSessionState.ended(projectName:colorHex:icon:focusedSec:)`
  - `countFromDate: Date?`, `differs(from:)`
  - `LiveSessionInfo(sessionID: String)`
  - `RunningSession.paused: Bool`
  - `LiveActivities.plan(existing: [(id: String, young: Bool)], running: Bool, force: Bool = false)`
  - `LiveActivities.reconcile(running:project:now:force:)`

- [ ] **Step 1: Rewrite the failing Core test** `LiveSessionTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it and check it fails.** Run `cd Shared && swift test --disable-sandbox --filter LiveSessionTests`. Expected: FAIL, `extra argument 'projectName'` or similar.

- [ ] **Step 3: Replace `LiveSessionState` and `LiveSessionInfo`** in `LiveSession.swift`. Keep `LivePush` as it is.

```swift
/// What the Live Activity shows (spec 2026-11-26 §7.3). Same JSON on the Mac (push body), in APNs (`content-state`)
/// and in ActivityKit (`ContentState`). `countFrom` is Unix seconds, not a Date, so no date format can disagree.
public struct LiveSessionState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case focused, offTask = "off_task", onBreak = "on_break", paused, ended }
    public var status: Status
    public var projectName: String
    public var colorHex: String
    public var icon: String?
    /// The clock counts up from here (now − focused time this stretch). nil while it isn't counting.
    public var countFrom: Double?
    /// Focused seconds this stretch; shown as a still number when `countFrom` is nil.
    public var focusedSec: Int

    public init(status: Status, projectName: String, colorHex: String, icon: String?, countFrom: Double?, focusedSec: Int) {
        self.status = status; self.projectName = projectName; self.colorHex = colorHex; self.icon = icon
        self.countFrom = countFrom; self.focusedSec = focusedSec
    }

    /// `paused` = idle or asleep.
    public static func make(projectName: String, colorHex: String, icon: String?, focusedSec: Int,
                            onBreak: Bool, offTask: Bool, paused: Bool, now: Date) -> LiveSessionState {
        let status: Status = onBreak ? .onBreak : paused ? .paused : offTask ? .offTask : .focused
        return LiveSessionState(status: status, projectName: projectName, colorHex: colorHex, icon: icon,
                                countFrom: status == .focused ? (now.timeIntervalSince1970 - Double(focusedSec)).rounded() : nil,
                                focusedSec: focusedSec)
    }

    public static func ended(projectName: String, colorHex: String, icon: String?, focusedSec: Int) -> LiveSessionState {
        LiveSessionState(status: .ended, projectName: projectName, colorHex: colorHex, icon: icon, countFrom: nil, focusedSec: focusedSec)
    }

    public var countFromDate: Date? { countFrom.map { Date(timeIntervalSince1970: $0) } }

    /// Worth a push: anything visible changed, or the clock's start moved by more than 30 s.
    public func differs(from o: LiveSessionState) -> Bool {
        if status != o.status || projectName != o.projectName || colorHex != o.colorHex || icon != o.icon { return true }
        switch (countFrom, o.countFrom) {
        case let (a?, b?): return abs(a - b) > 30
        case (nil, nil): return false
        default: return true
        }
    }
}

/// Live Activity attributes on the wire. Property names must match `StintActivityAttributes` on iOS.
/// One activity per tracking run; the project lives in the content state because it changes on every switch.
public struct LiveSessionInfo: Codable, Hashable, Sendable {
    public var sessionID: String
    public init(sessionID: String) { self.sessionID = sessionID }
}
```

- [ ] **Step 4: Update `push-activity`.**
  - In `push.ts`:
    - Replace the `tokens` expression with:

```ts
  // One tracking run at a time: updates and ends go to whatever activity each phone has (spec 2026-11-26 §7.3).
  const tokens = [...new Set(devices.map((d) => event === "start" ? d.push_to_start_token : d.activity_token)
    .filter((t): t is string => typeof t === "string" && HEX.test(t)))];
```

    - Delete the `sid` line above it.
    - Replace the alert line with:

```ts
    const cs = content_state as Record<string, unknown>;
    aps.alert = { title: typeof cs.projectName === "string" ? cs.projectName : "Stint", body: "Tracking on your Mac" };
```

    - Delete `const a = …` if nothing else uses it; keep `aps.attributes = attributes`.
  - In `push_test.ts`:
    - Set `state` to `{ status: "focused", projectName: "Northwind", colorHex: "#000000", countFrom: 1800000000, focusedSec: 600 }` and `attrs` to `{ sessionID: S }`.
    - Change the start alert assertion to `{ title: "Northwind", body: "Tracking on your Mac" }`.
    - Rename the update test to `"update goes to every device's activity token"` and expect `sent.map((s) => s.token)` to equal `["bb22", "cc33"]` and `{ sent: 2, failed: 0 }`.
  - Run `cd supabase/functions/push-activity && deno test`. Expected: all pass.

- [ ] **Step 5: Update the phone.**
  - `SharedUI/StintActivity.swift`: `StintActivityAttributes` keeps only `var sessionID: String`.
  - `RunningSession.swift`: add `public var paused: Bool { isOpen(.idleStart, .idleEnd) || isOpen(.sleep, .wake) }`.
  - `LiveActivities.swift`:
    - Replace `plan` with:

```swift
    /// Pure: one activity per tracking run. Keep the first; end every other one except young ones (unless `force`);
    /// start one if tracking and none is kept. A young activity may have been push-started before its row arrived.
    nonisolated static func plan(existing: [(id: String, young: Bool)], running: Bool,
                                 force: Bool = false) -> (start: Bool, end: Set<String>, keep: String?) {
        let keep = running ? existing.first?.id : nil
        let end = Set(existing.filter { $0.id != keep && (force || !$0.young) }.map(\.id))
        return (running && keep == nil, end, keep)
    }
```

    - Change `reconcile` to `func reconcile(running: RunningSession?, project: Project?, now: Date, force: Bool = false) async`.
    - Call `plan(existing: all.map { (id: $0.id, young: …) }, running: running != nil, force: force)`.
    - End activities with `ActivityContent(state: .ended(projectName: a.content.state.projectName, colorHex: a.content.state.colorHex, icon: a.content.state.icon, focusedSec: a.content.state.focusedSec), staleDate: nil)`.
    - Build the state as:

```swift
        let state = LiveSessionState.make(projectName: project?.name ?? "Stint", colorHex: project?.colorHex ?? "#8E8E93",
                                          icon: project?.icon, focusedSec: running.totals(at: now).focusedSec,
                                          onBreak: running.onBreak, offTask: running.offTask, paused: running.paused, now: now)
```

    - Request with `StintActivityAttributes(sessionID: running.id.uuidString)`.
  - `PhoneSync.swift`, line ~140: `await live.reconcile(running: nil, project: nil, now: .now, force: true)`. Line ~200: `await live.reconcile(running: run, project: project, now: .now)`. Remove the now-unused `task` lookup next to it.
  - `LiveSessionWidget.swift`:
    - Use `ctx.state.projectName` wherever it used `ctx.attributes.projectName`. `LockScreen` no longer needs `attrs`.
    - In `LockScreen`, show `Image(systemName: state.icon ?? "circle.fill").foregroundStyle(Color(hex: state.colorHex))` before the name, and drop the task line.
    - Replace `Clock`'s body with:

```swift
        Group {
            if let from = state.countFromDate {
                Text(from, style: .timer)
            } else if state.status == .ended {
                Image(systemName: "checkmark.circle.fill")
            } else {
                Text(remainingText(state.focusedSec))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
```

    - In `label`, `.paused` → `"Paused"` and `.ended` → `"Stopped"`. In `symbol`, `.paused` → `"pause.circle"`.
  - `iOSTests/LiveActivityTests.swift`:
    - The attributes test encodes `StintActivityAttributes(sessionID: "S")` against `LiveSessionInfo(sessionID: "S")`.
    - Rewrite the two plan tests for the new signature:
      - `plan(existing: [], running: true)` → start;
      - `[("1", false), ("2", false)]`, running → keep "1", end ["2"];
      - not running → end all non-young;
      - a young one is left alone unless `force`.

- [ ] **Step 6: Point the Mac at the new shape** (the Pomodoro `AppState` stays until Task 7).
  - In `AppState.swift`, replace `liveState`:

```swift
    private func liveState(at now: Date) -> LiveSessionState? {
        guard let e = engine, let p = project else { return nil }
        return .make(projectName: p.name, colorHex: p.colorHex, icon: p.icon, focusedSec: e.totals(at: now).focusedSec,
                     onBreak: e.onBreak, offTask: e.isOffTask, paused: e.idle || e.asleep, now: now)
    }
```

  - The start push uses `attributes: LiveSessionInfo(sessionID: r.id.uuidString)`.
  - The end push in `finish` uses `contentState: .ended(projectName: project?.name ?? "", colorHex: project?.colorHex ?? "#8E8E93", icon: project?.icon, focusedSec: result.totals.focusedSec)`. Compute it before `project` is cleared.
  - In `run`, the update condition becomes `if let s = liveState(at: .now), let r = record, let last = lastLive, s.differs(from: last)`.
  - In `SyncCoordinator.swift` line ~96, the recovered-session end push uses `.ended(projectName: "", colorHex: "#8E8E93", icon: nil, focusedSec: 0)`.
  - `MacTests/LivePushTests.swift`: expect `first.attributes == LiveSessionInfo(sessionID: first.sessionID.uuidString)`. The break update has `status == .onBreak && countFrom == nil`, the resume update has `countFrom != nil`, and the end has `.ended`.

- [ ] **Step 7: Run everything.**
  - `cd Shared && swift test --disable-sandbox`
  - the Mac tests
  - the iOS tests
  - the Deno tests
  - Expected: all pass. If you changed files, run `xcodegen generate` first.

- [ ] **Step 8: Commit.**

```bash
git add -A Shared SharedUI iOS iOSTests Widgets Mac MacTests supabase/functions/push-activity
git commit -m "feat(live): run-long Live Activity showing the current project

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Deploy the function.** Run `supabase functions deploy push-activity --remote --yes`. If the CLI rejects `--remote` for deploy, use `supabase functions deploy push-activity --project-ref vaidmipsctbcgxeescqj --yes`. Expected: "Deployed Function push-activity".

---

### Task 7: The Mac on `Tracker`: switching, menu bar panel, commands

This is the switch-over: `AppState`, `SyncCoordinator`, `SessionCommand`, the menu bar, the nudge and the Mac Today screen change together, plus the phone's call sites, so the whole thing compiles.

**Files:**
- Modify: `Shared/Sources/StintData/Sync/SessionCommand.swift`
- Test: `Shared/Tests/StintDataTests/SessionCommandTests.swift` (rewrite the parse/wire cases)
- Rewrite: `Mac/App/AppState.swift`
- Modify: `Mac/App/SyncCoordinator.swift` (`perform`, `rejectionReason`, the retry in `handlePending`)
- Rewrite: `Mac/UI/MenuBarView.swift`
- Modify: `Mac/UI/NudgePanel.swift` (`NudgeView` copy)
- Modify: `Mac/UI/TodayView.swift` (remove `startBar`; `app.engine` → `app.tracker.engine`)
- Delete: `Mac/UI/StartSessionControls.swift`
- Create: `SharedUI/ProjectIcon.swift`
- Modify: `SharedUI/Theme.swift` (add `hoursMinutes`)
- Modify (phone call sites only): `iOS/UI/TodayView.swift`, `iOS/PhoneSync.swift` (`openStart`, `flushPendingStart`), `Widgets/StintWidgets.swift` (the Start label)
- Test: `MacTests/LivePushTests.swift`, `MacTests/SyncCoordinatorTests.swift`, `MacTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `Tracker`, `TrackedProject`, `Ledger.openStretch/closeStretch/recoverOrphans(…allowanceSec:)`, `LiveSessionState.make/ended`, `Project.icon/shortName/offMac`.
- Produces:
  - `SessionCommand`: `.switchTo(projectID:)`, `.stop`, `.breakStart`, `.breakEnd`, `.legacy`
  - `AppState` with:
    - `tracker: Tracker`, `record: SessionRecord?`, `project: Project?`, `isTracking: Bool`, `previousProject: Project?`, `activeProjects: [Project]`
    - `switchTo(_ p: Project, at: Date = .now)`, `switchTo(projectID:) -> Bool`, `switchToPrevious()`, `stop()`, `takeBreak()`, `resume()`
    - `allowCurrent(reason:)` (permanent: adds an `AllowRule` to the current project)
    - `focusedToday(_ projectID: UUID) -> Int`, `todayStats() -> TodayStats`
    - `findProject(_ id: UUID) -> Project?`
    - `static tracked(_ p: Project) -> TrackedProject`
  - `Project.menuTitle: String` (Mac extension)
  - `hoursMinutes(_ sec: Int) -> String` (`"1:42"`)
  - `initials(_ name: String) -> String`
  - `ProjectIcon(name:colorHex:icon:size:)`

- [ ] **Step 1: Rewrite the failing tests.**

`SessionCommandTests.swift`: replace the parse/wire cases with these. Keep any `awaitCommandOutcome`/`ownerCheck` tests that are already there.

```swift
    @Test func parsesSwitchFirstKinds() {
        let id = UUID()
        func row(_ kind: String, _ payload: [String: String] = [:]) -> SessionCommandRow {
            SessionCommandRow(id: UUID(), userID: UUID(), createdAt: .now, kind: kind, payload: payload, rejectedReason: nil)
        }
        #expect(SessionCommand.parse(row("switch", ["project_id": id.uuidString])) == .switchTo(projectID: id))
        #expect(SessionCommand.parse(row("switch", ["project_id": "nope"])) == nil)
        #expect(SessionCommand.parse(row("stop")) == .stop)
        #expect(SessionCommand.parse(row("break_start")) == .breakStart)
        #expect(SessionCommand.parse(row("break_end")) == .breakEnd)
        for old in ["start", "break", "resume", "end_early_request"] { #expect(SessionCommand.parse(row(old)) == .legacy) }
        #expect(SessionCommand.parse(row("dance")) == nil)
        let w = SessionCommand.switchTo(projectID: id).wire
        #expect(w.kind == "switch" && w.payload == ["project_id": id.uuidString])
    }
```

If `SessionCommandRow`'s memberwise init differs, copy how the file's existing tests build rows.

`SyncCoordinatorTests.swift`: replace `startRunsThenIgnoredWhileRunning`, `endEarlyRecordsEarly`, `unknownProjectAndNoSession` and `rejectionReasons` with:

```swift
    @Test func switchStopAndBreakCommands() throws {
        let (app, p, keep) = try make(); defer { withExtendedLifetime(keep) {} }
        #expect(!SyncCoordinator.perform(.stop, on: app))
        #expect(!SyncCoordinator.perform(.breakStart, on: app))
        #expect(SyncCoordinator.perform(.switchTo(projectID: p.id), on: app))
        #expect(app.isTracking && app.tracker.currentID == p.id)
        #expect(SyncCoordinator.perform(.switchTo(projectID: p.id), on: app)) // already current: accepted, no-op
        #expect(SyncCoordinator.perform(.breakStart, on: app) && app.tracker.onBreak)
        #expect(SyncCoordinator.perform(.breakEnd, on: app) && !app.tracker.onBreak)
        let record = try #require(app.record)
        #expect(SyncCoordinator.perform(.stop, on: app))
        #expect(!app.isTracking && record.endKind == "stopped")
        #expect(!SyncCoordinator.perform(.switchTo(projectID: UUID()), on: app))
        #expect(!SyncCoordinator.perform(.legacy, on: app))
        p.archivedAt = .now
        #expect(!SyncCoordinator.perform(.switchTo(projectID: p.id), on: app))
    }

    @Test func rejectionReasons() {
        #expect(SyncCoordinator.rejectionReason(.legacy, isTracking: false) == "Update Stint on your phone.")
        #expect(SyncCoordinator.rejectionReason(.switchTo(projectID: UUID()), isTracking: false) == "Your Mac doesn't have that project, or it's archived. If you just created it, try again in a minute.")
        #expect(SyncCoordinator.rejectionReason(.stop, isTracking: false) == "Your Mac isn't tracking anything.")
        #expect(SyncCoordinator.rejectionReason(nil, isTracking: false) == "Your Mac couldn't read that request. Update Stint on both devices.")
    }
```

`LivePushTests.swift`: replace the test with:

```swift
    @Test func oneRunStartsUpdatesOnSwitchAndBreakThenEnds() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "Northwind"), b = Project(name: "CHL")
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        var got: [LivePush] = []
        app.onLive = { got.append($0) }

        app.switchTo(a)
        #expect(got.last?.event == .start && got.last?.contentState.projectName == "Northwind")
        app.takeBreak()
        #expect(got.last?.event == .update && got.last?.contentState.status == .onBreak)
        app.resume()
        #expect(got.last?.event == .update && got.last?.contentState.countFrom != nil)
        app.switchTo(b)
        #expect(got.last?.event == .update && got.last?.contentState.projectName == "CHL")
        app.stop()
        #expect(got.last?.event == .end && got.last?.contentState.status == .ended)
        #expect(got.filter { $0.event == .start }.count == 1)
        _ = c
    }
```

Append to `AppStateTests.swift`:

```swift
    @Test func hoursMinutesAndMenuTitle() {
        #expect(hoursMinutes(0) == "0:00")
        #expect(hoursMinutes(6120) == "1:42")
        let p = Project(name: "Christian Heritage Ltd")
        #expect(p.menuTitle == "Christian H…")
        p.shortName = "CHL"
        #expect(p.menuTitle == "CHL")
        #expect(initials("Christian Heritage") == "CH")
        #expect(initials("stint") == "S")
    }

    @MainActor @Test func switchingWritesOneRowPerStretch() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "A"), b = Project(name: "B")
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        app.switchTo(a); app.switchTo(b); app.switchToPrevious()
        #expect(app.tracker.currentID == a.id)
        let rows = try c.mainContext.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt)]))
        #expect(rows.map(\.projectID) == [a.id, b.id, a.id])
        #expect(rows.prefix(2).allSatisfy { $0.endKind == "switched" } && rows[2].endedAt == nil)
        app.stop()
    }
```

If `AppStateTests` is not `@MainActor`, keep the attribute on the new test as written. Add `import SwiftData`, `import StintData` and `import Core` if the file lacks them.

- [ ] **Step 2: Run them and check they fail.** Run the Mac tests. Expected: compile errors (`switchTo`, `.switchTo`, `hoursMinutes` not found).

- [ ] **Step 3: Rewrite `SessionCommand`** (top of `SessionCommand.swift`, both the enum and the `wire` extension):

```swift
public enum SessionCommand: Equatable, Sendable {
    case switchTo(projectID: UUID)
    case stop
    case breakStart, breakEnd
    /// A kind from a phone that predates switch-first tracking; the Mac rejects it.
    case legacy

    public static func parse(_ row: SessionCommandRow) -> SessionCommand? {
        switch row.kind {
        case "switch": return row.payload["project_id"].flatMap(UUID.init(uuidString:)).map { .switchTo(projectID: $0) }
        case "stop": return .stop
        case "break_start": return .breakStart
        case "break_end": return .breakEnd
        case "start", "break", "resume", "end_early_request": return .legacy
        default: return nil
        }
    }
}

public extension SessionCommand {
    /// Wire form for a `session_command` row; `parse` is its inverse. `.legacy` is never sent.
    var wire: (kind: String, payload: [String: String]) {
        switch self {
        case let .switchTo(id): return ("switch", ["project_id": id.uuidString])
        case .stop: return ("stop", [:])
        case .breakStart: return ("break_start", [:])
        case .breakEnd: return ("break_end", [:])
        case .legacy: return ("start", [:])
        }
    }
}
```

- [ ] **Step 4: Add the shared helpers.**
  - Append to `SharedUI/Theme.swift`:

```swift
/// "1:42": hours and minutes, for time-on-project labels.
func hoursMinutes(_ sec: Int) -> String { String(format: "%d:%02d", max(0, sec) / 3600, max(0, sec) / 60 % 60) }
```

  - Create `SharedUI/ProjectIcon.swift`:

```swift
import SwiftUI

/// "Christian Heritage" → "CH". Used when a project has no icon.
func initials(_ name: String) -> String {
    String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
}

/// A project's SF Symbol (or initials) on its colour (spec 2026-11-26 §6.4).
struct ProjectIcon: View {
    let name: String
    let colorHex: String
    let icon: String?
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(Color(hex: colorHex))
            .frame(width: size, height: size)
            .overlay {
                if let icon {
                    Image(systemName: icon).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text(initials(name)).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}
```

- [ ] **Step 5: Rewrite `Mac/App/AppState.swift`:**

```swift
import StintData
import AppKit
import SwiftData
import Core
import os

struct Nudge: Equatable { var bundleID: String; var host: String?; var startedAt: Date }

struct TodayStats: Equatable { var focusedSec: Int; var breakLeftSec: Int; var points: Int }

extension Project {
    /// Menu bar name: the short name, else the name cut to 12 characters.
    var menuTitle: String {
        if let s = shortName?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
        return name.count > 12 ? String(name.prefix(11)) + "…" : name
    }
}

/// The Mac's tracking state (spec 2026-11-26 §5): one current project, switched from the menu bar, hotkey,
/// suggestions or the phone.
@MainActor @Observable
final class AppState {
    private static let log = Logger(subsystem: "dev.stint.mac", category: "app")
    static let ownBundleID = Bundle.main.bundleIdentifier ?? "dev.stint.mac"

    var now = Date()
    private(set) var tracker = Tracker(calendar: PeriodCalendar(timeZone: .current))
    private(set) var record: SessionRecord?
    private(set) var project: Project?
    var nudge: Nudge? {
        didSet { if nudge == nil { nudgePanel.hide() } else if oldValue == nil { nudgePanel.show(self) } }
    }
    var automationDenied = false

    @ObservationIgnored private let nudgePanel = NudgePanelController()
    @ObservationIgnored let ctx: ModelContext
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var monitor: ActivityMonitor?
    @ObservationIgnored private var ticks = 0
    /// Sync hooks: fired after every checkpoint and after a stretch closes.
    @ObservationIgnored var onCheckpoint: (() -> Void)?
    @ObservationIgnored var onSessionClosed: (() -> Void)?
    /// Live Activity hook: .start when tracking begins, .update when what the phone shows changes, .end on stop.
    @ObservationIgnored var onLive: ((LivePush) -> Void)?
    /// Stretches closed at launch after a quit or crash; their Live Activity still needs an .end once signed in.
    @ObservationIgnored var recoveredSessionIDs: [UUID] = []
    @ObservationIgnored private var lastLive: LiveSessionState?
    @ObservationIgnored private var lastClosedID: UUID?

    init(context: ModelContext) {
        ctx = context
        do { recoveredSessionIDs = try Ledger.recoverOrphans(ctx, now: .now, allowanceSec: allowanceSec) }
        catch { Self.log.error("recoverOrphans: \(error)") }
    }

    var isTracking: Bool { tracker.isTracking }
    var previousProject: Project? { tracker.previousID.flatMap(findProject) }
    var activeProjects: [Project] {
        (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.archivedAt == nil }, sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    private var allowanceSec: Int { (UserDefaults.standard.object(forKey: "breakAllowanceMin") as? Int ?? 60) * 60 }
    private var calendar: PeriodCalendar { PeriodCalendar(timeZone: .current) }

    func findProject(_ id: UUID) -> Project? {
        try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first
    }

    static func tracked(_ p: Project) -> TrackedProject {
        TrackedProject(id: p.id, allowlist: Allowlist(entries: p.allowEntries, ownBundleID: ownBundleID), offMac: p.offMac)
    }

    // MARK: numbers

    /// Focused seconds today on one project, including the open stretch.
    func focusedToday(_ projectID: UUID) -> Int {
        let day = calendar.dayInterval(containing: now)
        let closed = Ledger.summaries(ctx, since: day.start)
            .filter { $0.projectID == projectID && $0.startedAt < day.end }.reduce(0) { $0 + $1.focusedSec }
        let open = tracker.currentID == projectID ? (tracker.engine?.totals(at: now).focusedSec ?? 0) : 0
        return closed + open
    }

    func todayStats() -> TodayStats {
        let day = calendar.dayInterval(containing: now)
        let sessions = Ledger.summaries(ctx, since: day.start).filter { $0.startedAt < day.end }
        var focused = sessions.reduce(0) { $0 + $1.focusedSec }
        var breakUsed = Core.breakSec(sessions, in: day)
        let start = day.start
        var points = ((try? ctx.fetch(FetchDescriptor<PointEvent>(predicate: #Predicate { $0.at >= start }))) ?? [])
            .reduce(0) { $0 + $1.delta }
        if let e = tracker.engine {
            let t = e.totals(at: now)
            focused += t.focusedSec; breakUsed += t.breakSec
            // ponytail: live estimate for the open stretch; exact (day-total rounding) once it closes.
            points += t.focusedSec / 60 * PointRules.perFocusedMinute + t.offtaskSec / 60 * PointRules.perOfftaskMinute
        }
        return TodayStats(focusedSec: focused, breakLeftSec: max(0, allowanceSec - breakUsed), points: points)
    }

    // MARK: actions

    /// Switches to `p`, optionally backdated (an accepted suggestion). Starts tracking when stopped.
    func switchTo(_ p: Project, at when: Date = .now) {
        guard p.archivedAt == nil else { return }
        let wasTracking = isTracking
        apply(tracker.switchTo(Self.tracked(p), at: when))
        if !wasTracking && isTracking { startMonitoring() }
    }

    /// Phone command. False if the project isn't local or is archived. The current project is a no-op that succeeds.
    @discardableResult
    func switchTo(projectID: UUID) -> Bool {
        guard let p = findProject(projectID), p.archivedAt == nil else { return false }
        switchTo(p)
        return true
    }

    func switchToPrevious() { if let p = previousProject { switchTo(p) } }

    func stop() {
        guard isTracking else { return }
        apply(tracker.stop(at: .now))
        stopMonitoring()
    }

    func takeBreak() { run { $0.setBreak(true, at: .now) }; checkBreakAllowance() }
    func resume() { run { $0.setBreak(false, at: .now) } }

    /// "It's work: allow": on-task now, and added to the project's allowlist for good (spec §5.4).
    func allowCurrent(reason: String) {
        guard let p = project, let (entry, out) = tracker.allowCurrent(at: .now) else { return }
        if !p.allowEntries.contains(entry) {
            let r = AllowRule(entry, label: reason)
            ctx.insert(r); r.project = p; p.updatedAt = .now
            try? ctx.save()
        }
        apply(out)
    }

    func backToTask() {
        guard let id = tracker.engine?.lastOnTaskBundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    }

    // MARK: plumbing

    private func run(checkpoint: Bool = true, _ f: (inout Tracker) -> [Tracker.Output]) {
        apply(f(&tracker), checkpoint: checkpoint)
    }

    private func apply(_ outputs: [Tracker.Output], checkpoint save: Bool = true) {
        for o in outputs {
            switch o {
            case let .ended(r):
                guard let rec = record else { continue }
                do {
                    try Ledger.closeStretch(ctx, record: rec, result: r, day: calendar.dayInterval(containing: r.startedAt),
                                            allowanceSec: allowanceSec, now: .now)
                } catch { Self.log.error("closeStretch: \(error)") }
                lastClosedID = rec.id
                record = nil; project = nil; nudge = nil
                onSessionClosed?()
            case let .started(id, at):
                do { record = try Ledger.openStretch(ctx, projectID: id, startedAt: at) }
                catch { Self.log.error("openStretch: \(error)") }
                project = findProject(id)
            case let .offTaskStarted(bundleID, host):
                nudge = Nudge(bundleID: bundleID, host: host, startedAt: Date())
            case .offTaskEnded:
                nudge = nil
            }
        }
        if let n = nudge, let f = tracker.front, tracker.isOffTask, f.bundleID != n.bundleID || f.host != n.host {
            nudge = Nudge(bundleID: f.bundleID, host: f.host, startedAt: n.startedAt)
        }
        if save || !outputs.isEmpty { checkpoint() }
        pushLive()
    }

    private func liveState(at now: Date) -> LiveSessionState? {
        guard let e = tracker.engine, let p = project else { return nil }
        return .make(projectName: p.name, colorHex: p.colorHex, icon: p.icon, focusedSec: e.totals(at: now).focusedSec,
                     onBreak: e.onBreak, offTask: e.isOffTask, paused: e.idle || e.asleep, now: now)
    }

    private func pushLive() {
        guard isTracking else {
            if let last = lastLive, let id = lastClosedID {
                onLive?(LivePush(event: .end, sessionID: id, attributes: nil,
                                 contentState: .ended(projectName: last.projectName, colorHex: last.colorHex,
                                                      icon: last.icon, focusedSec: last.focusedSec)))
            }
            lastLive = nil
            return
        }
        guard let r = record, let s = liveState(at: .now) else { return }
        if let last = lastLive {
            guard s.differs(from: last) else { return }
            onLive?(LivePush(event: .update, sessionID: r.id, attributes: nil, contentState: s))
        } else {
            onLive?(LivePush(event: .start, sessionID: r.id, attributes: LiveSessionInfo(sessionID: r.id.uuidString), contentState: s))
        }
        lastLive = s
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let m = ActivityMonitor(
            onFront: { [weak self] id, host in self?.observe(bundleID: id, host: host) },
            onIdle: { [weak self] v, at in self?.run { $0.setIdle(v, at: at) } },
            onSleep: { [weak self] v in self?.run { $0.setAsleep(v, at: .now) } },
            onAutomationDenied: { [weak self] denied in self?.automationDenied = denied })
        monitor = m
        m.start()
        m.reportCurrent()
        Notifier.requestAuthorization()
    }

    private func stopMonitoring() {
        timer?.invalidate(); timer = nil
        monitor?.stop(); monitor = nil
        nudge = nil
    }

    func observe(bundleID: String, host: String?) {
        run { $0.observe(bundleID: bundleID, host: host, at: .now) }
    }

    private func tick() {
        now = Date()
        run(checkpoint: false) { $0.tick(at: .now) }
        ticks += 1
        if ticks % 15 == 0 { checkpoint() }
        checkBreakAllowance()
    }

    private func checkpoint() {
        guard let e = tracker.engine, let r = record else { return }
        do { try Ledger.checkpoint(ctx, record: r, events: e.events, allowAdded: [], at: Date()) }
        catch { Self.log.error("checkpoint: \(error)") }
        onCheckpoint?()
    }

    private func checkBreakAllowance() {
        guard let e = tracker.engine, e.onBreak else { return }
        let today = calendar.dayInterval(containing: e.startedAt)
        let used = Ledger.breakUsedSec(ctx, in: today) + e.totals(at: now).breakSec
        let key = String(Int(today.start.timeIntervalSince1970))
        guard used >= allowanceSec, UserDefaults.standard.string(forKey: "breakWarnedDay") != key else { return }
        UserDefaults.standard.set(key, forKey: "breakWarnedDay")
        Notifier.post(title: "Break allowance used up", body: "Each extra minute costs 1 point")
    }
}
```

`tracker` is `private(set)`, so the mutating `tracker.allowCurrent(at:)` compiles inside `AppState`. If the compiler rejects the tuple binding in a `guard let`, split it into `guard let result = …; let (entry, out) = result`. Delete the old `start`, `endEarly`, `finish`, `remainingText` and `lastResult` members: none survive. Grep the Mac target for `remainingText` and `lastResult` and remove the callers. The main ones are rewritten in Steps 7–8.

- [ ] **Step 6: Update `SyncCoordinator`.**
  - In `handlePending`, change the retry to `if !done, let cmd, case .switchTo = cmd {`, and the reject call to `Self.rejectionReason(cmd, isTracking: app.isTracking)`.
  - Replace `rejectionReason` and `perform`:

```swift
    /// What the phone shows when the Mac can't act on a command.
    static func rejectionReason(_ cmd: SessionCommand?, isTracking: Bool) -> String {
        switch cmd {
        case nil: "Your Mac couldn't read that request. Update Stint on both devices."
        case .legacy: "Update Stint on your phone."
        case .switchTo: "Your Mac doesn't have that project, or it's archived. If you just created it, try again in a minute."
        case .stop, .breakStart, .breakEnd: "Your Mac isn't tracking anything."
        }
    }

    /// True when the command was acted on.
    static func perform(_ cmd: SessionCommand, on app: AppState) -> Bool {
        switch cmd {
        case let .switchTo(id): return app.switchTo(projectID: id)
        case .stop: guard app.isTracking else { return false }; app.stop(); return true
        case .breakStart: guard app.isTracking else { return false }; app.takeBreak(); return true
        case .breakEnd: guard app.isTracking else { return false }; app.resume(); return true
        case .legacy: return false
        }
    }
```

  - The `isTracking` parameter is unused in the body. Keep it for call-site clarity, or drop it from both the function and the call. Pick one and match the tests.

- [ ] **Step 7: Rewrite `Mac/UI/MenuBarView.swift`** (mockup "Mac · menu bar panel"):

```swift
import StintData
import SwiftUI
import SwiftData
import Core

struct MenuBarLabel: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if let p = app.project {
            if app.tracker.onBreak {
                Text("Break \(app.todayStats().breakLeftSec / 60)m").monospacedDigit()
            } else {
                HStack(spacing: 4) {
                    Image(systemName: p.icon ?? "circle.fill")
                    Text("\(p.menuTitle) \(hoursMinutes(app.focusedToday(p.id)))").monospacedDigit()
                }
            }
        } else {
            Image(systemName: "timer")
        }
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]

    var body: some View {
        let stats = app.todayStats()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WORKING ON").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Today \(hoursMinutes(stats.focusedSec)) · \(stats.points >= 0 ? "+" : "")\(stats.points) pts")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if projects.isEmpty {
                Text("Add a project in Stint to start tracking.").foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(Array(projects.prefix(9).enumerated()), id: \.element.id) { i, p in
                    ProjectRowButton(project: p, number: i + 1)
                }
            }
            if app.nudge != nil {
                HStack {
                    Text("Off task").foregroundStyle(Theme.warn).bold()
                    Spacer()
                    Button("Back to work") { app.backToTask() }
                }
                .padding(8).background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if app.automationDenied {
                Text("Site checks are off — allow Stint to control Safari/Chrome in System Settings › Privacy & Security › Automation")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            Divider()
            HStack {
                Button { app.tracker.onBreak ? app.resume() : app.takeBreak() } label: {
                    VStack(spacing: 1) {
                        Text(app.tracker.onBreak ? "Resume" : "Break").bold()
                        Text("\(stats.breakLeftSec / 60) min left today").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
                Button(role: .destructive) { app.stop() } label: { Text("Stop").bold().frame(maxWidth: .infinity) }
            }
            .controlSize(.large)
            .disabled(!app.isTracking)
            HStack {
                Spacer()
                Button("Open Stint") { NSApp.activate(); openWindow(id: "main") }.buttonStyle(.link)
                Button("Quit") { app.stop(); NSApplication.shared.terminate(nil) }.buttonStyle(.link)
            }.font(.caption)
        }
        .padding(14).frame(width: 340)
    }
}

/// One project row: a click switches to it (spec §6.2). Number keys 1–9 work while the panel is open.
private struct ProjectRowButton: View {
    @Environment(AppState.self) private var app
    let project: Project
    let number: Int

    var body: some View {
        let on = app.tracker.currentID == project.id
        let tint = Color(hex: project.colorHex)
        Button { app.switchTo(project) } label: {
            HStack(spacing: 12) {
                ProjectIcon(name: project.name, colorHex: project.colorHex, icon: project.icon, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.callout.weight(.semibold))
                    if on { Text("Tracking now").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(hoursMinutes(app.focusedToday(project.id))).monospacedDigit().fontWeight(on ? .bold : .regular)
                Text("\(number)").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
            }
            .padding(.horizontal, 10).frame(minHeight: 48)
            .background(on ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? tint : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
        .accessibilityLabel("\(project.name), \(hoursMinutes(app.focusedToday(project.id))) today\(on ? ", tracking now" : "")")
    }
}
```

- [ ] **Step 8: Update the nudge and the Mac Today screen. Delete the start controls.**
  - `NudgeView` (`NudgePanel.swift`):
    - Title: `Text("\(name) isn't on \(app.project?.name ?? "this project")'s list").font(.headline)`.
    - Body: `Text("Off-task time doesn't count toward your goal and costs \(-PointRules.perOfftaskMinute) points a minute.")`. Delete the `left` constant.
    - Back button: `Button("Back to \(app.tracker.engine?.lastOnTaskBundleID.map(appName) ?? "work")")`.
    - Allow button: `Button("It's work: allow for \(app.project?.menuTitle ?? "this project")")`.
  - `Mac/UI/TodayView.swift`:
    - Delete the `startBar` property and its use in `body`.
    - Change `(app.engine?.totals(at: now).offtaskSec ?? 0)` to `(app.tracker.engine?.totals(at: now).offtaskSec ?? 0)`.
  - Delete `Mac/UI/StartSessionControls.swift`, then grep `Mac/` for `StartSessionControls` and `EndEarlySheet`. Neither may remain in the Mac target.

- [ ] **Step 9: Update the phone call sites** (Task 11 redesigns these screens; this step only keeps them compiling and working).
  - `iOS/PhoneSync.swift`: `openStart(_:)` and `flushPendingStart()` send `.switchTo(projectID: id)`.
  - `iOS/UI/TodayView.swift`:
    - `StartCard`:
      - title "Switch on your Mac";
      - delete the Length and First task pickers, and the `minutes`/`taskID` state;
      - the button is "Switch" and sends `.switchTo(projectID: id)`;
      - remove `.onChange(of: projectID) { taskID = nil }`.
    - `SessionCard`:
      - the clock shows `remainingText(running.totals(at: tl.date).focusedSec)`;
      - the break button sends `running.onBreak ? .breakEnd : .breakStart`;
      - replace "End early…" with `Button("Stop") { Task { await sync.send(.stop) } }.buttonStyle(.bordered)`;
      - delete `endSheet` and its `.sheet`.
  - `Widgets/StintWidgets.swift`: change the Start label to `Label("Switch", systemImage: "arrow.left.arrow.right")`.
  - `iOSTests/PhoneSyncTests.swift`: no change needed (it builds `RunningSession` directly).

- [ ] **Step 10: Regenerate, build and test.**
  - Run `xcodegen generate`.
  - Then the SwiftPM tests, the Mac tests and the iOS tests.
  - Expected: all pass. `SmokeTests.coreLinks` still passes, because `PointRules.sessionComplete` exists until Task 12.

- [ ] **Step 11: Smoke-test by hand on the Mac.**
  - Build and launch `StintMac`. Click a project row: the title shows the icon, short name and `0:00`.
  - Click another row, then Stop: the title goes back to the timer icon.
  - Run `supabase db query --local "select project_id, end_kind, planned_min from session order by started_at desc limit 3"`. Expected: `switched`, then `stopped`, with `planned_min` null. If the local CLI needs a different flag, use the one the earlier plans used.

- [ ] **Step 12: Commit.**

```bash
git add -A Shared Mac MacTests SharedUI iOS Widgets Stint.xcodeproj
git commit -m "feat(mac): one current project, menu bar switching, switch/stop/break commands

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `⌃⌥Space` switcher

**Files:**
- Create: `Mac/App/Hotkey.swift`
- Create: `Mac/UI/Switcher.swift`
- Modify: `Mac/StintApp.swift`
- Modify: `Mac/App/AppState.swift` (add `var hotkeyUnavailable = false`)
- Modify: `Mac/UI/MenuBarView.swift` (hotkey hint)
- Test: `MacTests/SwitcherTests.swift`

**Interfaces:**
- Consumes: `AppState.switchTo/switchToPrevious/stop/takeBreak/resume/activeProjects/previousProject/project/tracker`, `ProjectIcon`, `hoursMinutes`.
- Produces:
  - `Hotkey(action:)` with `.register()` and `.registered`
  - `Switcher.order(_:current:previous:) -> [Project]`
  - `Switcher.filter(_:query:) -> [Project]`
  - `Switcher.pressAction(sinceLast: TimeInterval?, isOpen: Bool) -> Switcher.Press` (`.open`, `.close`, `.flipBack`)
  - `SwitcherController.hotkeyPressed(_ app: AppState)`

- [ ] **Step 1: Write the failing test** `MacTests/SwitcherTests.swift`:

```swift
import Foundation
import Testing
import StintData
@testable import Stint

@MainActor @Suite struct SwitcherTests {
    @Test func previousFirstThenByName() {
        let a = Project(name: "Admin"), c = Project(name: "Christian Heritage"), f = Project(name: "Freelance")
        let rows = Switcher.order([a, c, f], current: c.id, previous: f.id)
        #expect(rows.map(\.name) == ["Freelance", "Admin", "Christian Heritage"])
        #expect(Switcher.order([a, c, f], current: nil, previous: nil).map(\.name) == ["Admin", "Christian Heritage", "Freelance"])
    }

    @Test func filterMatchesNameOrShortName() {
        let c = Project(name: "Christian Heritage"); c.shortName = "CHL"
        let s = Project(name: "Sermon prep")
        #expect(Switcher.filter([c, s], query: "chl").map(\.name) == ["Christian Heritage"])
        #expect(Switcher.filter([c, s], query: "SER").map(\.name) == ["Sermon prep"])
        #expect(Switcher.filter([c, s], query: " ").count == 2)
    }

    @Test func doublePressFlipsBack() {
        #expect(Switcher.pressAction(sinceLast: nil, isOpen: false) == .open)
        #expect(Switcher.pressAction(sinceLast: 0.3, isOpen: true) == .flipBack)
        #expect(Switcher.pressAction(sinceLast: 0.6, isOpen: true) == .close)
        #expect(Switcher.pressAction(sinceLast: 0.3, isOpen: false) == .open)
    }
}
```

- [ ] **Step 2: Run it and check it fails.** Run the Mac tests. Expected: `cannot find 'Switcher' in scope`.

- [ ] **Step 3: Write** `Mac/App/Hotkey.swift`:

```swift
import AppKit
import Carbon.HIToolbox

/// ⌃⌥Space through Carbon `RegisterEventHotKey`: global, and no Accessibility permission (spec 2026-11-26 §6.3).
@MainActor
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var registered = false

    init(action: @escaping () -> Void) { self.action = action }

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.action() } // Carbon delivers application events on the main thread
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x5354_4E54), id: 1) // 'STNT'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
    }
}
```

- [ ] **Step 4: Write** `Mac/UI/Switcher.swift`:

```swift
import AppKit
import SwiftUI
import StintData
import Core

enum Switcher {
    enum Press: Equatable { case open, close, flipBack }

    /// The previous project first (Return flips back), then the rest by name.
    static func order(_ projects: [Project], current: UUID?, previous: UUID?) -> [Project] {
        let sorted = projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let previous, previous != current, let p = sorted.first(where: { $0.id == previous }) else { return sorted }
        return [p] + sorted.filter { $0.id != previous }
    }

    static func filter(_ projects: [Project], query: String) -> [Project] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.shortName ?? "").localizedCaseInsensitiveContains(q) }
    }

    /// A second press within 0.4 s of the first, while the panel is open, flips back to the previous project.
    static func pressAction(sinceLast: TimeInterval?, isOpen: Bool) -> Press {
        guard isOpen else { return .open }
        if let s = sinceLast, s < 0.4 { return .flipBack }
        return .close
    }
}

/// A panel that can take typing without activating Stint.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SwitcherController {
    private var panel: NSPanel?
    private var lastPress: Date?
    private var resignObserver: NSObjectProtocol?

    func hotkeyPressed(_ app: AppState) {
        let now = Date()
        let action = Switcher.pressAction(sinceLast: lastPress.map { now.timeIntervalSince($0) }, isOpen: panel != nil)
        lastPress = now
        switch action {
        case .open: show(app)
        case .close: hide()
        case .flipBack: hide(); app.switchToPrevious()
        }
    }

    private func show(_ app: AppState) {
        let rows = Switcher.order(app.activeProjects, current: app.tracker.currentID, previous: app.tracker.previousID)
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 10),
                         styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true; p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: SwitcherView(projects: rows, close: { [weak self] in self?.hide() }).environment(app))
        p.contentView = host
        p.setContentSize(host.fittingSize)
        p.center()
        p.makeKeyAndOrderFront(nil)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        panel = p
    }

    func hide() {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        panel?.close(); panel = nil
    }
}

/// Spotlight-style switcher (mockup "Mac · ⌃⌥Space switcher"). 1–9 or Return switches, ⌘S stops, ⌘B breaks, Esc closes.
struct SwitcherView: View {
    @Environment(AppState.self) private var app
    let projects: [Project]
    let close: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let rows = Array(Switcher.filter(projects, query: query).prefix(9))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                TextField("Switch to…", text: $query)
                    .textFieldStyle(.plain).font(.title2).focused($focused)
                    .onSubmit { pick(rows.first) }
                    .onKeyPress(characters: .decimalDigits) { press in
                        guard let n = Int(press.characters), n >= 1, n <= rows.count else { return .ignored }
                        pick(rows[n - 1]); return .handled
                    }
                    .onExitCommand(perform: close)
                Text("On: \(app.project?.name ?? "nothing")").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, p in row(i, p) }
            }.padding(8)
            Divider()
            HStack(spacing: 16) {
                hint("1–\(max(1, rows.count))", "switch")
                hint("⌃⌥Space", "again: back to \(app.previousProject?.name ?? "previous")")
                hint("⌘S", "stop"); hint("⌘B", "break"); hint("esc", "cancel")
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 520)
        .background {
            Button("Stop") { app.stop(); close() }.keyboardShortcut("s", modifiers: .command).hidden()
            Button("Break") { app.tracker.onBreak ? app.resume() : app.takeBreak(); close() }
                .keyboardShortcut("b", modifiers: .command).hidden()
        }
        .onAppear { focused = true }
    }

    private func row(_ i: Int, _ p: Project) -> some View {
        let first = i == 0
        let tag = p.id == app.tracker.currentID ? "current" : p.id == app.tracker.previousID ? "previous" : ""
        return Button { pick(p) } label: {
            HStack(spacing: 14) {
                Text("\(i + 1)").font(.callout.weight(.bold)).monospacedDigit().frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(first ? .white.opacity(0.7) : .secondary, lineWidth: 1.5))
                ProjectIcon(name: p.name, colorHex: p.colorHex, icon: p.icon, size: 34)
                Text(p.name).font(.body.weight(.semibold))
                Spacer()
                Text(tag).font(.caption).opacity(0.85)
                Text(hoursMinutes(app.focusedToday(p.id))).monospacedDigit()
            }
            .padding(.horizontal, 12).frame(minHeight: 52)
            .foregroundStyle(first ? .white : .primary)
            .background(first ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) { Text(key).bold().foregroundStyle(.primary); Text(label) }
    }

    private func pick(_ p: Project?) {
        if let p { app.switchTo(p) }
        close()
    }
}
```

- [ ] **Step 5: Wire it up.**
  - In `AppState`, add `var hotkeyUnavailable = false` under `automationDenied`.
  - In `StintApp`, add the properties `let switcher = SwitcherController()` and `let hotkey: Hotkey`. At the end of `init`, after `_sync = …`, add:

```swift
        let switcher = self.switcher
        hotkey = Hotkey { switcher.hotkeyPressed(state) }
        hotkey.register()
        state.hotkeyUnavailable = !hotkey.registered
```

  - Swift needs every stored property set before `self` is used. If it complains, move `let switcher = SwitcherController()` to a local before the `self.switcher` assignment, and assign `self.switcher = switcher` explicitly.
  - In `MenuBarView`, put this hint at the start of the last `HStack`, before the `Spacer()`:

```swift
                Text(app.hotkeyUnavailable ? "Hotkey unavailable" : "Switch anywhere: ⌃⌥Space").foregroundStyle(.secondary)
```

- [ ] **Step 6: Regenerate and test.** Run `xcodegen generate`, then the Mac tests. Expected: `SwitcherTests` (3) pass, and everything else still passes.

- [ ] **Step 7: Test by hand.** Launch `StintMac` and switch to project A, then B.
  - Press `⌃⌥Space`: the panel opens with A first and highlighted.
  - Press Return: tracking switches to A.
  - Press `⌃⌥Space` twice quickly: it switches to B without leaving the panel open.
  - Press `⌃⌥Space`, type "ser", press Return: tracking switches to the matching project.
  - Esc closes the panel.
  - ⌘S stops tracking.

- [ ] **Step 8: Commit.**

```bash
git add -A Mac MacTests Stint.xcodeproj
git commit -m "feat(mac): ⌃⌥Space switcher with double-press flip back

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Suggested switch with Undo

**Files:**
- Modify: `Mac/App/AppState.swift`
- Modify: `Mac/UI/NudgePanel.swift` (the controller takes its content; add `SuggestView`)
- Test: `MacTests/SuggestTests.swift`

**Interfaces:**
- Consumes: `SwitchSuggester` (Task 2), `AppState.switchTo(_:at:)`.
- Produces:
  - `AppState.suggestion: SwitchSuggester.Suggestion?`
  - `AppState.undo: SwitchUndo?`
  - `AppState.acceptSuggestion()`, `staySuggestion()`, `undoSwitch()`
  - `struct SwitchUndo { fromID: UUID; since: Date; until: Date; suggestion: SwitchSuggester.Suggestion }`
  - `NudgePanelController(content:)`

- [ ] **Step 1: Write the failing test** `MacTests/SuggestTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct SuggestTests {
    @Test func acceptBackdatesAndUndoGoesBack() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "CHL"), b = Project(name: "Freelance")
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        app.switchTo(a)
        let since = Date().addingTimeInterval(-12)
        app.suggestion = SwitchSuggester.Suggestion(projectID: b.id, since: since, bundleID: "com.apple.safari", host: "figma.com")
        app.acceptSuggestion()
        #expect(app.tracker.currentID == b.id && app.suggestion == nil)
        let bRow = try #require(app.record)
        #expect(bRow.startedAt == max(since, bRow.startedAt))
        #expect(app.undo?.fromID == a.id)
        app.undoSwitch()
        #expect(app.tracker.currentID == a.id && app.undo == nil)
        app.stop()
    }

    @Test func stayDismissesWithoutSwitching() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = Project(name: "CHL"), b = Project(name: "Freelance")
        c.mainContext.insert(a); c.mainContext.insert(b); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        app.switchTo(a)
        app.suggestion = SwitchSuggester.Suggestion(projectID: b.id, since: .now, bundleID: "com.apple.safari", host: "figma.com")
        app.staySuggestion()
        #expect(app.tracker.currentID == a.id && app.suggestion == nil)
        app.stop()
    }
}
```

- [ ] **Step 2: Run it and check it fails.** Run the Mac tests. Expected: `value of type 'AppState' has no member 'suggestion'`.

- [ ] **Step 3: Make the panel controller generic.** In `NudgePanel.swift`, change `NudgePanelController`:
  - Add `private let content: (AppState) -> AnyView` and `init(content: @escaping (AppState) -> AnyView) { self.content = content }`.
  - In `show`, build `NSHostingView(rootView: content(app))`.
  - Add `func refit() { if let p = panel, let v = p.contentView { p.setContentSize(v.fittingSize) } }`.
  - Then append `SuggestView`:

```swift
/// "Looks like Freelance — switch?" (spec 2026-11-26 §5.4; mockup "Mac · suggested switch").
struct SuggestView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if let s = app.suggestion, let to = app.findProject(s.projectID) {
                let here = app.project?.menuTitle ?? "this project"
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        ProjectIcon(name: to.name, colorHex: to.colorHex, icon: to.icon, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Looks like \(to.name)").font(.headline)
                            Text("\(s.host ?? appName(s.bundleID)) is on \(to.name)'s list. You're tracking \(app.project?.name ?? "another project").")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Switch from \(s.since.formatted(date: .omitted, time: .shortened))") { app.acceptSuggestion() }
                            .buttonStyle(.borderedProminent).tint(Color(hex: to.colorHex))
                        Button("Stay on \(here)") { app.staySuggestion() }
                    }
                    Text("Ignore it and the time stays on \(here) as off-task.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let u = app.undo, let to = app.project {
                HStack {
                    Text("Switched to \(to.name) · counted from \(u.since.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Button("Undo") { app.undoSwitch() }
                }
            }
        }
        .padding(16).frame(width: 340, alignment: .leading)
    }
}
```

- [ ] **Step 4: Add suggestions to `AppState`.**
  - Above `AppState`, add:

```swift
struct SwitchUndo: Equatable { var fromID: UUID; var since: Date; var until: Date; var suggestion: SwitchSuggester.Suggestion }
```

  - Replace `@ObservationIgnored private let nudgePanel = NudgePanelController()` with:

```swift
    @ObservationIgnored private let nudgePanel = NudgePanelController { AnyView(NudgeView().environment($0)) }
    @ObservationIgnored private let suggestPanel = NudgePanelController { AnyView(SuggestView().environment($0)) }
    @ObservationIgnored private var suggester = SwitchSuggester()
    var suggestion: SwitchSuggester.Suggestion? { didSet { updateSuggestPanel() } }
    var undo: SwitchUndo? { didSet { updateSuggestPanel() } }
```

  - Add the methods:

```swift
    func acceptSuggestion() {
        guard let s = suggestion, let to = findProject(s.projectID), let from = tracker.currentID else { return }
        suggestion = nil
        switchTo(to, at: s.since)
        undo = SwitchUndo(fromID: from, since: s.since, until: Date().addingTimeInterval(10), suggestion: s)
    }

    func staySuggestion() {
        guard let s = suggestion else { return }
        suggester.mute(s)
        suggestion = nil
    }

    func undoSwitch() {
        guard let u = undo, Date() < u.until, let p = findProject(u.fromID) else { undo = nil; return }
        undo = nil
        switchTo(p, at: u.since) // the suggested stretch ends with zero length
        suggester.mute(u.suggestion) // after the switch: a new stretch resets mutes
    }

    private func updateSuggestPanel() {
        if suggestion == nil && undo == nil { suggestPanel.hide(); return }
        suggestPanel.hide(); suggestPanel.show(self) // content size changes between ask and undo
    }

    private var candidates: [SwitchSuggester.Candidate] {
        activeProjects.map { .init(id: $0.id, allowlist: Self.tracked($0).allowlist) }
    }
```

  - In `observe(bundleID:host:)`, after the `run` line:

```swift
        if let s = suggester.observe(bundleID: bundleID, host: host, current: tracker.currentID, projects: candidates, at: .now) {
            suggestion = s
        } else if let s = suggestion, suggester.pending?.projectID != s.projectID {
            suggestion = nil // you moved away before deciding
        }
```

  - In `tick()`, after the `run` line:

```swift
        if let s = suggester.tick(at: now) { suggestion = s; nudge = nil }
        if let u = undo, now >= u.until { undo = nil }
```

  - In `apply`:
    - In `.started`, add `suggester.reset(); suggestion = nil` after `project = findProject(id)`.
    - In `.offTaskStarted`, wrap the nudge in `if suggestion?.bundleID != bundleID || suggestion?.host != host { … }`, so the suggestion panel replaces the nudge for that app (spec §5.4).
  - In `stopMonitoring()`, add `suggestion = nil; undo = nil`.

- [ ] **Step 5: Test.** Run the Mac tests. Expected: `SuggestTests` (2) pass, and all others still pass.

- [ ] **Step 6: Test by hand.**
  - Give project B the website `figma.com`, then start tracking A.
  - Open figma.com in Safari for 10 s: "Looks like B" appears.
  - Click Switch: the menu bar title shows B, and the Undo row shows for 10 s.
  - Click Undo: tracking goes back to A, and figma.com doesn't prompt again during this stretch.
  - Repeat, and click "Stay on A": the panel closes, and after 15 s off-task counts as before.

- [ ] **Step 7: Commit.**

```bash
git add -A Mac MacTests
git commit -m "feat(mac): suggest switching when another project owns the app, with Undo

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Projects editor fields. Hide tasks on the Mac.

**Files:**
- Create: `Mac/UI/IconPicker.swift`
- Modify: `Mac/UI/ProjectsView.swift`
- Modify: `Mac/UI/TodayView.swift`

**Interfaces:**
- Consumes: `Project.icon/shortName/offMac`, `ProjectIcon`.
- Produces: `IconPicker(selection: Binding<String?>, colorHex: String)`, `ProjectSymbols.all` (24 names).

- [ ] **Step 1: Write** `Mac/UI/IconPicker.swift`:

```swift
import SwiftUI

enum ProjectSymbols {
    /// Spec 2026-11-26 §6.4.
    static let all = ["building.columns", "briefcase", "book", "hammer", "paintbrush", "laptopcomputer", "music.note", "cross",
                      "house", "graduationcap", "camera", "chart.bar", "doc.text", "envelope", "globe", "heart", "leaf",
                      "lightbulb", "megaphone", "person.2", "star", "terminal", "timer", "wrench"]
}

struct IconPicker: View {
    @Binding var selection: String?
    let colorHex: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
            cell(nil)
            ForEach(ProjectSymbols.all, id: \.self) { cell($0) }
        }
    }

    private func cell(_ name: String?) -> some View {
        Button { selection = name } label: {
            Group {
                if let name { Image(systemName: name) } else { Text("Aa").font(.caption.bold()) }
            }
            .frame(width: 30, height: 30)
            .foregroundStyle(selection == name ? .white : .primary)
            .background(selection == name ? Color(hex: colorHex) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name ?? "Initials")
    }
}
```

- [ ] **Step 2: Add the fields to the project editor.** In `ProjectsView.swift`, after the colour `HStack` and before `goals`:

```swift
                GroupBox("Switching") {
                    VStack(alignment: .leading, spacing: 10) {
                        IconPicker(selection: Binding(get: { project.icon }, set: { project.icon = $0; project.updatedAt = .now }),
                                   colorHex: project.colorHex)
                        HStack {
                            Text("Short name")
                            TextField(String(project.name.prefix(12)), text: Binding(
                                get: { project.shortName ?? "" },
                                set: { project.shortName = $0.isEmpty ? nil : $0; project.updatedAt = .now })).frame(width: 160)
                        }
                        Toggle("Off-Mac work", isOn: edit(\.offMac))
                        Text("Idle and off-task checks are off while this project is current.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
```

In `goals`, delete the `HStack` holding the "Tasks done" `GoalField` and the Period `Picker` (spec §2: tasks hidden). If `edit(_:)` is constrained to particular key path types and rejects `\.offMac`, use `Binding(get: { project.offMac }, set: { project.offMac = $0; project.updatedAt = .now })`.

- [ ] **Step 3: Hide the task UI on the Mac Today screen.** In `Mac/UI/TodayView.swift`:
  - delete the "Dictate tasks" button;
  - delete the `.sheet(isPresented: $dictating)` block and the `dictating` state;
  - delete the `VStack` that holds "Today's tasks";
  - delete the `@Query private var openTasks` if it exists and nothing else uses it.
  - Leave `TaskGroup` and `DictateView` in the codebase (spec §2: code stays).

- [ ] **Step 4: Build and check by hand.**
  - Run `xcodegen generate`, then the Mac tests. Expected: pass.
  - Launch, open Projects:
    - pick the `book` icon and type the short name "Sermon": the menu bar shows them while that project is current;
    - toggle Off-Mac, switch to that project, and leave the Mac untouched for 6 minutes: the time keeps counting (no idle).
  - Today has no Dictate button and no Today's tasks.

- [ ] **Step 5: Commit.**

```bash
git add -A Mac Stint.xcodeproj
git commit -m "feat(mac): project icon, short name and off-Mac toggle; hide tasks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: iPhone: Desk mode, tabs, Today, Desk widget

**Files:**
- Create: `iOS/UI/DeskView.swift`
- Modify: `iOS/UI/RootView.swift`, `iOS/UI/TodayView.swift`, `iOS/PhoneSync.swift`
- Rename: `SharedUI/StartLink.swift` → `SharedUI/DeskLink.swift` (update `project.yml` line ~151)
- Modify: `Widgets/StintWidgets.swift` (`StartWidget`)
- Test: `iOSTests/WidgetPlumbingTests.swift` (the `StartLink` cases)

**Interfaces:**
- Consumes: `SessionCommand.switchTo/stop/breakStart/breakEnd`, `PhoneSync.send/running/snapshot/commandStatus/waiting`, `ProjectIcon`, `hoursMinutes`.
- Produces: `DeskLink.url` and `DeskLink.matches(_:)`, and `DeskView`.

- [ ] **Step 1: Update the failing test.** In `WidgetPlumbingTests.swift`, replace the four `StartLink` lines with:

```swift
        #expect(DeskLink.matches(DeskLink.url))
        #expect(DeskLink.url.absoluteString == "stint://desk")
        #expect(!DeskLink.matches(URL(string: "stint://start?project=\(UUID())")!))
        #expect(!DeskLink.matches(URL(string: "https://desk")!))
```

Remove the `let id = UUID()` above them if nothing else uses it.

- [ ] **Step 2: Rename the link.** `git mv SharedUI/StartLink.swift SharedUI/DeskLink.swift`. Replace its contents:

```swift
import Foundation

/// The Desk widget's link (spec 2026-11-26 §7.1).
enum DeskLink {
    static let url = URL(string: "stint://desk")!
    static func matches(_ url: URL) -> Bool { url.scheme == "stint" && url.host() == "desk" }
}
```

In `project.yml`, change `SharedUI/StartLink.swift` to `SharedUI/DeskLink.swift`.

- [ ] **Step 3: Remove the start-link plumbing from `PhoneSync`.**
  - Delete `pendingStart`, `openStart(_:)` and `flushPendingStart()`.
  - Delete the `await flushPendingStart()` call in `resume()`.
  - Turn `else { pendingStart = nil; return }` into `else { return }`.
  - Delete every other `pendingStart = nil` (lines ~111, 115, 139).
  - Update the comment in `resume()` that mentions a start tapped before launch.

- [ ] **Step 4: Write** `iOS/UI/DeskView.swift`:

```swift
import SwiftUI
import SwiftData
import UIKit
import Core
import StintData

/// Phone-on-a-stand switch panel (spec 2026-11-26 §7.1; mockup "iPhone · Desk mode").
/// Taps send commands; nothing changes here until the Mac acts and its row syncs back.
struct DeskView: View {
    @Environment(PhoneSync.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @State private var sending: String?
    @State private var shake: String?

    var body: some View {
        let running = sync.running
        let lines = sync.snapshot?.lines ?? []
        GeometryReader { geo in
            let columns = geo.size.width > geo.size.height ? 3 : 2
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(running, projects: projects, lines: lines)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(projects) { p in
                            tile(key: p.id.uuidString, on: running?.projectID == p.id, color: Color(hex: p.colorHex),
                                 title: p.name, sub: "\(hoursMinutes(lines.first { $0.id == p.id }?.todayFocusedSec ?? 0)) today") {
                                ProjectIcon(name: p.name, colorHex: p.colorHex, icon: p.icon, size: 52)
                            } action: { .switchTo(projectID: p.id) }
                        }
                        tile(key: "break", on: running?.onBreak == true, color: .gray,
                             title: running?.onBreak == true ? "On break" : "Break", sub: "Pause the current project") {
                            symbol("cup.and.saucer")
                        } action: { running?.onBreak == true ? .breakEnd : .breakStart }
                        tile(key: "stop", on: running == nil, color: Color(red: 1, green: 0.54, blue: 0.5),
                             title: running == nil ? "Stopped" : "Stop", sub: running == nil ? "Tap a project to start" : "Done for now") {
                            symbol("stop.fill")
                        } action: { .stop }
                    }
                    if let s = sync.commandStatus, sending == nil { Text(s).font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(24)
            }
        }
        .background(Color(red: 0.055, green: 0.059, blue: 0.071).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) { Button("Done") { dismiss() }.padding() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func header(_ running: RunningSession?, projects: [Project], lines: [WidgetSnapshot.Line]) -> some View {
        let p = projects.first { $0.id == running?.projectID }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(running == nil ? "NOT TRACKING" : running!.onBreak ? "PAUSED" : "WORKING ON")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Text(p?.name ?? "Nothing").font(.title2.bold())
            if let running {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    Text(remainingText(running.totals(at: tl.date).focusedSec)).font(.title2.bold().monospacedDigit())
                        .foregroundStyle(Color(hex: p?.colorHex ?? "#A1A1AA"))
                }
            }
            Spacer()
            Text("Today \(hoursMinutes(sync.snapshot?.todayFocusedSec ?? 0)) · \(sync.snapshot?.pointsToday ?? 0) pts")
                .font(.footnote).foregroundStyle(.secondary)
            Label(running.map { $0.isStale(at: .now) } == true ? "Mac quiet" : "Mac connected", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.trailing, 60) // clear of Done
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 26, weight: .semibold)).frame(width: 52, height: 52)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tile<Icon: View>(key: String, on: Bool, color: Color, title: String, sub: String,
                                  @ViewBuilder icon: () -> Icon, action: @escaping () -> SessionCommand) -> some View {
        Button {
            guard sending == nil else { return }
            sending = key
            Task {
                await sync.send(action())
                if sync.commandStatus != nil { shake = key }
                sending = nil
            }
        } label: {
            HStack(spacing: 14) {
                icon()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(sub).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if sending == key { ProgressView() }
            }
            .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(on ? color.opacity(0.35) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(on ? color : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .phaseAnimator([0, 8, -8, 0], trigger: shake == key) { v, x in v.offset(x: x) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
```

- [ ] **Step 5: Tabs, Today and the deep link.**
  - `RootView.swift`:
    - `enum Tab: Hashable { case today, week, rewards }`.
    - Remove the Tasks and Dictate tabs.
    - Add `@State private var desk = false`.
    - `onOpenURL`: `tab = .today; if DeskLink.matches(url) { desk = true }`.
    - Add `.fullScreenCover(isPresented: $desk) { DeskView() }` on the `TabView`.
  - `iOS/UI/TodayView.swift`:
    - Delete the "Up next" section and the `openTasks` query.
    - In the first `Section`, after the card, add a Desk mode button. `TodayView` needs its own `@State private var desk = false` for it:

```swift
                    Button { desk = true } label: { Label("Desk mode", systemImage: "square.grid.2x2") }
```

      Put the `.fullScreenCover(isPresented: $desk) { DeskView() }` on the `NavigationStack`.
    - `SessionCard`: delete the task line and the `task` constant.
    - Rename the "This week" section to "Today": `ForEach(sync.snapshot?.lines ?? []) { l in HStack { Circle().fill(Color(hex: l.colorHex)).frame(width: 10, height: 10); Text(l.name); Spacer(); Text(hoursMinutes(l.todayFocusedSec)).monospacedDigit() } }`. Keep the `WeekBars` section below it as "This week".
  - `Widgets/StintWidgets.swift` `StartWidget`: replace the content `Group` with:

```swift
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "square.grid.2x2.fill").font(.title2)
                Spacer(minLength: 0)
                Text("Desk mode").font(.headline)
                Text("Tap a project to switch on your Mac").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(DeskLink.url)
            .containerBackground(.fill.tertiary, for: .widget)
```

    Set `.configurationDisplayName("Desk mode")` and `.description("Opens big project tiles for switching on your Mac.")`. Keep `kind: "start"` so placed widgets survive.

- [ ] **Step 6: Regenerate and test.** Run `xcodegen generate`, then the iOS tests. Expected: all pass.

- [ ] **Step 7: Test on the iPhone 11** (Release config = hosted). Build and install as in the device-log memory: `xcrun devicectl …`. Mac hosted build tracking.
  - Open Today → Desk mode, in landscape: 3 columns of tiles.
  - Tap another project: its tile spins, then glows, and the Mac menu bar switches.
  - Leave Desk mode open for 2 minutes: the screen doesn't dim.
  - The Live Activity updates the project name on each switch.
  - Tap Stop: the Live Activity ends.
  - Quit Stint on the Mac and tap a tile: the tile shakes and shows "Mac not reachable".

- [ ] **Step 8: Commit.**

```bash
git add -A iOS iOSTests SharedUI Widgets project.yml Stint.xcodeproj
git commit -m "feat(ios): Desk mode switch panel, Desk widget, Today/Week/Rewards tabs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Remove planned-length code

**Files:**
- Modify: `Shared/Sources/Core/SessionEngine.swift`, `Shared/Sources/Core/Points.swift`, `Shared/Sources/Core/SessionAccounting.swift`, `Shared/Sources/StintData/Ledger.swift`, `Shared/Sources/StintData/Sync/RunningSession.swift`
- Modify tests: `Shared/Tests/CoreTests/SessionEngineTests.swift`, `Shared/Tests/CoreTests/PointsTests.swift`, `Shared/Tests/StintDataTests/LedgerTests.swift`, `Shared/Tests/StintDataTests/RunningSessionTests.swift`, `MacTests/SmokeTests.swift`
- Delete if unused: `SharedUI/EndEarlySheet.swift` (or wherever `EndEarlySheet` lives)

**Interfaces:**
- Removes:
  - `SessionEngine.plannedMin`, `remainingSec`, `finish`, `Signal.reachedPlannedLength`, `SessionResult`;
  - `sessionPoints`, `breakOverAllowance`, `isComplete`, `SessionTotals.activeSec`, `PointRules.sessionComplete`;
  - `Ledger.openSession`, `Ledger.close`;
  - `RunningSession.plannedMin`, `RunningSession.remainingSec`.
- Keeps: `PointKind.sessionComplete` (old ledger rows decode with it).

- [ ] **Step 1: Delete the symbols, one at a time, building after each.**
  - Remove one listed symbol and run `cd Shared && swift test --disable-sandbox`.
  - Then delete or adjust the tests that only existed for it:
    - `SessionEngineTests` cases about planned length, completion or `finish`;
    - `PointsTests` for `sessionPoints`/`breakOverAllowance`;
    - `LedgerTests` for `openSession`/`close`;
    - `RunningSessionTests` for `remainingSec`;
    - `SmokeTests.coreLinks`, which becomes `#expect(PointRules.perFocusedMinute == 1)`.
  - `SessionEngine.init` becomes `init(startedAt:allowlist:)`. `Tracker.open` already calls it that way.
  - `Tracker.map` loses the `.reachedPlannedLength` case.
  - `RunningSession.init(row:events:)` stops reading `plannedMin`. `PhoneSyncTests` builds `RunningSession(…plannedMin: 25…)`: drop that argument.
  - Grep the whole repo for each removed name before deleting it: `grep -rn "remainingSec\|sessionPoints\|openSession\|plannedMin\|EndEarlySheet" Shared Mac iOS Widgets SharedUI MacTests iOSTests`. `SessionRecord.plannedMin`, `SessionRow.plannedMin` and the `Mapping` lines stay: they carry old rows.

- [ ] **Step 2: Run every suite.**
  - Run `xcodegen generate`.
  - Then SwiftPM, Mac, iOS, `deno test` and `supabase test db`.
  - Expected: all pass.

- [ ] **Step 3: Mark the old spec as superseded.** At the top of `docs/superpowers/specs/2026-11-24-freelance-focus-app-design.md`, under the title, add:

```markdown
> Sessions, ending early, planned length and the phone start flow (§6.3, §6.6, parts of §6.4–6.9) are superseded by `2026-11-26-switch-first-tracking-design.md`.
```

- [ ] **Step 4: Commit.**

```bash
git add -A Shared Mac MacTests iOS iOSTests SharedUI Widgets docs Stint.xcodeproj
git commit -m "refactor: drop planned-length session code

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Clean up build folders.** Run `rm -rf /private/tmp/claude-501/dd*`.
