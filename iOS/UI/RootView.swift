import SwiftUI

enum Tab: Hashable { case today, tasks, week, rewards }

struct RootView: View {
    @Environment(PhoneSync.self) private var sync
    @State var tab: Tab = .today
    var body: some View {
        if case .signedIn = sync.state {
            TabView(selection: $tab) {
                TodayView().tabItem { Label("Today", systemImage: "sun.max") }.tag(Tab.today)
                TasksView().tabItem { Label("Tasks", systemImage: "checklist") }.tag(Tab.tasks)
                WeekView().tabItem { Label("Week", systemImage: "calendar") }.tag(Tab.week)
                RewardsView().tabItem { Label("Rewards", systemImage: "gift") }.tag(Tab.rewards)
            }
        } else { SignInView() }
    }
}
