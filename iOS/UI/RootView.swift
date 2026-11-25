import SwiftUI

struct RootView: View {
    @Environment(PhoneSync.self) private var sync
    var body: some View {
        if case .signedIn = sync.state { NavigationStack { AccountView() } } else { SignInView() }
    }
}
