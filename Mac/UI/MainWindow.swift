import StintData
import SwiftUI
import SwiftData

enum MainSection: String, CaseIterable, Identifiable {
    case today = "Today", projects = "Projects", rewards = "Rewards"
    var id: String { rawValue }
    var icon: String {
        switch self { case .today: "sun.max"; case .projects: "folder"; case .rewards: "gift" }
    }
}

struct MainWindow: View {
    @Environment(\.modelContext) private var ctx
    @Query private var events: [PointEvent]   // observed so the balance refreshes
    @State private var section: MainSection? = .today

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $section) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("Points").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Ledger.balance(ctx))").font(.headline.monospacedDigit())
                    }.padding(12)
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch section ?? .today {
            case .today: TodayView()
            case .projects: ProjectsView()
            case .rewards: RewardsView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(Theme.accent)
    }
}
