import SwiftUI
import SwiftData
import Core
import StintData

/// The one main screen (spec 2026-11-27 §5): a column of task cards, grouped Active / Pending / Completed today.
struct BoardView: View {
    @Binding var desk: Bool
    @Environment(PhoneSync.self) private var sync
    @Environment(\.modelContext) private var ctx
    @Query private var tasks: [TaskItem]
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @State private var sheet: BoardSheet?
    @State private var showDone = false
    @State private var editing: TaskItem?
    @State private var editTitle = ""
    @State private var created: Project?

    var body: some View {
        // Re-read each minute so completed cards drop off at midnight.
        TimelineView(.everyMinute) { tl in content(sync.board(tasks, now: tl.date)) }
    }

    private func content(_ board: Board) -> some View {
        let tracked = projects.first { $0.id == sync.running?.projectID }
        return NavigationStack {
            List {
                Section {
                    NowBar(running: sync.running, project: tracked, current: board.current)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } header: {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).textCase(.uppercase)
                }
                if board.active.isEmpty && board.pending.isEmpty && board.doneToday.isEmpty {
                    Text(projects.isEmpty ? "Add a project in Settings, then add your first card below."
                                          : "Add a card below. Tap a card to start working on it.")
                        .foregroundStyle(.secondary).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if !board.active.isEmpty {
                    Section("Active · \(board.active.count)") {
                        ForEach(board.active) { card($0, current: $0.id == board.current?.id) }
                            .onMove { Board.reorder(board.active, from: $0, to: $1, now: .now); sync.boardChanged() }
                    }
                }
                if !board.pending.isEmpty {
                    Section("Pending · \(board.pending.count)") {
                        ForEach(board.pending) { card($0, current: false) }
                            .onMove { Board.reorder(board.pending, from: $0, to: $1, now: .now); sync.boardChanged() }
                    }
                }
                if !board.doneToday.isEmpty {
                    Section {
                        if showDone { ForEach(board.doneToday) { card($0, current: false) } }
                    } header: {
                        Button { withAnimation { showDone.toggle() } } label: {
                            HStack(spacing: 4) {
                                Text("Completed today · \(board.doneToday.count)")
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(showDone ? 90 : 0))
                            }
                        }
                        .buttonStyle(.plain).accessibilityHint(showDone ? "Hides completed cards" : "Shows completed cards")
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Progress", systemImage: "chart.bar") { sheet = .progress }
                    Button("Settings", systemImage: "gearshape") { sheet = .settings }
                }
            }
            .refreshable { await sync.refresh() }
            .safeAreaInset(edge: .bottom) {
                QuickAddBar(projects: projects, defaultProjectID: board.current?.project?.id ?? sync.running?.projectID,
                            newProject: { created = Project.makeNew(in: ctx); ctx.saveLogged(); sheet = .newProject }, dictate: { sheet = .dictate })
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .progress: ProgressSheet()
                case .settings: SettingsSheet(openDesk: { desk = true })
                case .newProject: if let created { NavigationStack { ProjectEditorView(project: created, isNew: true) } }
                case .dictate:
                    NavigationStack {
                        DictateView(parse: { try await sync.parseTasks($0, projects: $1) }, onSaved: { _ in sheet = nil; sync.syncSoon() })
                            .navigationTitle("Dictate").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { sheet = nil } } }
                    }
                }
            }
            .alert("Edit card", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), presenting: editing) { t in
                TextField("Title", text: $editTitle)
                Button("Save") { Board.retitle(t, editTitle, now: .now); sync.boardChanged() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func card(_ t: TaskItem, current: Bool) -> some View {
        Button { sync.tap(t) } label: { CardView(task: t, isCurrent: current) }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if t.state != .done {
                    Button { Board.complete(t, now: .now); sync.boardChanged() } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: t.state == .active) {
                if t.state == .active {
                    Button { Board.toPending(t, now: .now); sync.boardChanged() } label: { Label("Pending", systemImage: "arrow.uturn.backward") }
                        .tint(.indigo)
                }
                Button(role: .destructive) { Board.delete(t, now: .now); sync.boardChanged() } label: { Label("Delete", systemImage: "trash") }
            }
            .contextMenu {
                Button("Edit title", systemImage: "pencil") { editTitle = t.title; editing = t }
                Menu("Change project", systemImage: "folder") {
                    ForEach(projects) { p in
                        Button(p.name) { Board.move(t, to: p, now: .now); sync.boardChanged() }.disabled(p.id == t.project?.id)
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { Board.delete(t, now: .now); sync.boardChanged() }
            }
            .accessibilityHint(current ? "Current card" : "Makes this the current card")
    }
}

enum BoardSheet: String, Identifiable { case progress, settings, newProject, dictate; var id: String { rawValue } }

struct CardView: View {
    let task: TaskItem
    let isCurrent: Bool

    var body: some View {
        let color = Color(hex: task.project?.colorHex ?? "#8E8E93")
        let done = task.state == .done
        HStack(alignment: done ? .center : .top, spacing: 12) {
            if done {
                Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(color, in: Circle())
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(task.state == .pending ? 0.45 : 1)).frame(width: 4)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(task.title).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !done {
                    HStack(spacing: 8) {
                        ProjectChip(project: task.project)
                        if isCurrent {
                            HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text("Now") }
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            if done { Text(task.project?.menuTitle ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, done ? 10 : 12).padding(.leading, 12).padding(.trailing, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isCurrent ? color : .clear, lineWidth: 2))
        .opacity(done ? 0.75 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// What's tracked right now, with Break and Stop. Commands go to the Mac.
struct NowBar: View {
    let running: RunningSession?
    let project: Project?
    let current: TaskItem?
    @Environment(PhoneSync.self) private var sync

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let running {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    let stale = running.isStale(at: tl.date)
                    HStack(spacing: 12) {
                        ProjectIcon(name: project?.name ?? "Stint", colorHex: project?.colorHex ?? "#8E8E93", icon: project?.icon, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project?.name ?? "Tracking").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(stale ? "Mac last seen \(running.lastSeen.formatted(date: .omitted, time: .shortened))"
                                 : running.onBreak ? "On break" : running.offTask ? "Off task" : current?.title ?? "Focused")
                                .font(.footnote).lineLimit(1)
                                .foregroundStyle(stale || running.offTask ? Theme.warn : .secondary)
                        }
                        Spacer(minLength: 4)
                        Text(remainingText(running.totals(at: tl.date).focusedSec)).font(.title3.weight(.semibold).monospacedDigit())
                        circle(running.onBreak ? "play.fill" : "cup.and.saucer", running.onBreak ? "Resume" : "Take a break") {
                            Task { await sync.send(running.onBreak ? .breakEnd : .breakStart) }
                        }
                        circle("stop.fill", "Stop tracking") { Task { await sync.send(.stop) } }
                    }
                    .disabled(sync.waiting || stale)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "timer").font(.title3).frame(width: 40, height: 40)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Not tracking").font(.subheadline.weight(.semibold))
                        Text("Tap a card to start").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            if let s = sync.commandStatus { Text(s).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func circle(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).frame(width: 36, height: 36)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44).accessibilityLabel(label)
    }
}

/// Bottom bar: project chip, title field, mic (or send while typing). Return adds to the top of Pending.
struct QuickAddBar: View {
    let projects: [Project]
    let defaultProjectID: UUID?
    let newProject: () -> Void
    let dictate: () -> Void
    @Environment(PhoneSync.self) private var sync
    @Environment(\.modelContext) private var ctx
    @State private var title = ""
    @State private var chosen: UUID?
    @FocusState private var focused: Bool

    private var project: Project? {
        projects.first { $0.id == chosen } ?? projects.first { $0.id == defaultProjectID } ?? projects.first
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(projects) { p in
                    Button { chosen = p.id } label: {
                        if p.id == project?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
                Divider()
                Button("New project…", systemImage: "plus", action: newProject)
            } label: {
                if let project {
                    HStack(spacing: 4) { ProjectChip(project: project, size: 26); Image(systemName: "chevron.up.chevron.down").font(.caption2) }
                } else {
                    Label("Project", systemImage: "folder.badge.plus").font(.subheadline.weight(.semibold))
                }
            }
            .tint(.primary)
            .accessibilityLabel("Project for new card: \(project?.name ?? "none")")
            TextField("Add a task", text: $title)
                .focused($focused).submitLabel(.done).onSubmit(add)
                .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
                .padding(.horizontal, 12).frame(minHeight: 36)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Button { title.isEmpty ? dictate() : add() } label: {
                Image(systemName: title.isEmpty ? "mic.fill" : "arrow.up").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Color.accentColor, in: Circle())
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(title.isEmpty ? "Dictate tasks" : "Add card")
            .disabled(project == nil && !title.isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    private func add() {
        guard let p = project, Board.add(title: title, project: p, in: ctx, now: .now) != nil else { return }
        title = ""; chosen = nil
        sync.boardChanged()
        focused = true // keep the keyboard up for the next card
    }
}
