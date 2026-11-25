import SwiftUI
import SwiftData

@main
struct StintApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Project.self, AllowRule.self, TaskItem.self,
                                           SessionRecord.self, PointEvent.self, Treat.self)
        } catch { fatalError("ModelContainer: \(error)") }
    }

    var body: some Scene {
        MenuBarExtra("Stint", systemImage: "timer") {
            Text("Stint")
                .padding()
        }
        .menuBarExtraStyle(.window)
        .modelContainer(container)

        Window("Stint", id: "main") {
            Text("Stint")
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(container)
    }
}
