import SwiftUI

enum Tab: Hashable { case today, week, rewards }

struct RootView: View {
    @Environment(PhoneSync.self) private var sync
    @State var tab: Tab = .today
    @State private var desk = false
    var body: some View {
        content.onOpenURL { url in
            tab = .today
            if DeskLink.matches(url) { desk = true }
        }
    }
    @ViewBuilder private var content: some View {
        if case .signedIn = sync.state {
            TabView(selection: $tab) {
                TodayView().tabItem { Label("Today", systemImage: "sun.max") }.tag(Tab.today)
                WeekView().tabItem { Label("Week", systemImage: "calendar") }.tag(Tab.week)
                RewardsView().tabItem { Label("Rewards", systemImage: "gift") }.tag(Tab.rewards)
            }
            .fullScreenCover(isPresented: $desk) { DeskView() }
        } else { SignInView() }
    }
}
