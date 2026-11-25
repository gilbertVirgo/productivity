import SwiftUI

@main
struct StintApp: App {
    var body: some Scene {
        MenuBarExtra("Stint", systemImage: "timer") {
            Text("Stint")
                .padding()
        }
        .menuBarExtraStyle(.window)

        Window("Stint", id: "main") {
            Text("Stint")
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
