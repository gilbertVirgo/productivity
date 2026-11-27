import SwiftUI
import SwiftData
import Core
import StintData

/// Progress (spec 2026-11-27 §5): Today, This week, Rewards, goal history in one scroll.
struct ProgressSheet: View {
    @Environment(PhoneSync.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Query private var tasks: [TaskItem]

    var body: some View {
        let lines = sync.snapshot?.lines ?? []
        NavigationStack {
            List {
                Section("Today") {
                    LabeledContent("Focused", value: hoursMinutes(sync.snapshot?.todayFocusedSec ?? 0))
                    LabeledContent("Points", value: "\(sync.snapshot?.pointsToday ?? 0)")
                    LabeledContent("Cards done", value: "\(sync.board(tasks).doneToday.count)")
                    ForEach(lines) { l in
                        HStack {
                            Circle().fill(Color(hex: l.colorHex)).frame(width: 10, height: 10)
                            Text(l.name)
                            Spacer()
                            Text(hoursMinutes(l.todayFocusedSec)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if !lines.isEmpty { Section("This week") { WeekBars(lines: lines) } }
                RewardsSections()
                GoalHistorySections()
            }
            .navigationTitle("Progress").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await sync.refresh() }
        }
    }
}

/// Settings (spec §5): projects, Desk mode, account.
struct SettingsSheet: View {
    let openDesk: () -> Void
    @Environment(PhoneSync.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.createdAt) private var projects: [Project]
    @State private var created: Project?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(projects) { p in
                        NavigationLink { ProjectEditorView(project: p) } label: {
                            HStack(spacing: 12) {
                                ProjectIcon(name: p.name, colorHex: p.colorHex, icon: p.icon, size: 28)
                                Text(p.name)
                                Spacer()
                                if let h = p.weeklyHoursGoal { Text("\(h.formatted())h/wk").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Button("New project", systemImage: "plus") {
                        created = Project.makeNew(in: ctx); ctx.saveLogged()
                    }
                } header: { Text("Projects") } footer: { Text("App and site allowlists, treats and break allowance are set on your Mac.") }
                Section {
                    Button("Desk mode", systemImage: "square.grid.2x2") { dismiss(); openDesk() }
                }
                Section("Account") {
                    NavigationLink("Account") { AccountView() }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(item: $created) { ProjectEditorView(project: $0, isNew: true) }
        }
    }
}

/// Settings › Project: name, short name, colour, icon, goals, flags, archive.
struct ProjectEditorView: View {
    @Bindable var project: Project
    var isNew = false
    @Environment(PhoneSync.self) private var sync
    @Environment(\.dismiss) private var dismiss

    private func edit<T>(_ kp: ReferenceWritableKeyPath<Project, T>) -> Binding<T> {
        Binding(get: { project[keyPath: kp] }, set: { project[keyPath: kp] = $0; project.updatedAt = .now })
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    ProjectIcon(name: project.name, colorHex: project.colorHex, icon: project.icon, size: 72)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Name", text: edit(\.name))
                TextField("Short name (menu bar)", text: Binding(
                    get: { project.shortName ?? "" },
                    set: { project.shortName = $0.isEmpty ? nil : $0; project.updatedAt = .now }))
            }
            Section("Colour") {
                HStack {
                    ForEach(ProjectColor.all, id: \.self) { hex in
                        Button { project.colorHex = hex; project.updatedAt = .now } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                                .overlay(Circle().strokeBorder(.white, lineWidth: project.colorHex == hex ? 3 : 0))
                                .overlay(Circle().strokeBorder(Color(hex: hex), lineWidth: project.colorHex == hex ? 1 : 0).padding(-3))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hex).accessibilityAddTraits(project.colorHex == hex ? .isSelected : [])
                    }
                }
            }
            Section("Icon") { IconPicker(selection: edit(\.icon), colorHex: project.colorHex).padding(.vertical, 4) }
            Section("Goals") {
                HoursGoalField(label: "Hours per week", value: project.weeklyHoursGoal) { project.weeklyHoursGoal = $0; project.updatedAt = .now }
                HoursGoalField(label: "Hours per day", value: project.dailyHoursGoal) { project.dailyHoursGoal = $0; project.updatedAt = .now }
            }
            Section {
                Toggle("Work happens off the Mac", isOn: edit(\.offMac))
                Toggle("Show on share page", isOn: edit(\.shared))
            }
            if !isNew {
                Section {
                    Button("Archive project", role: .destructive) {
                        project.archivedAt = .now; project.updatedAt = .now
                        sync.boardChanged(); dismiss()
                    }
                }
            }
        }
        .navigationTitle(project.name.isEmpty ? "Project" : project.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { if isNew { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
        .onDisappear { sync.boardChanged() }
    }
}

/// A goal in hours: empty = no goal. Invalid text is shown and not saved.
private struct HoursGoalField: View {
    let label: String
    let set: (Double?) -> Void
    @State private var text: String
    @State private var error: String?

    init(label: String, value: Double?, set: @escaping (Double?) -> Void) {
        self.label = label; self.set = set
        _text = State(initialValue: value.map { $0.formatted() } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label) {
                TextField("None", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .onChange(of: text) { _, t in
                        switch GoalInput.parse(t) {
                        case .empty: error = nil; set(nil)
                        case .value(let v): error = nil; set(v)
                        case .invalid(let m): error = m
                        }
                    }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.warn) }
        }
    }
}
