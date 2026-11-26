import SwiftUI
import SwiftData
import Core
import StintData

struct TodayView: View {
    @Environment(PhoneSync.self) private var sync
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @State private var account = false
    @State private var desk = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let running = sync.running { SessionCard(running: running, projects: projects) } else { StartCard(projects: projects) }
                    Button { desk = true } label: { Label("Desk mode", systemImage: "square.grid.2x2") }
                    if let s = sync.commandStatus { Text(s).font(.footnote).foregroundStyle(.secondary) }
                }
                let lines = sync.snapshot?.lines ?? []
                Section("Today") {
                    if lines.isEmpty { Text("Projects you add on your Mac show up here.").foregroundStyle(.secondary) }
                    ForEach(lines) { l in
                        HStack {
                            Circle().fill(Color(hex: l.colorHex)).frame(width: 10, height: 10)
                            Text(l.name)
                            Spacer()
                            Text(hoursMinutes(l.todayFocusedSec)).monospacedDigit()
                        }
                    }
                }
                if !lines.isEmpty { Section("This week") { WeekBars(lines: lines) } }
            }
            .navigationTitle("Today")
            .refreshable { await sync.refresh() }
            .toolbar { Button("Account", systemImage: "person.crop.circle") { account = true } }
            .sheet(isPresented: $account) { NavigationStack { AccountView() } }
            .fullScreenCover(isPresented: $desk) { DeskView() }
        }
    }
}

struct SessionCard: View {
    let running: RunningSession
    let projects: [Project]
    @Environment(PhoneSync.self) private var sync

    var body: some View {
        let project = projects.first { $0.id == running.projectID }
        // Re-evaluated every 15 s: a Mac that quit sends nothing, so staleness must come from the clock, not a re-render.
        TimelineView(.periodic(from: .now, by: 15)) { staleTick in
        let stale = running.isStale(at: staleTick.date)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: project?.colorHex ?? "#8E8E93")).frame(width: 10, height: 10)
                Text(project?.name ?? "Session").font(.headline)
            }
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                Text(remainingText(running.totals(at: tl.date).focusedSec)).font(.system(size: 44, weight: .semibold).monospacedDigit())
            }
            Text(stale ? "Mac last seen \(running.lastSeen.formatted(date: .omitted, time: .shortened))"
                       : running.onBreak ? "On break" : running.offTask ? "Off task" : "Focused")
                .font(.subheadline).foregroundStyle(running.offTask || stale ? Theme.warn : .secondary)
            HStack {
                Button(running.onBreak ? "Resume" : "Take a break") {
                    Task { await sync.send(running.onBreak ? .breakEnd : .breakStart) }
                }.buttonStyle(.borderedProminent)
                Button("Stop") { Task { await sync.send(.stop) } }.buttonStyle(.bordered)
            }
            .disabled(sync.waiting || stale)
        }
        }
    }
}

struct StartCard: View {
    let projects: [Project]
    @Environment(PhoneSync.self) private var sync
    @State private var projectID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Switch on your Mac").font(.headline)
            Picker("Project", selection: $projectID) {
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            Button("Switch") {
                if let id = projectID { Task { await sync.send(.switchTo(projectID: id)) } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(projectID == nil || sync.waiting)
        }
        .onAppear { if projectID == nil { projectID = projects.first?.id } }
        .onChange(of: projects.map(\.id)) { _, ids in
            if projectID == nil || !ids.contains(projectID!) { projectID = ids.first }
        }
    }
}
