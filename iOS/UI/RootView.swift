import SwiftUI

enum Tab: Hashable { case today, tasks, dictate, week, rewards }

struct RootView: View {
    @Environment(PhoneSync.self) private var sync
    @State var tab: Tab = .today
    var body: some View {
        content.onOpenURL { url in
            tab = .today
            if let id = StartLink.parse(url) { sync.openStart(id) }
        }
    }
    @ViewBuilder private var content: some View {
        if case .signedIn = sync.state {
            TabView(selection: $tab) {
                TodayView().tabItem { Label("Today", systemImage: "sun.max") }.tag(Tab.today)
                TasksView().tabItem { Label("Tasks", systemImage: "checklist") }.tag(Tab.tasks)
                NavigationStack {
                    DictateView(parse: { try await sync.parseTasks($0, projects: $1) }) { _ in
                        sync.syncSoon(); tab = .tasks
                    }
                    .navigationTitle("Dictate")
                }
                .tabItem { Label("Dictate", systemImage: "mic.fill") }.tag(Tab.dictate)
                WeekView().tabItem { Label("Week", systemImage: "calendar") }.tag(Tab.week)
                RewardsView().tabItem { Label("Rewards", systemImage: "gift") }.tag(Tab.rewards)
            }
        } else { SignInView() }
    }
}
