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

/// Menu bar panel (spec 2026-11-27 §6): now bar, the card column, quick add.
struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Query private var tasks: [TaskItem]
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @State private var showDone = false

    var body: some View {
        let stats = app.todayStats()
        let board = Board.make(tasks: tasks, trackedProjectID: app.tracker.currentID, now: app.now, calendar: PeriodCalendar(timeZone: .current))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month())).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Today \(hoursMinutes(stats.focusedSec)) · \(stats.points >= 0 ? "+" : "")\(stats.points) pts")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MacNowBar(current: board.current, breakLeftSec: stats.breakLeftSec)
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
            cards(board).frame(height: listHeight(board))
            MacQuickAdd(projects: projects, defaultProjectID: board.current?.project?.id ?? app.tracker.currentID)
            Divider()
            HStack {
                Text(app.hotkeyUnavailable ? "Hotkey unavailable" : "Switch anywhere: ⌃⌥Space").foregroundStyle(.secondary)
                Spacer()
                Button("Open Stint") { NSApp.activate(); openWindow(id: "main") }.buttonStyle(.link)
                Button("Quit") { app.stop(); NSApplication.shared.terminate(nil) }.buttonStyle(.link)
            }.font(.caption)
        }
        .padding(14).frame(width: 360)
        .onAppear { app.now = Date() }
    }

    private func cards(_ board: Board) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if board.active.isEmpty && board.pending.isEmpty && board.doneToday.isEmpty {
                    Text(projects.isEmpty ? "Add a project in Stint, then add a card below." : "Add a card below. Click a card to work on it.")
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                }
                group("ACTIVE", board.active) { MacCardRow(task: $0, isCurrent: $0.id == board.current?.id, projects: projects) }
                group("PENDING", board.pending) { MacCardRow(task: $0, isCurrent: false, projects: projects) }
                if !board.doneToday.isEmpty {
                    Button { showDone.toggle() } label: {
                        HStack(spacing: 4) {
                            Text("COMPLETED TODAY · \(board.doneToday.count)")
                            Image(systemName: "chevron.right").rotationEffect(.degrees(showDone ? 90 : 0))
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                    }
                    .buttonStyle(.plain)
                    if showDone { ForEach(board.doneToday) { MacCardRow(task: $0, isCurrent: false, projects: projects) } }
                }
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [TaskItem], row: @escaping (TaskItem) -> MacCardRow) -> some View {
        if !items.isEmpty {
            Text("\(title) · \(items.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            ForEach(items) { row($0) }
        }
    }

    /// The panel sizes to its content; a ScrollView has no ideal height, so estimate it and cap it.
    private func listHeight(_ b: Board) -> CGFloat {
        let rows = b.active.count + b.pending.count + (showDone ? b.doneToday.count : 0)
        let headers = [b.active, b.pending, b.doneToday].filter { !$0.isEmpty }.count
        return min(420, max(36, CGFloat(rows) * 50 + CGFloat(headers) * 26))
    }
}

private struct MacNowBar: View {
    @Environment(AppState.self) private var app
    let current: TaskItem?
    let breakLeftSec: Int

    var body: some View {
        HStack(spacing: 10) {
            if let p = app.project {
                ProjectIcon(name: p.name, colorHex: p.colorHex, icon: p.icon, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(app.tracker.onBreak ? "On break · \(breakLeftSec / 60)m left" : app.tracker.isOffTask ? "Off task" : current?.title ?? "Focused")
                        .font(.caption).foregroundStyle(app.tracker.isOffTask ? Theme.warn : .secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(remainingText(app.tracker.engine?.totals(at: app.now).focusedSec ?? 0)).font(.title3.weight(.semibold).monospacedDigit())
                Button { app.tracker.onBreak ? app.resume() : app.takeBreak() } label: {
                    Image(systemName: app.tracker.onBreak ? "play.fill" : "cup.and.saucer")
                }
                .help(app.tracker.onBreak ? "Resume" : "Take a break (\(breakLeftSec / 60) min left today)")
                Button { app.stop() } label: { Image(systemName: "stop.fill") }.help("Stop tracking")
            } else {
                Image(systemName: "timer").font(.title3).frame(width: 34, height: 34)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Not tracking").font(.callout.weight(.semibold))
                    Text("Click a card to start").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle)
        .padding(8).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One card. Click = current (and switch). Hover shows ✓; right-click for the rest.
private struct MacCardRow: View {
    @Environment(AppState.self) private var app
    let task: TaskItem
    let isCurrent: Bool
    let projects: [Project]
    @State private var hover = false
    @State private var editing = false
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        let color = Color(hex: task.project?.colorHex ?? "#8E8E93")
        let done = task.state == .done
        HStack(spacing: 6) {
            Button { app.tap(task) } label: {
                HStack(spacing: 10) {
                    if done {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(color.opacity(task.state == .pending ? 0.45 : 1)).frame(width: 4)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if editing {
                            TextField("Title", text: $title).textFieldStyle(.plain).focused($focused)
                                .onSubmit { Board.retitle(task, title, now: .now); app.tasksChanged(); editing = false }
                                .onExitCommand { editing = false }
                        } else {
                            Text(task.title).font(.callout).strikethrough(done).foregroundStyle(done ? .secondary : .primary).lineLimit(2)
                        }
                        if !done {
                            HStack(spacing: 6) {
                                ProjectChip(project: task.project, size: 14)
                                if isCurrent { Text("Now").font(.caption.weight(.semibold)) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hover && !done && !editing {
                Button { Board.complete(task, now: .now); app.tasksChanged() } label: { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.plain).help("Complete").accessibilityLabel("Complete")
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(isCurrent ? color.opacity(0.12) : hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isCurrent ? color : .clear, lineWidth: 1.5))
        .onHover { hover = $0 }
        .contextMenu {
            if !done { Button("Complete") { Board.complete(task, now: .now); app.tasksChanged() } }
            if task.state == .active { Button("Back to Pending") { Board.toPending(task, now: .now); app.tasksChanged() } }
            Button("Edit title") { title = task.title; editing = true; focused = true }
            Menu("Change project") {
                ForEach(projects) { p in
                    Button(p.name) { Board.move(task, to: p, now: .now); app.tasksChanged() }.disabled(p.id == task.project?.id)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { Board.delete(task, now: .now); app.tasksChanged() }
        }
        .accessibilityLabel("\(task.title), \(task.project?.name ?? "")\(isCurrent ? ", current" : "")")
    }
}

/// Project menu + field. Return adds the card to the top of Pending.
private struct MacQuickAdd: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var ctx
    let projects: [Project]
    let defaultProjectID: UUID?
    @State private var title = ""
    @State private var chosen: UUID?

    private var project: Project? {
        projects.first { $0.id == chosen } ?? projects.first { $0.id == defaultProjectID } ?? projects.first
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(projects) { p in Button(p.name) { chosen = p.id } }
            } label: {
                Text(project?.menuTitle ?? "Project")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(projects.isEmpty)
            TextField("Add a task", text: $title).textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard let p = project, Board.add(title: title, project: p, in: ctx, now: .now) != nil else { return }
                    title = ""; chosen = nil
                    app.tasksChanged()
                }
        }
    }
}
