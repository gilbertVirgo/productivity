import StintData
import SwiftUI
import SwiftData
import Core

@main
struct StintApp: App {
    let container: ModelContainer
    @State private var app: AppState
    @State private var sync: SyncCoordinator

    init() {
        do {
            container = try ModelContainer(for: Schema(StintSchema.models))
        } catch { fatalError("ModelContainer: \(error)") }
        let state = AppState(context: container.mainContext)
        _app = State(initialValue: state)
        _sync = State(initialValue: SyncCoordinator(app: state, context: container.mainContext))
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
            MainWindow().environment(app).environment(sync)
        }
        .modelContainer(container)
    }
}
