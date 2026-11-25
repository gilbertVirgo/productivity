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
        #if DEBUG
        Self.seedSample(container.mainContext)
        #endif
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
            Text("Stint")
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(container)
    }

    #if DEBUG
    // Removed in Task 6 once projects can be created in the UI.
    @MainActor private static func seedSample(_ ctx: ModelContext) {
        guard ((try? ctx.fetchCount(FetchDescriptor<Project>())) ?? 0) == 0 else { return }
        let p = Project(name: "Sample project", colorHex: "#0F7B6C")
        ctx.insert(p)
        for e in [AllowEntry(.app, "com.figma.desktop"), AllowEntry(.app, "com.apple.dt.xcode"), AllowEntry(.domain, "figma.com")] {
            let r = AllowRule(e); ctx.insert(r); r.project = p
        }
        try? ctx.save()
    }
    #endif
}
