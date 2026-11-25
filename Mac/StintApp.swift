import SwiftUI
import SwiftData
import Core

@main
struct StintApp: App {
    let container: ModelContainer
    @State private var app: AppState

    init() {
        do {
            container = try ModelContainer(for: Project.self, AllowRule.self, TaskItem.self,
                                           SessionRecord.self, PointEvent.self, Treat.self)
        } catch { fatalError("ModelContainer: \(error)") }
        _app = State(initialValue: AppState(context: container.mainContext))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environment(app)
        } label: {
            MenuBarLabel().environment(app)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(container)

        Window("Stint", id: "main") {
            MainWindow().environment(app)
        }
        .modelContainer(container)
    }
}
