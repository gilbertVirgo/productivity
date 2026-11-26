import Foundation
import SwiftData
import Supabase
import StintData
import Core
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
    @ObservationIgnored private var livePushes: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var handling = false
    @ObservationIgnored private var rerunCommands = false
    @ObservationIgnored private var generation = 0 // bumped on sign-out so in-flight passes discard their results
    @ObservationIgnored private let defaults = UserDefaults.standard

    init(app: AppState, context: ModelContext) {
        self.app = app; self.ctx = context
        if let c = SyncConfig.client(info: Bundle.main.infoDictionary) {
            client = c; engine = SyncEngine(client: c, context: context); configured = true
        } else {
            client = nil; engine = nil; configured = false
        }
        app.onCheckpoint = { [weak self] in self?.syncSoon() }
        app.onSessionClosed = { [weak self] in self?.syncSoon() }
        app.onLive = { [weak self] in self?.sendLive($0) }
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
        generation += 1
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
        livePushes?.cancel(); livePushes = nil
        userID = nil
        await engine?.stopRealtime()
        try? await client?.auth.signOut()
        while syncing || handling { try? await Task.sleep(for: .milliseconds(50)) } // in-flight passes bail on the generation change
        if let ctx { try? Self.resetSyncState(ctx) }
        userID = nil; lastSync = nil; lastError = nil; state = .signedOut
    }

    private func signedIn(_ user: User) async {
        state = .signedIn(email: user.email ?? "")
        switch ownerCheck(stored: defaults.string(forKey: "syncOwnerUserID"), current: user.id) {
        case .claim: defaults.set(user.id.uuidString, forKey: "syncOwnerUserID")
        case .ok: break
        case .mismatch:
            lastError = "This Mac's data belongs to another Stint account. Sign out and sign in with that account."
            return
        }
        userID = user.id
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.handlePending()
                await self?.syncNow()
            }
        }
        // Commands first: a slow first sync must not age them past 10 s.
        await engine?.startRealtime(userID: user.id) { [weak self] in
            self?.syncSoon()
            Task { await self?.handlePending() }
        }
        await handlePending()
        await syncNow()
    }

    // MARK: live activity

    /// In order, one at a time: an update must never overtake its start. Failures (503 = no APNs key yet) are logged only;
    /// the phone's own foreground reconcile still shows the session.
    private func sendLive(_ push: LivePush) {
        guard let engine, userID != nil else { return }
        let previous = livePushes, gen = generation
        livePushes = Task {
            await previous?.value
            guard gen == generation else { return } // signed out: cancel only reaches the tail, so check here
            do { try await engine.pushActivity(push) }
            catch { Self.log.notice("push-activity \(push.event.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: sync

    func parseTasks(_ transcript: String, projects: [Project]) async throws -> [ParsedTask] {
        guard let engine, userID != nil else { throw NotSignedIn() }
        return try await engine.parseTasks(transcript: transcript, projects: projects)
    }

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
        let gen = generation
        repeat {
            syncAgain = false
            do {
                try await engine.push(userID: userID)
                try await engine.pull()
                guard gen == generation else { return }
                lastSync = .now; lastError = nil
            } catch {
                guard gen == generation else { return }
                lastError = error.localizedDescription
                Self.log.error("sync: \(error.localizedDescription, privacy: .public)")
            }
        } while syncAgain && gen == generation
    }

    // MARK: phone commands

    private func handlePending() async {
        guard let engine else { return }
        if handling { rerunCommands = true; return }
        handling = true; defer { handling = false }
        let gen = generation
        repeat {
            rerunCommands = false
            do {
                for row in try await engine.pendingCommands() {
                    guard gen == generation else { return }
                    let age = Date.now.timeIntervalSince(row.createdAt)
                    switch Self.disposition(age: age, rejected: row.rejectedReason != nil) {
                    case .leave: continue // rejected, waiting for the phone to read it
                    case .cleanup:
                        Self.log.notice("cleaned up rejected command \(row.kind, privacy: .public), age \(Int(age))s")
                        try await engine.deleteCommand(row.id)
                        continue
                    case .rejectTooLate:
                        // Never delete: a missing row means "accepted" to the phone.
                        Self.log.notice("rejected stale command \(row.kind, privacy: .public), age \(Int(age))s")
                        try await engine.rejectCommand(row.id, reason: "Your Mac got this too late.")
                        continue
                    case .act: break
                    }
                    let cmd = SessionCommand.parse(row)
                    var done = cmd.map { Self.perform($0, on: app) } ?? false
                    if !done, let cmd, case .start = cmd {
                        // The project may have been created on the phone moments ago: pull once and retry.
                        await syncNow()
                        // A pass already in flight only queues another; wait until the queued pass finishes.
                        while syncing { try? await Task.sleep(for: .milliseconds(50)) }
                        guard gen == generation else { return }
                        done = Self.perform(cmd, on: app)
                    }
                    if done {
                        try await engine.deleteCommand(row.id) // deleting is the acknowledgement
                    } else {
                        if cmd == nil { Self.log.error("unparseable command \(row.kind, privacy: .public)") }
                        try await engine.rejectCommand(row.id, reason: Self.rejectionReason(cmd, isRunning: app.isRunning))
                    }
                }
            } catch { Self.log.error("commands: \(error.localizedDescription, privacy: .public)") }
        } while rerunCommands && gen == generation
    }

    enum Disposition { case act, rejectTooLate, cleanup, leave }
    /// A missing row means "accepted" to the phone, so only an acted-on command is ever deleted straight away.
    /// The phone polls for 15 s and the Mac never accepts after 10 s; rejected rows linger 60 s for the phone to read.
    static func disposition(age: TimeInterval, rejected: Bool) -> Disposition {
        if rejected { return age > 60 ? .cleanup : .leave }
        return age <= 10 ? .act : .rejectTooLate
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

    /// What the phone shows when the Mac can't act on a command.
    static func rejectionReason(_ cmd: SessionCommand?, isRunning: Bool) -> String {
        switch cmd {
        case nil: "Your Mac couldn't read that request. Update Stint on both devices."
        case .start: isRunning ? "A session is already running on your Mac." : "Your Mac doesn't have that project, or it's archived. If you just created it, try again in a minute."
        case .takeBreak, .resume, .endEarly: "No session is running on your Mac."
        }
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
