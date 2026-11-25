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
    @ObservationIgnored private let client: SupabaseClient?
    @ObservationIgnored private let engine: SyncEngine?
    @ObservationIgnored private var userID: UUID?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var handling = false

    init(app: AppState, context: ModelContext) {
        self.app = app
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
        await engine?.stopRealtime()
        try? await client?.auth.signOut()
        userID = nil; lastSync = nil; lastError = nil; state = .signedOut
    }

    private func signedIn(_ user: User) async {
        userID = user.id
        state = .signedIn(email: user.email ?? "")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        await syncNow()
        await engine?.startRealtime { [weak self] in
            self?.syncSoon()
            Task { await self?.handlePending() }
        }
        await handlePending()
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
        guard let engine, let userID, !syncing else { return }
        syncing = true; defer { syncing = false }
        do {
            try await engine.push(userID: userID)
            try await engine.pull()
            lastSync = .now; lastError = nil
        } catch {
            lastError = error.localizedDescription
            Self.log.error("sync: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: phone commands

    private func handlePending() async {
        guard let engine, !handling else { return }
        handling = true; defer { handling = false }
        do {
            for row in try await engine.pendingCommands() {
                if Date.now.timeIntervalSince(row.createdAt) <= 10 {
                    if let cmd = SessionCommand.parse(row) { _ = Self.perform(cmd, on: app) }
                    else { Self.log.error("unparseable command \(row.kind, privacy: .public)") }
                }
                try await engine.deleteCommand(row.id) // deleting is the acknowledgement
            }
        } catch { Self.log.error("commands: \(error.localizedDescription, privacy: .public)") }
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
