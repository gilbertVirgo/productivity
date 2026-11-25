import StintData
import SwiftUI
import SwiftData
import AppKit
import Core

struct ProjectsView: View {
    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.createdAt) private var projects: [Project]
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(projects, selection: $selection) { p in
                    HStack { Circle().fill(Color(hex: p.colorHex)).frame(width: 9, height: 9); Text(p.name) }.tag(p.id)
                }
                Divider()
                Button("New project", action: create).padding(8)
            }.frame(width: 220)
            Divider()
            if let p = projects.first(where: { $0.id == selection }) {
                ProjectEditor(project: p, onArchive: { selection = nil }).id(p.id)
            } else {
                Text("Select or create a project").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func create() {
        let total = (try? ctx.fetchCount(FetchDescriptor<Project>())) ?? projects.count
        let p = Project(name: "Untitled", shareAlias: "Project \(total + 1)",
                        colorHex: ProjectColor.all[total % ProjectColor.all.count])
        ctx.insert(p)
        ctx.saveLogged()
        selection = p.id
    }
}

private struct ProjectEditor: View {
    @Environment(\.modelContext) private var ctx
    @Bindable var project: Project
    let onArchive: () -> Void
    @State private var newDomain = ""

    /// Binding that stamps `updatedAt` on every edit.
    private func edit<T>(_ kp: ReferenceWritableKeyPath<Project, T>) -> Binding<T> {
        Binding(get: { project[keyPath: kp] }, set: { project[keyPath: kp] = $0; project.updatedAt = .now })
    }

    private func rules(_ kind: AllowKind) -> [AllowRule] {
        project.allowRules.filter { $0.kind == kind.rawValue }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Name", text: edit(\.name)).font(.title2.bold()).textFieldStyle(.plain)
                HStack {
                    ForEach(ProjectColor.all, id: \.self) { hex in
                        Button { project.colorHex = hex; project.updatedAt = .now } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary, lineWidth: project.colorHex == hex ? 2 : 0).padding(-3))
                        }.buttonStyle(.plain)
                    }
                }
                goals
                appsSection
                sitesSection
                GroupBox("Friends") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show on share page", isOn: edit(\.shared))
                        HStack { Text("Name friends see"); TextField("Project", text: edit(\.shareAlias)).frame(width: 200) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                Button("Archive project", role: .destructive) {
                    project.archivedAt = .now; project.updatedAt = .now; ctx.saveLogged(); onArchive()
                }
            }.padding(24).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var goals: some View {
        GroupBox("Goals") {
            VStack(alignment: .leading, spacing: 10) {
                GoalField(label: "Hours per week", initial: project.weeklyHoursGoal.map { "\($0)" } ?? "") { v in
                    project.weeklyHoursGoal = v; project.updatedAt = .now
                }
                GoalField(label: "Hours per day", initial: project.dailyHoursGoal.map { "\($0)" } ?? "") { v in
                    project.dailyHoursGoal = v; project.updatedAt = .now
                }
                HStack(spacing: 4) {
                    Text("On days")
                    ForEach(Array("MTWTFSS".enumerated()), id: \.offset) { i, c in
                        let day = i + 1
                        Toggle(String(c), isOn: Binding(
                            get: { project.dailyGoalDays.contains(day) },
                            set: { on in
                                var d = Set(project.dailyGoalDays)
                                if on { d.insert(day) } else { d.remove(day) }
                                project.dailyGoalDays = d.sorted(); project.updatedAt = .now
                            })).toggleStyle(.button)
                    }
                }
                HStack {
                    GoalField(label: "Tasks done", initial: project.tasksGoal.map { "\($0)" } ?? "", wholeNumber: true) { v in
                        project.tasksGoal = v.map { Int($0) }; project.updatedAt = .now
                    }
                    Picker("Period", selection: edit(\.tasksGoalPeriod)) {
                        Text("per day").tag("day"); Text("per week").tag("week")
                    }.labelsHidden().frame(width: 100)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private var appsSection: some View {
        GroupBox("On-task apps") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rules(.app)) { r in
                    HStack {
                        Text(r.label.isEmpty ? r.value : r.label)
                        Text(r.value).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { remove(r) }
                    }
                }
                Button("Add app…", action: addApp)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private var sitesSection: some View {
        GroupBox("On-task websites") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rules(.domain)) { r in
                    HStack { Text(r.value); Spacer(); Button("Remove") { remove(r) } }
                }
                TextField("Add website, e.g. figma.com", text: $newDomain).onSubmit(addDomain)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func remove(_ r: AllowRule) {
        ctx.insert(Tombstone(table: "project_allow", rowID: r.id, at: .now))
        ctx.delete(r); project.updatedAt = .now; ctx.saveLogged()
    }

    private func addRule(_ entry: AllowEntry, label: String = "") {
        guard !entry.value.isEmpty, !project.allowEntries.contains(entry) else { return }
        let r = AllowRule(entry, label: label)
        ctx.insert(r)
        r.project = project
        project.updatedAt = .now
        ctx.saveLogged()
    }

    private func addDomain() {
        addRule(AllowEntry(.domain, newDomain))
        newDomain = ""
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        addRule(AllowEntry(.app, id), label: url.deletingPathExtension().lastPathComponent)
    }
}

/// Numeric goal field: empty clears the goal, positive saves, anything else shows an inline error and is not saved.
private struct GoalField: View {
    let label: String
    var wholeNumber = false
    let apply: (Double?) -> Void
    @State private var text: String
    @State private var error: String?

    init(label: String, initial: String, wholeNumber: Bool = false, apply: @escaping (Double?) -> Void) {
        self.label = label; self.wholeNumber = wholeNumber; self.apply = apply
        _text = State(initialValue: initial.hasSuffix(".0") ? String(initial.dropLast(2)) : initial)
    }

    var body: some View {
        HStack {
            Text(label)
            TextField("No goal", text: $text).frame(width: 80)
                .onChange(of: text) { _, t in
                    switch GoalInput.parse(t, wholeNumber: wholeNumber) {
                    case .empty: error = nil; apply(nil)
                    case let .value(v): error = nil; apply(v)
                    case let .invalid(m): error = m
                    }
                }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.warn) }
        }
    }
}
