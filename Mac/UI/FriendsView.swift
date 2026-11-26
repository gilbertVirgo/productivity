import SwiftUI
import StintData

/// Spec §6.10: one revocable link per friend. Links live on the server only (they need the account anyway).
struct FriendsView: View {
    @Environment(SyncCoordinator.self) private var sync
    @State private var links: [ShareLinkRow] = []
    @State private var label = ""
    @State private var error: String?
    @State private var busy = false
    @State private var revoking: ShareLinkRow?

    private var signedIn: Bool { if case .signedIn = sync.state { true } else { false } }

    var body: some View {
        Form {
            if !signedIn {
                Text("Sign in under Account to share your goals with friends.").foregroundStyle(.secondary)
            } else {
                Section {
                    Text("Friends see only the projects you mark \u{201C}Show on share page\u{201D}, by the name you give them, with this week's goals and results. Never project names, tasks, apps, sites or points.")
                        .foregroundStyle(.secondary)
                }
                Section("New link") {
                    TextField("Who is it for? Only you see this.", text: $label)
                    Button("Create link") { Task { await create() } }.disabled(busy)
                }
                Section("Links") {
                    if links.isEmpty { Text("No links yet.").foregroundStyle(.secondary) }
                    ForEach(links) { link in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(link.friendLabel.isEmpty ? "Unnamed link" : link.friendLabel)
                                Text("Created \(link.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let url = sync.shareURL(link) {
                                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                }
                            }
                            Button("Revoke", role: .destructive) { revoking = link }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.warn) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Friends")
        .task(id: signedIn) { await load() }
        .confirmationDialog("Revoke this link?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            presenting: revoking) { link in
            Button("Revoke", role: .destructive) { Task { await revoke(link) } }
        } message: { _ in
            Text("Anyone with it will see \u{201C}This link isn't active.\u{201D} You can make a new one later.")
        }
    }

    private func load() async {
        guard signedIn else { links = []; return }
        do { links = try await sync.shareLinks(); error = nil } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func create() async {
        busy = true; defer { busy = false }
        do { links.append(try await sync.createShareLink(label: label)); label = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func revoke(_ link: ShareLinkRow) async {
        do { try await sync.revokeShareLink(link); links.removeAll { $0.id == link.id }; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
