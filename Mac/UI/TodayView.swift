import StintData
import SwiftUI
import SwiftData
import Core

struct TodayView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var ctx
    @Environment(SyncCoordinator.self) private var sync
    @State private var dictating = false
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @Query private var sessions: [SessionRecord]   // observed so numbers refresh when a session closes
    @Query private var events: [PointEvent]

    private let cal = PeriodCalendar(timeZone: .current)

    var body: some View {
        let now = app.now
        let day = cal.dayInterval(containing: now)
        let week = cal.weekInterval(containing: now)
        let stats = app.todayStats()
        let allowance = (UserDefaults.standard.object(forKey: "breakAllowanceMin") as? Int ?? 60) * 60
        let offtask = sessions.filter { $0.endedAt != nil && $0.startedAt >= day.start && $0.startedAt < day.end }
            .reduce(0) { $0 + $1.offtaskSec } + (app.tracker.engine?.totals(at: now).offtaskSec ?? 0)
        let summaries = Ledger.summaries(ctx, since: week.start)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(now, format: .dateTime.weekday(.wide).month(.wide).day()).font(.largeTitle.bold())
                    HStack(spacing: 28) {
                        stat("Focused today", "\(stats.focusedSec / 60)m")
                        stat("Off-task today", "\(offtask / 60)m")
                        stat("Break used", "\((allowance - stats.breakLeftSec) / 60) / \(allowance / 60)m")
                        stat("Points today", "\(stats.points)")
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("This week").font(.title3.bold())
                        Spacer()
                        Button("Dictate tasks", systemImage: "mic") { dictating = true }
                    }
                    if projects.isEmpty { Text("Add a project in Projects to set goals.").foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(projects) { card($0, now: now, day: day, week: week, summaries: summaries) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Today's tasks").font(.title3.bold())
                    ForEach(projects) { TaskGroup(project: $0, dayStart: day.start) }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $dictating) {
            DictateView(parse: { try await sync.parseTasks($0, projects: $1) }) { _ in
                dictating = false; sync.syncSoon()
            }
            .frame(minWidth: 560, minHeight: 520)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dictating = false } } }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func liveFocusedHours(_ p: Project, _ summaries: [SessionSummary], in interval: DateInterval) -> Double {
        var sec = focusedSec(summaries, projectID: p.id, in: interval)
        if let e = app.tracker.engine, app.project?.id == p.id, e.startedAt >= interval.start, e.startedAt < interval.end {
            sec += e.totals(at: app.now).focusedSec
        }
        return Double(sec) / 3600
    }

    private func card(_ p: Project, now: Date, day: DateInterval, week: DateInterval, summaries: [SessionSummary]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(Color(hex: p.colorHex)).frame(width: 9, height: 9)
                    Text(p.name).font(.headline)
                }
                if let g = p.weeklyHoursGoal {
                    bar("This week", actual: liveFocusedHours(p, summaries, in: week), target: g, elapsed: cal.elapsedFraction(of: week, at: now))
                }
                if let g = p.dailyHoursGoal, hasDailyGoal(on: now, days: Set(p.dailyGoalDays), calendar: cal) {
                    bar("Today", actual: liveFocusedHours(p, summaries, in: day), target: g, elapsed: cal.elapsedFraction(of: day, at: now))
                }
                if let g = p.tasksGoal {
                    let interval = p.tasksGoalPeriod == "day" ? day : week
                    let done = tasksDone(p.tasks.map(\.doneAt), in: interval)
                    Text("Tasks \(done) / \(g) this \(p.tasksGoalPeriod)").font(.callout.monospacedDigit())
                }
                if p.weeklyHoursGoal == nil && p.dailyHoursGoal == nil && p.tasksGoal == nil {
                    Text("No goals set").foregroundStyle(.secondary).font(.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func bar(_ title: String, actual: Double, target: Double, elapsed: Double) -> some View {
        let status = goalStatus(target: target, actual: actual, elapsedFraction: elapsed, closed: false)
        let label = switch status { case .met: "Met"; case .onTrack: "On track"; default: "Behind" }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(label).font(.caption.bold()).foregroundStyle(status == .behind ? Theme.warn : Theme.accent)
            }
            ProgressView(value: min(actual, target), total: target)
            Text(String(format: "%.1f / %g h", actual, target)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct TaskGroup: View {
    @Environment(\.modelContext) private var ctx
    let project: Project
    let dayStart: Date
    @State private var newTitle = ""

    private var tasks: [TaskItem] {
        project.tasks.filter { $0.doneAt == nil || $0.doneAt! >= dayStart }.sorted { $0.sort < $1.sort }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(Color(hex: project.colorHex)).frame(width: 9, height: 9)
                Text(project.name).font(.headline)
            }
            ForEach(tasks) { t in
                Toggle(isOn: Binding(get: { t.doneAt != nil }, set: { on in
                    t.doneAt = on ? .now : nil; t.updatedAt = .now; ctx.saveLogged()
                })) {
                    Text(t.title).strikethrough(t.doneAt != nil).foregroundStyle(t.doneAt != nil ? .secondary : .primary)
                }
            }
            TextField("Add task", text: $newTitle).textFieldStyle(.roundedBorder).frame(maxWidth: 320).onSubmit(add)
        }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let item = TaskItem(title: title, sort: (project.tasks.map(\.sort).max() ?? -1) + 1)
        ctx.insert(item)
        item.project = project
        ctx.saveLogged()
        newTitle = ""
    }
}
