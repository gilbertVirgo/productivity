import SwiftUI

/// One main screen (spec 2026-11-27 §5): the board. Progress and Settings are sheets; Desk mode is a full-screen cover.
struct RootView: View {
    @Environment(PhoneSync.self) private var sync
    @State private var desk = false
    var body: some View {
        content.onOpenURL { url in
            if DeskLink.matches(url) { desk = true }
        }
    }
    @ViewBuilder private var content: some View {
        if case .signedIn = sync.state {
            BoardView(desk: $desk)
                .fullScreenCover(isPresented: $desk) { DeskView() }
        } else { SignInView() }
    }
}
