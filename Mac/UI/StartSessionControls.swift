import SwiftUI
import SwiftData
import Core

/// Project / length / first-task pickers and the Start button. Shared by the menu bar and the Today screen.
struct StartSessionControls: View {
    @Environment(AppState.self) private var app
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @State private var projectID: UUID?
    @State private var plannedMin = 25
    @State private var taskID: UUID?

    private var selected: Project? { projects.first { $0.id == projectID } ?? projects.first }
    private var openTasks: [TaskItem] { (selected?.tasks ?? []).filter { $0.doneAt == nil }.sorted { $0.sort < $1.sort } }

    #if DEBUG
    private let lengths = [1, 25, 50, 90]
    #else
    private let lengths = [25, 50, 90]
    #endif

    var body: some View {
        if projects.isEmpty {
            Text("No projects yet").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Project", selection: Binding(get: { selected?.id }, set: { projectID = $0; taskID = nil })) {
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Length", selection: $plannedMin) {
                    ForEach(lengths, id: \.self) { Text("\($0)").tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Picker("First task", selection: $taskID) {
                    Text("No task").tag(UUID?.none)
                    ForEach(openTasks) { Text($0.title).tag(Optional($0.id)) }
                }
                Button("Start") {
                    if let p = selected { app.start(project: p, plannedMin: plannedMin, firstTask: openTasks.first { $0.id == taskID }) }
                }.buttonStyle(.borderedProminent).disabled(selected == nil || app.isRunning)
            }
        }
    }
}
