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
            // Unsandboxed: SwiftData's default URL (~/Library/Application Support/default.store) is shared
            // with every other unsandboxed app, so keep the store in a folder named for this bundle.
            let dir = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.stint.mac")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            container = try ModelContainer(for: Schema(StintSchema.models),
                                           configurations: ModelConfiguration(url: dir.appending(path: "Stint.store")))
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
