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
    var hotkeyUnavailable = false

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
        var closed = false
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
                closed = true
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
        // Once per apply, after the new stretch (if any) is open: a switch syncs both rows in one push.
        if closed { onSessionClosed?() }
        // A midnight split can stop an off-Mac stretch without going through stop().
        if !isTracking && timer != nil { stopMonitoring() }
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
        guard timer == nil else { return }
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

    /// Test hook: the 1 s timer's body, at a chosen time.
    func tick(at when: Date) {
        now = when
        run(checkpoint: false) { $0.tick(at: when) }
    }

    /// Test hook: whether the 1 s timer and activity monitor are live.
    var isMonitoring: Bool { timer != nil && monitor != nil }

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
