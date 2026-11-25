import SwiftUI
import SwiftData
import StintData

struct TasksView: View {
    @Environment(PhoneSync.self) private var sync
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]

    var body: some View {
        NavigationStack {
            List {
                if projects.isEmpty { Text("Add a project on your Mac first.").foregroundStyle(.secondary) }
                ForEach(projects) { p in
                    Section(p.name) {
                        ForEach(visibleTasks(p.tasks, now: .now, calendar: sync.cal)) { TaskLine(task: $0) }
                        AddTaskField(project: p)
                    }
                }
            }
            .navigationTitle("Tasks")
            .refreshable { await sync.refresh() }
        }
    }
}

struct TaskLine: View {
    let task: TaskItem
    @Environment(PhoneSync.self) private var sync
    @Environment(\.modelContext) private var ctx

    var body: some View {
        Button {
            task.doneAt = task.doneAt == nil ? .now : nil
            task.updatedAt = .now
            ctx.saveLogged()
            sync.syncSoon()
        } label: {
            HStack {
                Image(systemName: task.doneAt == nil ? "circle" : "checkmark.circle.fill")
                Text(task.title).strikethrough(task.doneAt != nil)
                Spacer()
                if let m = task.estimateMin { Text("\(m)m").foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }
}

struct AddTaskField: View {
    let project: Project
    @Environment(PhoneSync.self) private var sync
    @Environment(\.modelContext) private var ctx
    @State private var title = ""

    var body: some View {
        TextField("Add a task", text: $title).onSubmit {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let item = TaskItem(title: t, sort: (project.tasks.map(\.sort).max() ?? -1) + 1)
            ctx.insert(item); item.project = project
            ctx.saveLogged()
            title = ""
            sync.syncSoon()
        }
    }
}
