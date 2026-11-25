import SwiftUI

struct SignInView: View {
    @Environment(PhoneSync.self) private var sync
    @State private var email = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                if !sync.configured {
                    Text("Sync not configured").foregroundStyle(.secondary)
                } else {
                    Section {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(sync.state == .signingIn)
                        if sync.state == .signingIn {
                            TextField("Code", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                            Button("Verify") { Task { await sync.verify(email: email, code: code) } }
                                .disabled(code.isEmpty)
                            Button("Use a different email") { code = ""; sync.cancelSignIn() }
                        } else {
                            Button("Send code") { Task { await sync.sendCode(email: email) } }
                                .disabled(email.isEmpty)
                        }
                    } footer: {
                        #if DEBUG
                        Text("Local dev: the code is in Mailpit at http://127.0.0.1:54324")
                        #endif
                    }
                    if let e = sync.lastError { Text(e).foregroundStyle(Theme.warn) }
                }
            }
            .navigationTitle("Stint")
        }
    }
}
