import SwiftUI
import SwiftData
import Core
import StintData

struct TodayView: View {
    @Environment(PhoneSync.self) private var sync
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @Query(filter: #Predicate<TaskItem> { $0.doneAt == nil }) private var openTasks: [TaskItem]
    @State private var account = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let running = sync.running { SessionCard(running: running, projects: projects) } else { StartCard(projects: projects) }
                    if let s = sync.commandStatus { Text(s).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("This week") {
                    let lines = sync.snapshot?.lines ?? []
                    if lines.isEmpty { Text("Projects you add on your Mac show up here.").foregroundStyle(.secondary) }
                    else { WeekBars(lines: lines) }
                }
                Section("Up next") {
                    let next = upNext(openTasks, limit: 5)
                    if next.isEmpty { Text("No open tasks.").foregroundStyle(.secondary) }
                    ForEach(next) { TaskLine(task: $0) }
                }
            }
            .navigationTitle("Today")
            .refreshable { await sync.refresh() }
            .toolbar { Button("Account", systemImage: "person.crop.circle") { account = true } }
            .sheet(isPresented: $account) { NavigationStack { AccountView() } }
        }
    }
}

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

struct StartCard: View {
    let projects: [Project]
    @Environment(PhoneSync.self) private var sync
    @State private var projectID: UUID?
    @State private var minutes = 50
    @State private var taskID: UUID?

    var body: some View {
        let project = projects.first { $0.id == projectID }
        VStack(alignment: .leading, spacing: 10) {
            Text("Start on your Mac").font(.headline)
            Picker("Project", selection: $projectID) {
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Length", selection: $minutes) {
                ForEach([25, 50, 90], id: \.self) { Text("\($0) min").tag($0) }
            }.pickerStyle(.segmented)
            Picker("First task", selection: $taskID) {
                Text("None").tag(UUID?.none)
                ForEach(upNext(project?.tasks ?? [], limit: 50)) { Text($0.title).tag(Optional($0.id)) }
            }
            Button("Start") {
                if let id = projectID { Task { await sync.send(.start(projectID: id, plannedMin: minutes, firstTaskID: taskID)) } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(projectID == nil || sync.waiting)
        }
        .onAppear { if projectID == nil { projectID = projects.first?.id } }
        .onChange(of: projectID) { taskID = nil }
    }
}
