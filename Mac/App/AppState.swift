import AppKit
import SwiftData
import Core
import os

struct Nudge: Equatable { var bundleID: String; var host: String?; var startedAt: Date }

struct TodayStats: Equatable { var focusedSec: Int; var breakLeftSec: Int; var points: Int }

func remainingText(_ sec: Int) -> String {
    let s = max(0, sec)
    return String(format: "%d:%02d", s / 60, s % 60)
}

@MainActor @Observable
final class AppState {
    private static let log = Logger(subsystem: "dev.stint.mac", category: "app")

    var now = Date()
    var engine: SessionEngine?
    var record: SessionRecord?
    var project: Project?
    var firstTask: TaskItem?
    var nudge: Nudge?
    var automationDenied = false
    var lastResult: (points: Int, completed: Bool)?

    @ObservationIgnored private let ctx: ModelContext
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var monitor: ActivityMonitor?
    @ObservationIgnored private var ticks = 0

    init(context: ModelContext) {
        ctx = context
        do { try Ledger.recoverOrphans(ctx, now: .now) } catch { Self.log.error("recoverOrphans: \(error)") }
    }

    var isRunning: Bool { engine != nil }
    var remainingText: String { engine.map { Stint.remainingText($0.remainingSec(at: now)) } ?? "" }

    private var allowanceSec: Int {
        (UserDefaults.standard.object(forKey: "breakAllowanceMin") as? Int ?? 60) * 60
    }

    private var today: DateInterval { PeriodCalendar(timeZone: .current).dayInterval(containing: engine?.startedAt ?? now) }

    func todayStats() -> TodayStats {
        let day = PeriodCalendar(timeZone: .current).dayInterval(containing: now)
        let sessions = Ledger.summaries(ctx, since: day.start)
        var focused = sessions.filter { $0.startedAt < day.end }.reduce(0) { $0 + $1.focusedSec }
        var breakUsed = Core.breakSec(sessions, in: day)
        let events = (try? ctx.fetch(FetchDescriptor<PointEvent>(predicate: #Predicate { $0.at >= day.start }))) ?? []
        var points = events.reduce(0) { $0 + $1.delta }
        if let e = engine {
            let t = e.totals(at: now)
            focused += t.focusedSec; breakUsed += t.breakSec
            points += sessionPoints(totals: t, completed: false, breakOverSec: 0).reduce(0) { $0 + $1.delta }
        }
        return TodayStats(focusedSec: focused, breakLeftSec: max(0, allowanceSec - breakUsed), points: points)
    }

    func start(project: Project, plannedMin: Int, firstTask: TaskItem?) {
        guard engine == nil else { return }
        let started = Date()
        let allowlist = Allowlist(entries: project.allowEntries, ownBundleID: Bundle.main.bundleIdentifier ?? "dev.stint.mac")
        let e = SessionEngine(plannedMin: plannedMin, startedAt: started, allowlist: allowlist)
        do {
            record = try Ledger.openSession(ctx, project: project, plannedMin: plannedMin, firstTask: firstTask,
                                            startedAt: started, allow: project.allowEntries)
        } catch {
            Self.log.error("openSession: \(error)")
            return
        }
        self.project = project; self.firstTask = firstTask
        engine = e; now = started; nudge = nil; lastResult = nil; automationDenied = false; ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let m = ActivityMonitor(
            onFront: { [weak self] id, host in self?.run { $0.observe(bundleID: id, host: host, at: .now) } },
            onIdle: { [weak self] v in self?.run { $0.setIdle(v, at: .now) } },
            onSleep: { [weak self] v in self?.run { $0.setAsleep(v, at: .now) } },
            onAutomationDenied: { [weak self] in self?.automationDenied = true })
        monitor = m
        m.start()
        m.reportCurrent()
        Notifier.requestAuthorization()
    }

    func takeBreak() { run { $0.setBreak(true, at: .now) }; checkBreakAllowance() }
    func resume() { run { $0.setBreak(false, at: .now) } }

    func endEarly(reason: String) {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        finish(early: true, reason: r)
    }

    func allowCurrent(reason: String) {
        guard var e = engine, let (_, signals) = e.allowCurrent(at: .now) else { return }
        engine = e
        record?.allowReasons.append(reason)
        handle(signals)
        checkpoint()
    }

    func backToTask() {
        guard let id = engine?.lastOnTaskBundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    }

    private func run(_ f: (inout SessionEngine) -> [SessionEngine.Signal]) {
        guard var e = engine else { return }
        let signals = f(&e)
        engine = e
        handle(signals)
        checkpoint()
    }

    private func tick() {
        now = Date()
        run { $0.tick(at: .now) }
        ticks += 1
        if ticks % 15 == 0 { checkpoint() }
        checkBreakAllowance()
    }

    private func handle(_ signals: [SessionEngine.Signal]) {
        for s in signals {
            switch s {
            case let .offTaskStarted(bundleID, host): nudge = Nudge(bundleID: bundleID, host: host, startedAt: Date())
            case .offTaskEnded: nudge = nil
            case .reachedPlannedLength: finish(early: false, reason: nil)
            }
        }
    }

    private func checkpoint() {
        guard let e = engine, let r = record else { return }
        do { try Ledger.checkpoint(ctx, record: r, events: e.events, allow: e.allowlist.entries.sorted { $0.value < $1.value }, at: Date()) }
        catch { Self.log.error("checkpoint: \(error)") }
    }

    private func checkBreakAllowance() {
        guard let e = engine, e.onBreak else { return }
        let used = Ledger.breakUsedSec(ctx, in: today) + e.totals(at: now).breakSec
        let key = String(Int(today.start.timeIntervalSince1970))
        guard used >= allowanceSec, UserDefaults.standard.string(forKey: "breakWarnedDay") != key else { return }
        UserDefaults.standard.set(key, forKey: "breakWarnedDay")
        Notifier.post(title: "Break allowance used up", body: "Each extra minute costs 1 point")
    }

    private func finish(early: Bool, reason: String?) {
        guard var e = engine, let r = record else { return }
        let end = Date()
        let used = Ledger.breakUsedSec(ctx, in: today)
        let result = e.finish(at: end, early: early, breakUsedEarlierTodaySec: used, allowanceSec: allowanceSec)
        do { try Ledger.close(ctx, record: r, result: result, endedAt: end, earlyReason: reason) }
        catch { Self.log.error("close: \(error)") }
        timer?.invalidate(); timer = nil
        monitor?.stop(); monitor = nil
        let total = result.points.reduce(0) { $0 + $1.delta }
        lastResult = (total, result.completed)
        engine = nil; record = nil; project = nil; firstTask = nil; nudge = nil
        if result.completed {
            Notifier.post(title: "Session complete", body: "+\(total) points")
        }
    }
}
