import Foundation
import SwiftData
import Supabase
import StintData
import os

@MainActor @Observable
final class SyncCoordinator {
    enum State: Equatable { case signedOut, signingIn, signedIn(email: String) }

    private static let log = Logger(subsystem: "dev.stint.mac", category: "sync")

    var state: State = .signedOut
    var lastSync: Date?
    var lastError: String?
    let configured: Bool

    @ObservationIgnored private let app: AppState
    @ObservationIgnored private let ctx: ModelContext?
    @ObservationIgnored private let client: SupabaseClient?
    @ObservationIgnored private let engine: SyncEngine?
    @ObservationIgnored private var userID: UUID?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var handling = false
    @ObservationIgnored private var rerunCommands = false

    init(app: AppState, context: ModelContext) {
        self.app = app; self.ctx = context
        let info = Bundle.main.infoDictionary
        func value(_ k: String) -> String? { (info?[k] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } }
        if let u = value("StintSupabaseURL").flatMap(URL.init(string:)), let key = value("StintSupabaseAnonKey") {
            let c = SupabaseClient(
                supabaseURL: u, supabaseKey: key,
                options: .init(db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
                               auth: .init(emitLocalSessionAsInitialSession: true)))
            client = c; engine = SyncEngine(client: c, context: context); configured = true
        } else {
            client = nil; engine = nil; configured = false
        }
        app.onCheckpoint = { [weak self] in self?.syncSoon() }
        app.onSessionClosed = { [weak self] in self?.syncSoon() }
        Task { await resume() }
    }

    // MARK: auth

    private func resume() async {
        guard let client, let s = try? await client.auth.session else { return }
        await signedIn(s.user)
    }

    func sendCode(email: String) async {
        guard let client else { return }
        lastError = nil
        do { try await client.auth.signInWithOTP(email: email); state = .signingIn }
        catch { lastError = error.localizedDescription }
    }

    func cancelSignIn() { lastError = nil; state = .signedOut }

    func verify(email: String, code: String) async {
        guard let client else { return }
        lastError = nil
        do {
            let r = try await client.auth.verifyOTP(email: email, token: code, type: .email)
            await signedIn(r.user)
        } catch { lastError = error.localizedDescription }
    }

    func signOut() async {
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
        await engine?.stopRealtime()
        try? await client?.auth.signOut()
        if let ctx { try? Self.resetSyncState(ctx) }
        userID = nil; lastSync = nil; lastError = nil; state = .signedOut
    }

    private func signedIn(_ user: User) async {
        userID = user.id
        state = .signedIn(email: user.email ?? "")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.handlePending()
                await self?.syncNow()
            }
        }
        // Commands first: a slow first sync must not age them past 10 s.
        await engine?.startRealtime { [weak self] in
            self?.syncSoon()
            Task { await self?.handlePending() }
        }
        await handlePending()
        await syncNow()
    }

    // MARK: sync

    func syncSoon() {
        guard userID != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let engine, let userID else { return }
        if syncing { syncAgain = true; return }
        syncing = true; defer { syncing = false }
        repeat {
            syncAgain = false
            do {
                try await engine.push(userID: userID)
                try await engine.pull()
                lastSync = .now; lastError = nil
            } catch {
                lastError = error.localizedDescription
                Self.log.error("sync: \(error.localizedDescription, privacy: .public)")
            }
        } while syncAgain && self.userID != nil
    }

    // MARK: phone commands

    private func handlePending() async {
        guard let engine else { return }
        if handling { rerunCommands = true; return }
        handling = true; defer { handling = false }
        repeat {
            rerunCommands = false
            do {
                for row in try await engine.pendingCommands() {
                    if Date.now.timeIntervalSince(row.createdAt) <= 10 {
                        if let cmd = SessionCommand.parse(row) { _ = Self.perform(cmd, on: app) }
                        else { Self.log.error("unparseable command \(row.kind, privacy: .public)") }
                    }
                    try await engine.deleteCommand(row.id) // deleting is the acknowledgement
                }
            } catch { Self.log.error("commands: \(error.localizedDescription, privacy: .public)") }
        } while rerunCommands
    }

    /// Signed-out data is local-only: the next account to sign in receives everything.
    static func resetSyncState(_ ctx: ModelContext, defaults: UserDefaults = .standard) throws {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("sync.watermark.") { defaults.removeObject(forKey: k) }
        defaults.removeObject(forKey: "profileUpdatedAt")
        func clear<M: PersistentModel & Syncable>(_ t: M.Type) throws {
            for var m in try ctx.fetch(FetchDescriptor<M>()) { m.syncedAt = nil }
        }
        try clear(Project.self); try clear(AllowRule.self); try clear(TaskItem.self)
        try clear(SessionRecord.self); try clear(PointEvent.self); try clear(Treat.self)
        for t in try ctx.fetch(FetchDescriptor<Tombstone>()) { ctx.delete(t) }
        try ctx.save()
    }

    /// True when the command was acted on.
    static func perform(_ cmd: SessionCommand, on app: AppState) -> Bool {
        switch cmd {
        case let .start(projectID, plannedMin, firstTaskID):
            return app.start(projectID: projectID, plannedMin: plannedMin, firstTaskID: firstTaskID)
        case .takeBreak:
            guard app.isRunning else { return false }
            app.takeBreak(); return true
        case .resume:
            guard app.isRunning else { return false }
            app.resume(); return true
        case let .endEarly(reason):
            guard app.isRunning else { return false }
            app.endEarly(reason: reason); return !app.isRunning
        }
    }
}
