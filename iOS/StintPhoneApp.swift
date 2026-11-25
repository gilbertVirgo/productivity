import SwiftUI
import SwiftData
import StintData

@main
struct StintPhoneApp: App {
    let container: ModelContainer
    @State private var sync: PhoneSync
    @Environment(\.scenePhase) private var phase

    init() {
        let c: ModelContainer
        do { c = try ModelContainer(for: Schema(StintSchema.models)) } catch { fatalError("store: \(error)") }
        container = c
        _sync = State(initialValue: PhoneSync(context: c.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(sync)
                .modelContainer(container)
                .onChange(of: phase) { _, p in Task { await sync.setActive(p == .active) } }
        }
    }
}
