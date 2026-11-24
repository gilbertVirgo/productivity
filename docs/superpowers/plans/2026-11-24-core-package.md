# Core Package Implementation Plan (plan 1 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `Core` Swift package. It is the pure, platform-free logic every app target shares: allowlist matching, the off-task state machine, session time accounting, day/week boundaries, goal status, and points.

**Architecture:** One SwiftPM package at `Shared/` with a single library target `Core` and one test target `CoreTests`. Only free functions and value types: no UI, no SwiftData, no AppKit/UIKit, no I/O, no clock reads (callers pass `Date`s in). The Mac and iOS apps (later plans) feed it events and persist its outputs.

**Tech Stack:** Swift 6 (language mode 6), SwiftPM, Swift Testing (`import Testing`), Foundation only.

**Spec:** `docs/superpowers/specs/2026-11-24-freelance-focus-app-design.md` (sections 6.1–6.7 are what this plan implements)

## Plan series

This spec is split into one plan per subsystem; each yields working, tested software:

1. **Core package** (this plan)
2. Supabase schema, RLS, period-close job
3. Mac app: projects/goals, sessions, ActivityMonitor, friction, points, menu bar (local data only)
4. Sync (outbox + Realtime + `session_command`)
5. iPhone app + widgets
6. Voice + `parse-tasks`
7. Live Activity + `push-activity`
8. Share page + `share-data`

## Global Constraints

- Platforms: macOS 14+, iOS 17.2+ (package declares `.macOS(.v14), .iOS(.v17)`; 17.2 is enforced by the app target).
- Swift tools version 6.0, Swift 6 language mode, strict concurrency: every public type is `Sendable`.
- `Core` depends on Foundation only. No third-party packages.
- Weeks start Monday 00:00 and days at 00:00, in the owner's timezone (passed in, never `TimeZone.current` inside Core).
- Off-task grace: 15 s. Idle threshold: 5 min (detected by the Mac layer; Core only receives `idle_start`/`idle_end`).
- Point values: focused minute +1, session completed +10, daily goal met +20, weekly goal met +100, off-task minute −2, over-allowance break minute −1. Partial minutes round down.
- Event type raw values must match the DB enum strings exactly: `offtask_start`, `offtask_end`, `break_start`, `break_end`, `idle_start`, `idle_end`, `sleep`, `wake`.
- Point kind raw values: `focus`, `session_complete`, `daily_goal`, `weekly_goal`, `offtask`, `break_over`, `redeem`.

## File map

```
Shared/
  Package.swift
  Sources/Core/
    Allowlist.swift        AllowKind, AllowEntry, Browsers, Allowlist.isOnTask
    OffTaskTracker.swift   grace-period state machine → started/ended outputs
    SessionAccounting.swift SessionEventType, SessionEvent, SessionTotals, sessionTotals(), isComplete()
    Periods.swift          PeriodCalendar: day/week intervals, ISO weekday, elapsed fraction
    Goals.swift            GoalStatus, goalStatus(), hasDailyGoal()
    Points.swift           PointRules, PointKind, PointLine, breakOverAllowance(), sessionPoints(), canRedeem()
  Tests/CoreTests/
    TestSupport.swift      date("…") helper
    AllowlistTests.swift
    OffTaskTrackerTests.swift
    SessionAccountingTests.swift
    PeriodsTests.swift
    GoalsTests.swift
    PointsTests.swift
```

Not in Core, on purpose: "System Settings is on-task while our permission prompt is showing" (spec 6.4). Only the Mac layer knows when it prompted, so plan 3 passes System Settings' bundle ID as an extra always-allowed ID at that moment via `Allowlist(entries:ownBundleID:extraAllowed:)`.

---

### Task 1: Toolchain, package scaffold, allowlist matching

**Files:**
- Create: `Shared/Package.swift`
- Create: `Shared/Sources/Core/Allowlist.swift`
- Create: `Shared/Tests/CoreTests/TestSupport.swift`
- Test: `Shared/Tests/CoreTests/AllowlistTests.swift`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum AllowKind: String { case app, domain }`
  - `struct AllowEntry: Hashable { kind: AllowKind; value: String; init(_ kind: AllowKind, _ value: String) }`. The value is lowercased on init.
  - `enum Browsers { static let safari: String; static let chrome: String; static let supported: Set<String> }`
  - `struct Allowlist { var entries: Set<AllowEntry>; init(entries: [AllowEntry], ownBundleID: String, extraAllowed: Set<String> = []); func isOnTask(bundleID: String, host: String?) -> Bool }`
  - test helper `func date(_ iso: String) -> Date`

- [ ] **Step 1: Install a working toolchain**

This machine's Command Line Tools are broken (`/Library/Developer/CommandLineTools/usr/bin/swiftc` is missing), and the apps need full Xcode anyway.
1. Install Xcode from the Mac App Store and open it once to accept the licence.
2. Point the command-line tools at it:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Verify:

```bash
swift --version && xcodebuild -version
```

Expected: Swift 6.x and Xcode 26.x printed, no errors.

- [ ] **Step 2: Branch**

```bash
git checkout -b core-package
```

- [ ] **Step 3: Create the package manifest and .gitignore**

`Shared/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
```

`.gitignore` (repo root):

```
.DS_Store
.build/
.swiftpm/
DerivedData/
xcuserdata/
```

- [ ] **Step 4: Write the test helper and failing allowlist tests**

`Shared/Tests/CoreTests/TestSupport.swift`:

```swift
import Foundation

/// Parse an ISO-8601 timestamp with offset, e.g. "2026-11-24T16:52:00Z" or "2026-11-24T10:30:00+11:00".
func date(_ iso: String) -> Date {
    guard let d = ISO8601DateFormatter().date(from: iso) else { fatalError("bad test date \(iso)") }
    return d
}
```

`Shared/Tests/CoreTests/AllowlistTests.swift`:

```swift
import Testing
@testable import Core

@Suite struct AllowlistTests {
    let own = "dev.focus.mac"
    func list(_ entries: [AllowEntry]) -> Allowlist { Allowlist(entries: entries, ownBundleID: own) }

    @Test func listedAppIsOnTask() {
        #expect(list([AllowEntry(.app, "com.figma.Desktop")]).isOnTask(bundleID: "com.figma.Desktop", host: nil))
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(list([AllowEntry(.app, "com.figma.desktop")]).isOnTask(bundleID: "COM.FIGMA.DESKTOP", host: nil))
    }

    @Test func unlistedAppIsOffTask() {
        #expect(!list([AllowEntry(.app, "com.figma.Desktop")]).isOnTask(bundleID: "com.spotify.client", host: nil))
    }

    @Test func ownAppAndSystemAreAlwaysOnTask() {
        let l = list([])
        #expect(l.isOnTask(bundleID: own, host: nil))
        #expect(l.isOnTask(bundleID: "com.apple.loginwindow", host: nil))
        #expect(l.isOnTask(bundleID: "com.apple.ScreenSaver.Engine", host: nil))
    }

    @Test func extraAllowedIsOnTask() {
        let l = Allowlist(entries: [], ownBundleID: own, extraAllowed: ["com.apple.systempreferences"])
        #expect(l.isOnTask(bundleID: "com.apple.systempreferences", host: nil))
    }

    @Test func browserOnListedDomainOrSubdomain() {
        let l = list([AllowEntry(.domain, "figma.com")])
        #expect(l.isOnTask(bundleID: Browsers.safari, host: "figma.com"))
        #expect(l.isOnTask(bundleID: Browsers.chrome, host: "www.Figma.com"))
    }

    @Test func lookalikeDomainsAreOffTask() {
        let l = list([AllowEntry(.domain, "figma.com")])
        #expect(!l.isOnTask(bundleID: Browsers.safari, host: "notfigma.com"))
        #expect(!l.isOnTask(bundleID: Browsers.safari, host: "figma.com.evil.io"))
        #expect(!l.isOnTask(bundleID: Browsers.safari, host: "youtube.com"))
    }

    @Test func browserListedAsAppAllowsAnySite() {
        #expect(list([AllowEntry(.app, Browsers.safari)]).isOnTask(bundleID: Browsers.safari, host: "youtube.com"))
    }

    @Test func unreadableHostGetsBenefitOfDoubtOnlyWhenDomainsListed() {
        #expect(list([AllowEntry(.domain, "figma.com")]).isOnTask(bundleID: Browsers.safari, host: nil))
        #expect(!list([AllowEntry(.app, "com.figma.Desktop")]).isOnTask(bundleID: Browsers.safari, host: nil))
    }

    @Test func unsupportedBrowserJudgedAsAppOnly() {
        let l = list([AllowEntry(.domain, "figma.com")])
        #expect(!l.isOnTask(bundleID: "org.mozilla.firefox", host: "figma.com"))
    }
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `cd Shared && swift test --filter AllowlistTests`
Expected: build FAIL with "cannot find 'Allowlist' in scope" (and similar for `AllowEntry`, `Browsers`).

- [ ] **Step 6: Implement**

`Shared/Sources/Core/Allowlist.swift`:

```swift
import Foundation

public enum AllowKind: String, Codable, Sendable {
    case app, domain
}

/// One on-task rule: an app bundle ID or a website domain. Values are stored lowercased.
public struct AllowEntry: Hashable, Codable, Sendable {
    public var kind: AllowKind
    public var value: String

    public init(_ kind: AllowKind, _ value: String) {
        self.kind = kind
        self.value = value.lowercased()
    }
}

public enum Browsers {
    public static let safari = "com.apple.safari"
    public static let chrome = "com.google.chrome"
    /// Browsers whose active-tab URL the Mac app can read via AppleScript.
    public static let supported: Set<String> = [safari, chrome]
}

public struct Allowlist: Sendable {
    public var entries: Set<AllowEntry>
    private let alwaysAllowed: Set<String>

    static let systemAlwaysAllowed: Set<String> = ["com.apple.loginwindow", "com.apple.screensaver.engine"]

    public init(entries: [AllowEntry], ownBundleID: String, extraAllowed: Set<String> = []) {
        self.entries = Set(entries)
        self.alwaysAllowed = Self.systemAlwaysAllowed
            .union([ownBundleID.lowercased()])
            .union(extraAllowed.map { $0.lowercased() })
    }

    /// - Parameters:
    ///   - bundleID: the frontmost app.
    ///   - host: the active tab's host when `bundleID` is a supported browser and it could be read; otherwise nil.
    public func isOnTask(bundleID: String, host: String?) -> Bool {
        let id = bundleID.lowercased()
        if alwaysAllowed.contains(id) || entries.contains(AllowEntry(.app, id)) { return true }
        guard Browsers.supported.contains(id) else { return false }
        let domains = entries.filter { $0.kind == .domain }.map(\.value)
        guard let host = host?.lowercased() else { return !domains.isEmpty } // spec 6.4: benefit of the doubt
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd Shared && swift test --filter AllowlistTests`
Expected: all 10 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add .gitignore Shared/Package.swift Shared/Sources/Core/Allowlist.swift Shared/Tests/CoreTests/TestSupport.swift Shared/Tests/CoreTests/AllowlistTests.swift
git commit -m "feat(core): add package and allowlist matching"
```

---

### Task 2: Session accounting

**Files:**
- Create: `Shared/Sources/Core/SessionAccounting.swift`
- Test: `Shared/Tests/CoreTests/SessionAccountingTests.swift`

**Interfaces:**
- Consumes: `date(_:)` test helper (Task 1).
- Produces:
  - `enum SessionEventType: String { case offtaskStart = "offtask_start", offtaskEnd = "offtask_end", breakStart = "break_start", breakEnd = "break_end", idleStart = "idle_start", idleEnd = "idle_end", sleep, wake }`
  - `struct SessionEvent { var type: SessionEventType; var at: Date; init(_ type: SessionEventType, at: Date) }`
  - `struct SessionTotals: Equatable { var focusedSec, offtaskSec, breakSec, idleSec, sleepSec: Int; var activeSec: Int { get } }`
  - `func sessionTotals(start: Date, end: Date, events: [SessionEvent]) -> SessionTotals`
  - `func isComplete(_ totals: SessionTotals, plannedMin: Int) -> Bool`

Rules (spec 6.3): each moment of the session goes into exactly one bucket. Priority when states overlap: **sleep > break > idle > off-task > focused**. `activeSec` = focused + off-task + idle (breaks and sleep don't use up planned length). Events outside `[start, end]` are ignored. A state left open runs to `end`.

- [ ] **Step 1: Write the failing tests**

`Shared/Tests/CoreTests/SessionAccountingTests.swift`:

```swift
import Testing
import Foundation
@testable import Core

@Suite struct SessionAccountingTests {
    let start = date("2026-11-24T16:00:00Z")
    func at(_ min: Double) -> Date { start.addingTimeInterval(min * 60) }

    @Test func noEventsIsAllFocused() {
        let t = sessionTotals(start: start, end: at(50), events: [])
        #expect(t == SessionTotals(focusedSec: 3000))
        #expect(t.activeSec == 3000)
    }

    @Test func offTaskStretch() {
        let t = sessionTotals(start: start, end: at(50), events: [
            SessionEvent(.offtaskStart, at: at(10)), SessionEvent(.offtaskEnd, at: at(15)),
        ])
        #expect(t == SessionTotals(focusedSec: 2700, offtaskSec: 300))
    }

    @Test func breakDoesNotUseUpPlannedLength() {
        let t = sessionTotals(start: start, end: at(60), events: [
            SessionEvent(.breakStart, at: at(20)), SessionEvent(.breakEnd, at: at(30)),
        ])
        #expect(t == SessionTotals(focusedSec: 3000, breakSec: 600))
        #expect(t.activeSec == 3000)
        #expect(isComplete(t, plannedMin: 50))
    }

    @Test func idleBeatsOffTask() {
        let t = sessionTotals(start: start, end: at(50), events: [
            SessionEvent(.offtaskStart, at: at(10)),
            SessionEvent(.idleStart, at: at(12)),
            SessionEvent(.idleEnd, at: at(15)),
            SessionEvent(.offtaskEnd, at: at(15)),
        ])
        #expect(t == SessionTotals(focusedSec: 2700, offtaskSec: 120, idleSec: 180))
    }

    @Test func sleepBeatsBreak() {
        let t = sessionTotals(start: start, end: at(60), events: [
            SessionEvent(.breakStart, at: at(10)),
            SessionEvent(.sleep, at: at(12)),
            SessionEvent(.wake, at: at(20)),
            SessionEvent(.breakEnd, at: at(22)),
        ])
        #expect(t == SessionTotals(focusedSec: 2880, breakSec: 240, sleepSec: 480))
    }

    @Test func openStateRunsToEnd() {
        let t = sessionTotals(start: start, end: at(50), events: [SessionEvent(.offtaskStart, at: at(45))])
        #expect(t == SessionTotals(focusedSec: 2700, offtaskSec: 300))
    }

    @Test func eventsOutsideWindowIgnoredAndOrderDoesNotMatter() {
        let t = sessionTotals(start: start, end: at(50), events: [
            SessionEvent(.offtaskEnd, at: at(15)),
            SessionEvent(.offtaskStart, at: at(10)),
            SessionEvent(.breakStart, at: at(70)),
        ])
        #expect(t == SessionTotals(focusedSec: 2700, offtaskSec: 300))
    }

    @Test func incompleteWhenActiveShort() {
        let t = sessionTotals(start: start, end: at(32), events: [])
        #expect(!isComplete(t, plannedMin: 50))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Shared && swift test --filter SessionAccountingTests`
Expected: build FAIL with "cannot find 'sessionTotals' in scope".

- [ ] **Step 3: Implement**

`Shared/Sources/Core/SessionAccounting.swift`:

```swift
import Foundation

public enum SessionEventType: String, Codable, Sendable {
    case offtaskStart = "offtask_start", offtaskEnd = "offtask_end"
    case breakStart = "break_start", breakEnd = "break_end"
    case idleStart = "idle_start", idleEnd = "idle_end"
    case sleep, wake
}

public struct SessionEvent: Hashable, Codable, Sendable {
    public var type: SessionEventType
    public var at: Date

    public init(_ type: SessionEventType, at: Date) {
        self.type = type
        self.at = at
    }
}

public struct SessionTotals: Equatable, Sendable {
    public var focusedSec: Int
    public var offtaskSec: Int
    public var breakSec: Int
    public var idleSec: Int
    public var sleepSec: Int

    /// Time that uses up the planned length: everything except breaks and sleep.
    public var activeSec: Int { focusedSec + offtaskSec + idleSec }

    public init(focusedSec: Int = 0, offtaskSec: Int = 0, breakSec: Int = 0, idleSec: Int = 0, sleepSec: Int = 0) {
        self.focusedSec = focusedSec
        self.offtaskSec = offtaskSec
        self.breakSec = breakSec
        self.idleSec = idleSec
        self.sleepSec = sleepSec
    }
}

/// Splits `[start, end]` into buckets. Overlap priority: sleep > break > idle > off-task > focused.
public func sessionTotals(start: Date, end: Date, events: [SessionEvent]) -> SessionTotals {
    var focused = 0.0, offtask = 0.0, onBreak = 0.0, idle = 0.0, asleep = 0.0
    var isOff = false, isBreak = false, isIdle = false, isAsleep = false
    var cursor = start

    func advance(to time: Date) {
        let d = time.timeIntervalSince(cursor)
        if isAsleep { asleep += d } else if isBreak { onBreak += d } else if isIdle { idle += d }
        else if isOff { offtask += d } else { focused += d }
        cursor = time
    }

    for e in events.filter({ $0.at >= start && $0.at <= end }).sorted(by: { $0.at < $1.at }) {
        advance(to: e.at)
        switch e.type {
        case .offtaskStart: isOff = true
        case .offtaskEnd: isOff = false
        case .breakStart: isBreak = true
        case .breakEnd: isBreak = false
        case .idleStart: isIdle = true
        case .idleEnd: isIdle = false
        case .sleep: isAsleep = true
        case .wake: isAsleep = false
        }
    }
    advance(to: end)

    return SessionTotals(focusedSec: Int(focused), offtaskSec: Int(offtask), breakSec: Int(onBreak),
                         idleSec: Int(idle), sleepSec: Int(asleep))
}

public func isComplete(_ totals: SessionTotals, plannedMin: Int) -> Bool {
    totals.activeSec >= plannedMin * 60
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Shared && swift test --filter SessionAccountingTests`
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/Sources/Core/SessionAccounting.swift Shared/Tests/CoreTests/SessionAccountingTests.swift
git commit -m "feat(core): add session time accounting"
```

---

### Task 3: Off-task tracker (grace-period state machine)

**Files:**
- Create: `Shared/Sources/Core/OffTaskTracker.swift`
- Test: `Shared/Tests/CoreTests/OffTaskTrackerTests.swift`

**Interfaces:**
- Consumes: `Allowlist`, `AllowEntry`, `Browsers` (Task 1); `date(_:)`.
- Produces:
  - `struct OffTaskTracker { init(allowlist: Allowlist, grace: TimeInterval = 15); var isOffTask: Bool { get }; var allowlist: Allowlist { get } }`
  - `enum OffTaskTracker.Output: Equatable { case started(at: Date, bundleID: String, host: String?); case ended(at: Date) }`
  - `mutating func observe(bundleID: String, host: String?, at: Date) -> [Output]`: call on every frontmost-app change and every browser-host poll.
  - `mutating func tick(at: Date) -> [Output]`: call every second while a session runs; this is what fires `started` once grace elapses.
  - `mutating func allow(_ entry: AllowEntry, at: Date) -> [Output]`: "It's work: allow for this session".
  - `mutating func setSuspended(_ suspended: Bool, at: Date) -> [Output]`: true during break, idle or sleep.

The Mac layer (plan 3) maps `.started` → `session_event offtask_start` + shows the nudge, `.ended` → `offtask_end` + hides it.

Rules (spec 6.4):
- Off-list → pending. Back on-list within 15 s → nothing logged.
- Grace elapsed → `.started(at: pendingSince + 15s)` with the culprit seen when drift began.
- Switching between off-list apps keeps the original pending time and culprit.
- On-list while off-task → `.ended(at: now)`.
- Suspend → ends any off-task stretch and drops pending. Resume → re-checks the current app, so grace starts again from the resume time.

- [ ] **Step 1: Write the failing tests**

`Shared/Tests/CoreTests/OffTaskTrackerTests.swift`:

```swift
import Testing
import Foundation
@testable import Core

@Suite struct OffTaskTrackerTests {
    let t0 = date("2026-11-24T16:00:00Z")
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    let figma = "com.figma.desktop"
    let spotify = "com.spotify.client"

    func tracker() -> OffTaskTracker {
        OffTaskTracker(allowlist: Allowlist(entries: [AllowEntry(.app, figma), AllowEntry(.domain, "figma.com")],
                                            ownBundleID: "dev.focus.mac"))
    }

    @Test func onTaskProducesNothing() {
        var t = tracker()
        #expect(t.observe(bundleID: figma, host: nil, at: at(0)).isEmpty)
        #expect(t.tick(at: at(60)).isEmpty)
        #expect(!t.isOffTask)
    }

    @Test func startsAfterGrace() {
        var t = tracker()
        _ = t.observe(bundleID: Browsers.safari, host: "youtube.com", at: at(0))
        #expect(t.tick(at: at(10)).isEmpty)
        #expect(t.tick(at: at(16)) == [.started(at: at(15), bundleID: Browsers.safari, host: "youtube.com")])
        #expect(t.isOffTask)
        #expect(t.tick(at: at(17)).isEmpty)
    }

    @Test func returningWithinGraceLogsNothing() {
        var t = tracker()
        _ = t.observe(bundleID: spotify, host: nil, at: at(0))
        #expect(t.observe(bundleID: figma, host: nil, at: at(10)).isEmpty)
        #expect(t.tick(at: at(30)).isEmpty)
    }

    @Test func returningAfterGraceEnds() {
        var t = tracker()
        _ = t.observe(bundleID: spotify, host: nil, at: at(0))
        _ = t.tick(at: at(15))
        #expect(t.observe(bundleID: figma, host: nil, at: at(40)) == [.ended(at: at(40))])
        #expect(!t.isOffTask)
    }

    @Test func hoppingBetweenOffListAppsKeepsOriginalStart() {
        var t = tracker()
        _ = t.observe(bundleID: spotify, host: nil, at: at(0))
        _ = t.observe(bundleID: Browsers.safari, host: "youtube.com", at: at(8))
        #expect(t.tick(at: at(15)) == [.started(at: at(15), bundleID: spotify, host: nil)])
    }

    @Test func allowEndsOffTask() {
        var t = tracker()
        _ = t.observe(bundleID: Browsers.safari, host: "youtube.com", at: at(0))
        _ = t.tick(at: at(15))
        #expect(t.allow(AllowEntry(.domain, "youtube.com"), at: at(30)) == [.ended(at: at(30))])
        #expect(t.allowlist.entries.contains(AllowEntry(.domain, "youtube.com")))
    }

    @Test func suspendEndsAndResumeRestartsGrace() {
        var t = tracker()
        _ = t.observe(bundleID: spotify, host: nil, at: at(0))
        _ = t.tick(at: at(15))
        #expect(t.setSuspended(true, at: at(20)) == [.ended(at: at(20))])
        #expect(t.tick(at: at(100)).isEmpty)
        #expect(t.setSuspended(false, at: at(200)).isEmpty)
        #expect(t.tick(at: at(210)).isEmpty)
        #expect(t.tick(at: at(215)) == [.started(at: at(215), bundleID: spotify, host: nil)])
    }

    @Test func observeWhileSuspendedIsRememberedForResume() {
        var t = tracker()
        _ = t.setSuspended(true, at: at(0))
        _ = t.observe(bundleID: figma, host: nil, at: at(5))
        _ = t.setSuspended(false, at: at(10))
        #expect(t.tick(at: at(60)).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Shared && swift test --filter OffTaskTrackerTests`
Expected: build FAIL with "cannot find 'OffTaskTracker' in scope".

- [ ] **Step 3: Implement**

`Shared/Sources/Core/OffTaskTracker.swift`:

```swift
import Foundation

/// Grace-period state machine for off-task detection (spec 6.4).
/// Pure: the caller supplies every observation and clock tick.
public struct OffTaskTracker: Sendable {
    public enum Output: Equatable, Sendable {
        case started(at: Date, bundleID: String, host: String?)
        case ended(at: Date)
    }

    struct Foreground: Sendable {
        var bundleID: String
        var host: String?
    }

    public private(set) var allowlist: Allowlist
    public private(set) var isOffTask = false
    let grace: TimeInterval
    var current: Foreground?
    var pending: (since: Date, culprit: Foreground)?
    var suspended = false

    public init(allowlist: Allowlist, grace: TimeInterval = 15) {
        self.allowlist = allowlist
        self.grace = grace
    }

    public mutating func observe(bundleID: String, host: String?, at now: Date) -> [Output] {
        current = Foreground(bundleID: bundleID, host: host)
        return evaluate(at: now)
    }

    public mutating func tick(at now: Date) -> [Output] {
        guard !suspended, !isOffTask, let p = pending, now.timeIntervalSince(p.since) >= grace else { return [] }
        pending = nil
        isOffTask = true
        return [.started(at: p.since.addingTimeInterval(grace), bundleID: p.culprit.bundleID, host: p.culprit.host)]
    }

    public mutating func allow(_ entry: AllowEntry, at now: Date) -> [Output] {
        allowlist.entries.insert(entry)
        return evaluate(at: now)
    }

    public mutating func setSuspended(_ value: Bool, at now: Date) -> [Output] {
        suspended = value
        guard value else { return evaluate(at: now) }
        pending = nil
        return endIfOffTask(at: now)
    }

    private mutating func evaluate(at now: Date) -> [Output] {
        guard !suspended, let c = current else { return [] }
        if allowlist.isOnTask(bundleID: c.bundleID, host: c.host) {
            pending = nil
            return endIfOffTask(at: now)
        }
        if !isOffTask && pending == nil { pending = (now, c) }
        return []
    }

    private mutating func endIfOffTask(at now: Date) -> [Output] {
        guard isOffTask else { return [] }
        isOffTask = false
        return [.ended(at: now)]
    }
}
```

Note: a tuple of `Sendable` members is `Sendable`, so `pending` keeps the struct `Sendable` under Swift 6. If the compiler disagrees on your toolchain, replace the tuple with a `struct Pending: Sendable { var since: Date; var culprit: Foreground }`. Behaviour is identical.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Shared && swift test --filter OffTaskTrackerTests`
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/Sources/Core/OffTaskTracker.swift Shared/Tests/CoreTests/OffTaskTrackerTests.swift
git commit -m "feat(core): add off-task grace state machine"
```

---

### Task 4: Day and week boundaries

**Files:**
- Create: `Shared/Sources/Core/Periods.swift`
- Test: `Shared/Tests/CoreTests/PeriodsTests.swift`

**Interfaces:**
- Consumes: `date(_:)`.
- Produces:
  - `struct PeriodCalendar { init(timeZone: TimeZone); func dayInterval(containing: Date) -> DateInterval; func weekInterval(containing: Date) -> DateInterval; func isoWeekday(of: Date) -> Int; func elapsedFraction(of: DateInterval, at: Date) -> Double }`
  - `isoWeekday`: 1 = Monday … 7 = Sunday (matches `project.daily_goal_days` in the DB).

- [ ] **Step 1: Write the failing tests**

`Shared/Tests/CoreTests/PeriodsTests.swift`:

```swift
import Testing
import Foundation
@testable import Core

@Suite struct PeriodsTests {
    let london = PeriodCalendar(timeZone: TimeZone(identifier: "Europe/London")!)
    let sydney = PeriodCalendar(timeZone: TimeZone(identifier: "Australia/Sydney")!)

    @Test func weekStartsMonday() {
        let w = london.weekInterval(containing: date("2026-11-24T16:52:00Z")) // Tue
        #expect(w.start == date("2026-11-23T00:00:00Z"))
        #expect(w.end == date("2026-11-30T00:00:00Z"))
    }

    @Test func lateSundayIsSameWeek() {
        let w = london.weekInterval(containing: date("2026-11-29T23:30:00Z"))
        #expect(w.start == date("2026-11-23T00:00:00Z"))
    }

    @Test func dayUsesOwnerTimezone() {
        // 23:30 UTC Monday is already Tuesday 10:30 in Sydney (UTC+11 in November).
        let d = sydney.dayInterval(containing: date("2026-11-23T23:30:00Z"))
        #expect(d.start == date("2026-11-24T00:00:00+11:00"))
        #expect(sydney.isoWeekday(of: date("2026-11-23T23:30:00Z")) == 2)
    }

    @Test func dstSpringForwardDayIs23Hours() {
        // UK clocks go forward Sunday 29 March 2026.
        #expect(london.dayInterval(containing: date("2026-03-29T12:00:00Z")).duration == 23 * 3600)
        #expect(london.weekInterval(containing: date("2026-03-29T12:00:00Z")).duration == 167 * 3600)
    }

    @Test func isoWeekdays() {
        #expect(london.isoWeekday(of: date("2026-11-23T12:00:00Z")) == 1) // Mon
        #expect(london.isoWeekday(of: date("2026-11-28T12:00:00Z")) == 6) // Sat
        #expect(london.isoWeekday(of: date("2026-11-29T12:00:00Z")) == 7) // Sun
    }

    @Test func elapsedFractionIsClamped() {
        let w = london.weekInterval(containing: date("2026-11-24T00:00:00Z"))
        #expect(london.elapsedFraction(of: w, at: date("2026-11-26T12:00:00Z")) == 0.5)
        #expect(london.elapsedFraction(of: w, at: date("2026-11-01T00:00:00Z")) == 0)
        #expect(london.elapsedFraction(of: w, at: date("2026-12-25T00:00:00Z")) == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Shared && swift test --filter PeriodsTests`
Expected: build FAIL with "cannot find 'PeriodCalendar' in scope".

- [ ] **Step 3: Implement**

`Shared/Sources/Core/Periods.swift`:

```swift
import Foundation

/// Day and week boundaries in the owner's timezone. Weeks start Monday (ISO 8601).
public struct PeriodCalendar: Sendable {
    let calendar: Calendar

    public init(timeZone: TimeZone) {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = timeZone
        calendar = c
    }

    public func dayInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)!
    }

    public func weekInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    /// 1 = Monday … 7 = Sunday.
    public func isoWeekday(of date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    public func elapsedFraction(of interval: DateInterval, at now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(interval.start) / interval.duration))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Shared && swift test --filter PeriodsTests`
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/Sources/Core/Periods.swift Shared/Tests/CoreTests/PeriodsTests.swift
git commit -m "feat(core): add day/week period boundaries"
```

---

### Task 5: Goal status

**Files:**
- Create: `Shared/Sources/Core/Goals.swift`
- Test: `Shared/Tests/CoreTests/GoalsTests.swift`

**Interfaces:**
- Consumes: `PeriodCalendar` (Task 4); `date(_:)`.
- Produces:
  - `enum GoalStatus: String { case onTrack = "on_track", behind, met, missed }`
  - `func goalStatus(target: Double, actual: Double, elapsedFraction: Double, closed: Bool) -> GoalStatus`
  - `func hasDailyGoal(on date: Date, days: Set<Int>, calendar: PeriodCalendar) -> Bool`

Rules (spec 6.2, 6.10):
- Met as soon as actual ≥ target, even mid-period.
- Closed and not met → missed.
- Open: on track if actual ≥ target × elapsed fraction, else behind.
- Hours goals pass `actual` in hours (`focusedSec / 3600`); task goals pass a count.

- [ ] **Step 1: Write the failing tests**

`Shared/Tests/CoreTests/GoalsTests.swift`:

```swift
import Testing
import Foundation
@testable import Core

@Suite struct GoalsTests {
    @Test func metBeforePeriodEnds() {
        #expect(goalStatus(target: 12, actual: 12.4, elapsedFraction: 0.6, closed: false) == .met)
    }

    @Test func missedWhenClosedShort() {
        #expect(goalStatus(target: 4, actual: 2.5, elapsedFraction: 1, closed: true) == .missed)
    }

    @Test func onTrackVersusBehindByPace() {
        #expect(goalStatus(target: 12, actual: 6, elapsedFraction: 0.5, closed: false) == .onTrack)
        #expect(goalStatus(target: 12, actual: 5.9, elapsedFraction: 0.5, closed: false) == .behind)
        #expect(goalStatus(target: 12, actual: 0, elapsedFraction: 0, closed: false) == .onTrack)
    }

    @Test func dailyGoalDays() {
        let cal = PeriodCalendar(timeZone: TimeZone(identifier: "Europe/London")!)
        let weekdays: Set<Int> = [1, 2, 3, 4, 5]
        #expect(hasDailyGoal(on: date("2026-11-24T12:00:00Z"), days: weekdays, calendar: cal))  // Tue
        #expect(!hasDailyGoal(on: date("2026-11-28T12:00:00Z"), days: weekdays, calendar: cal)) // Sat
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Shared && swift test --filter GoalsTests`
Expected: build FAIL with "cannot find 'goalStatus' in scope".

- [ ] **Step 3: Implement**

`Shared/Sources/Core/Goals.swift`:

```swift
import Foundation

public enum GoalStatus: String, Codable, Sendable {
    case onTrack = "on_track", behind, met, missed
}

public func goalStatus(target: Double, actual: Double, elapsedFraction: Double, closed: Bool) -> GoalStatus {
    if actual >= target { return .met }
    if closed { return .missed }
    return actual >= target * elapsedFraction ? .onTrack : .behind
}

/// `days` uses ISO weekdays: 1 = Monday … 7 = Sunday.
public func hasDailyGoal(on date: Date, days: Set<Int>, calendar: PeriodCalendar) -> Bool {
    days.contains(calendar.isoWeekday(of: date))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Shared && swift test --filter GoalsTests`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/Sources/Core/Goals.swift Shared/Tests/CoreTests/GoalsTests.swift
git commit -m "feat(core): add goal status rules"
```

---

### Task 6: Points

**Files:**
- Create: `Shared/Sources/Core/Points.swift`
- Test: `Shared/Tests/CoreTests/PointsTests.swift`

**Interfaces:**
- Consumes: `SessionTotals` (Task 2).
- Produces:
  - `enum PointRules { static let perFocusedMinute, sessionComplete, dailyGoalMet, weeklyGoalMet, perOfftaskMinute, perOverBreakMinute: Int }`
  - `enum PointKind: String { case focus, sessionComplete = "session_complete", dailyGoal = "daily_goal", weeklyGoal = "weekly_goal", offtask, breakOver = "break_over", redeem }`
  - `struct PointLine: Equatable { var kind: PointKind; var delta: Int }`
  - `func breakOverAllowance(usedEarlierSec: Int, sessionBreakSec: Int, allowanceSec: Int) -> Int`
  - `func sessionPoints(totals: SessionTotals, completed: Bool, breakOverSec: Int) -> [PointLine]`: lines in order focus, sessionComplete, offtask, breakOver; zero lines omitted.
  - `func canRedeem(cost: Int, balance: Int) -> Bool`

Goal points (`dailyGoal`, `weeklyGoal`) are written by the period-close job in plan 2. Only the constants live here, so values stay in one place for the Swift side.

- [ ] **Step 1: Write the failing tests**

`Shared/Tests/CoreTests/PointsTests.swift`:

```swift
import Testing
@testable import Core

@Suite struct PointsTests {
    @Test func earlyEndKeepsFocusMinutesOnly() {
        let lines = sessionPoints(totals: SessionTotals(focusedSec: 32 * 60 + 14), completed: false, breakOverSec: 0)
        #expect(lines == [PointLine(kind: .focus, delta: 32)])
    }

    @Test func completedSessionGetsBonus() {
        let lines = sessionPoints(totals: SessionTotals(focusedSec: 3000), completed: true, breakOverSec: 0)
        #expect(lines == [PointLine(kind: .focus, delta: 50), PointLine(kind: .sessionComplete, delta: 10)])
    }

    @Test func offTaskAndOverBreakCost() {
        let lines = sessionPoints(totals: SessionTotals(focusedSec: 2820, offtaskSec: 3 * 60 + 59),
                                  completed: true, breakOverSec: 12 * 60)
        #expect(lines == [
            PointLine(kind: .focus, delta: 47),
            PointLine(kind: .sessionComplete, delta: 10),
            PointLine(kind: .offtask, delta: -6),
            PointLine(kind: .breakOver, delta: -12),
        ])
    }

    @Test func breakAllowance() {
        let hour = 3600
        #expect(breakOverAllowance(usedEarlierSec: 0, sessionBreakSec: 22 * 60, allowanceSec: hour) == 0)
        #expect(breakOverAllowance(usedEarlierSec: 50 * 60, sessionBreakSec: 22 * 60, allowanceSec: hour) == 12 * 60)
        #expect(breakOverAllowance(usedEarlierSec: 70 * 60, sessionBreakSec: 22 * 60, allowanceSec: hour) == 22 * 60)
    }

    @Test func redeemGuard() {
        #expect(canRedeem(cost: 150, balance: 1240))
        #expect(!canRedeem(cost: 2000, balance: 1240))
        #expect(!canRedeem(cost: 150, balance: -20))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Shared && swift test --filter PointsTests`
Expected: build FAIL with "cannot find 'sessionPoints' in scope".

- [ ] **Step 3: Implement**

`Shared/Sources/Core/Points.swift`:

```swift
import Foundation

/// Point values (spec 6.7). Tune here; plan 2's SQL period-close job mirrors the goal values.
public enum PointRules {
    public static let perFocusedMinute = 1
    public static let sessionComplete = 10
    public static let dailyGoalMet = 20
    public static let weeklyGoalMet = 100
    public static let perOfftaskMinute = -2
    public static let perOverBreakMinute = -1
}

public enum PointKind: String, Codable, Sendable {
    case focus, offtask, redeem
    case sessionComplete = "session_complete"
    case dailyGoal = "daily_goal"
    case weeklyGoal = "weekly_goal"
    case breakOver = "break_over"
}

public struct PointLine: Equatable, Sendable {
    public var kind: PointKind
    public var delta: Int

    public init(kind: PointKind, delta: Int) {
        self.kind = kind
        self.delta = delta
    }
}

/// Seconds of this session's break that fall beyond today's allowance.
public func breakOverAllowance(usedEarlierSec: Int, sessionBreakSec: Int, allowanceSec: Int) -> Int {
    max(0, sessionBreakSec - max(0, allowanceSec - usedEarlierSec))
}

/// Ledger lines written when a session ends. Partial minutes round down; zero lines are omitted.
public func sessionPoints(totals: SessionTotals, completed: Bool, breakOverSec: Int) -> [PointLine] {
    let candidates: [PointLine] = [
        PointLine(kind: .focus, delta: totals.focusedSec / 60 * PointRules.perFocusedMinute),
        PointLine(kind: .sessionComplete, delta: completed ? PointRules.sessionComplete : 0),
        PointLine(kind: .offtask, delta: totals.offtaskSec / 60 * PointRules.perOfftaskMinute),
        PointLine(kind: .breakOver, delta: breakOverSec / 60 * PointRules.perOverBreakMinute),
    ]
    return candidates.filter { $0.delta != 0 }
}

public func canRedeem(cost: Int, balance: Int) -> Bool {
    cost <= balance
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Shared && swift test --filter PointsTests`
Expected: all 5 tests PASS.

- [ ] **Step 5: Run the whole suite**

Run: `cd Shared && swift test`
Expected: 41 tests, all PASS, no warnings about Sendable.

- [ ] **Step 6: Commit**

```bash
git add Shared/Sources/Core/Points.swift Shared/Tests/CoreTests/PointsTests.swift
git commit -m "feat(core): add points rules and session ledger lines"
```

---

## Done when

- `cd Shared && swift test` passes all 41 tests on Swift 6 with no concurrency warnings.
- Branch `core-package` has 6 commits, one per task.
- Nothing outside `Shared/` and `.gitignore` changed.
