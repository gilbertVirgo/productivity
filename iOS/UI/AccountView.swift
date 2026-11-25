import SwiftUI

struct AccountView: View {
    @Environment(PhoneSync.self) private var sync
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            if case .signedIn(let email) = sync.state { LabeledContent("Signed in", value: email) }
            if let e = sync.lastError {
                Text(e).foregroundStyle(Theme.warn)
            } else if let d = sync.lastSync {
                LabeledContent("Last synced", value: d.formatted(.relative(presentation: .named)))
            }
            Button("Sync now") { Task { await sync.refresh() } }
            Button("Sign out", role: .destructive) { confirmSignOut = true }
        }
        .navigationTitle("Account")
        .confirmationDialog("Signing out removes Stint data from this iPhone. It stays in your account.",
                            isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await sync.signOut() } }
        }
    }
}
