import SwiftUI

struct AccountView: View {
    @Environment(SyncCoordinator.self) private var sync
    @State private var email = ""
    @State private var code = ""
    @AppStorage("displayName") private var displayName = ""

    var body: some View {
        Form {
            if !sync.configured {
                Text("Sync not configured").foregroundStyle(.secondary)
            } else {
                switch sync.state {
                case .signedOut:
                    TextField("Email", text: $email)
                    Button("Send code") { Task { await sync.sendCode(email: email) } }.disabled(email.isEmpty)
                case .signingIn:
                    TextField("Code", text: $code)
                    Button("Verify") { Task { await sync.verify(email: email, code: code) } }.disabled(code.isEmpty)
                case let .signedIn(mail):
                    LabeledContent("Signed in as", value: mail)
                    if let e = sync.lastError {
                        Text(e).foregroundStyle(Theme.warn)
                    } else if let t = sync.lastSync {
                        LabeledContent("Last synced") { Text(t, style: .relative) + Text(" ago") }
                    }
                    Button("Sync now") { Task { await sync.syncNow() } }
                    TextField("Name friends see", text: Binding(
                        get: { displayName },
                        set: { displayName = $0; UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "profileUpdatedAt") }))
                    Button("Sign out") { Task { await sync.signOut() } }
                }
                if case .signedIn = sync.state {} else if let e = sync.lastError {
                    Text(e).foregroundStyle(Theme.warn)
                }
                #if DEBUG
                if case .signedIn = sync.state {} else {
                    Text("Local dev: the code is in Inbucket at http://127.0.0.1:54324").font(.caption).foregroundStyle(.secondary)
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
    }
}
