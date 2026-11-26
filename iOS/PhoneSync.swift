import Foundation
import SwiftData
import Supabase
import StintData
import Core
import os
import WidgetKit
import ActivityKit
import AuthenticationServices

/// The phone's sync: auth, push/pull through the shared SyncEngine, the session feed, and commands to the Mac.
@MainActor @Observable
final class PhoneSync {
    enum State: Equatable { case signedOut, signingIn, signedIn(email: String) }
    static let log = Logger(subsystem: "dev.stint.ios", category: "sync")

    var state: State = .signedOut
    var lastSync: Date?
    var lastError: String?
    var running: RunningSession?
    var snapshot: WidgetSnapshot?
    /// "Waiting for your Mac…" while a command is pending; afterwards the rejection or "Mac not reachable".
    var commandStatus: String?
    var waiting = false
    let configured: Bool
    let cal = PeriodCalendar(timeZone: .current)
    @ObservationIgnored let live = LiveActivities()
    static let deviceIDKey = "deviceID"

    @ObservationIgnored private let ctx: ModelContext
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: SupabaseClient?
    @ObservationIgnored private let engine: SyncEngine?
    @ObservationIgnored private var userID: UUID?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var loggedGroupMissing = false
    @ObservationIgnored private var activeTask: Task<Void, Never>? // serializes setActive so a late stop can't land after a start
    @ObservationIgnored private var generation = 0 // bumped on sign-out so in-flight passes discard their results

    init(context: ModelContext, defaults: UserDefaults = .standard, info: [String: Any]? = Bundle.main.infoDictionary) {
        ctx = context; self.defaults = defaults
        client = SyncConfig.client(info: info)
        engine = client.map { SyncEngine(client: $0, context: context, defaults: defaults, pushesProfile: false) }
        configured = client != nil
        Task { await resume() }
    }

    // MARK: auth

    private func resume() async {
        // `session` throws offline with an expired token; the stored session still says who is signed in, and the next refresh retries.
        guard let client, let user = (try? await client.auth.session)?.user ?? client.auth.currentSession?.user
        else { return }
        signedIn(user)
        await setActive(true)
    }

    private func signedIn(_ user: User) {
        switch ownerCheck(stored: defaults.string(forKey: Self.ownerKey), current: user.id) {
        case .ok: break
        case .claim: defaults.set(user.id.uuidString, forKey: Self.ownerKey)
        case .mismatch: // another account's cache: never mix it into this one
            do { try Self.wipe(ctx, defaults: defaults) } catch { Self.log.error("wipe: \(error.localizedDescription, privacy: .public)") }
            snapshot = nil; running = nil; publish()
            defaults.set(user.id.uuidString, forKey: Self.ownerKey)
        }
        state = .signedIn(email: user.email ?? ""); userID = user.id
    }
    static let ownerKey = "phoneOwnerUserID"

    /// Dirty rows the phone itself edits (tasks, points); signing out would lose them.
    func unsyncedCount() -> Int { Self.unsyncedCount(ctx) }
    static func unsyncedCount(_ ctx: ModelContext) -> Int {
        let t = ((try? ctx.fetch(FetchDescriptor<TaskItem>())) ?? []).filter(\.isDirty).count
        let p = ((try? ctx.fetch(FetchDescriptor<PointEvent>())) ?? []).filter(\.isDirty).count
        return t + p
    }

    /// Best-effort push before the sign-out confirmation; returns what is still unsynced.
    func flushForSignOut() async -> Int {
        if let engine, let userID { try? await engine.push(userID: userID) }
        return unsyncedCount()
    }

    func sendCode(email: String) async {
        guard let client else { return }
        lastError = nil
        do { try await client.auth.signInWithOTP(email: email); state = .signingIn }
        catch { lastError = error.localizedDescription }
    }

    func signInWithApple(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        guard let client else { return }
        lastError = nil
        do {
            let auth = try result.get()
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else {
                lastError = "Apple didn't return an identity token."; return
            }
            let s = try await client.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: token, nonce: nonce))
            signedIn(s.user)
            await setActive(true)
            } catch let e as ASAuthorizationError where e.code == .canceled {
        } catch { lastError = error.localizedDescription }
    }

    func cancelSignIn() { lastError = nil; state = .signedOut }

    func verify(email: String, code: String) async {
        guard let client else { return }
        lastError = nil
        do {
            let r = try await client.auth.verifyOTP(email: email, token: code, type: .email)
            signedIn(r.user)
            await setActive(true)
            } catch { lastError = error.localizedDescription }
    }

    func signOut() async {
        if let engine, let userID { try? await engine.push(userID: userID) } // before the generation bump, so the push isn't discarded
        // JWT still valid here: drop this phone's device row so the old account stops pushing to it.
        if let engine, let s = defaults.string(forKey: Self.deviceIDKey), let id = UUID(uuidString: s) { try? await engine.deleteDevice(id: id) }
        generation += 1
        debounce?.cancel(); debounce = nil
        userID = nil
        await engine?.stopRealtime()
        try? await client?.auth.signOut()
        while syncing { try? await Task.sleep(for: .milliseconds(50)) }
        do { try Self.wipe(ctx, defaults: defaults) } catch { Self.log.error("wipe: \(error.localizedDescription, privacy: .public)") }
        running = nil; snapshot = nil; lastSync = nil; lastError = nil; commandStatus = nil
        await live.reconcile(running: nil, project: nil, now: .now, force: true) // the last account's activity ends
        live.forgetActivity()
        publish()
        state = .signedOut
    }

    /// The phone's store is a cache of the account: signing out empties it, so the next account starts clean.
    static func wipe(_ ctx: ModelContext, defaults: UserDefaults) throws {
        func clear<M: PersistentModel>(_ t: M.Type) throws { try ctx.delete(model: t) }
        // Project first: batch-deleting a TaskItem while its project lives violates the mandatory inverse. The rest are swept per type.
        for t in StintSchema.models { try clear(t) }
        try ctx.save()
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("sync.watermark.") { defaults.removeObject(forKey: k) }
        for k in ["profileUpdatedAt", "displayName", "breakAllowanceMin", deviceIDKey] { defaults.removeObject(forKey: k) }
    }

    // MARK: sync

    /// Foreground: realtime on plus a refresh. Background: realtime off (spec §6.9: widgets refresh on foreground).
    func setActive(_ active: Bool) async {
        let prev = activeTask
        let t = Task { await prev?.value; await self.applyActive(active) }
        activeTask = t
        await t.value
    }

    private func applyActive(_ active: Bool) async {
        guard let engine, let userID else { return }
        if active {
            live.onTokens = { [weak self] t in Task { await self?.saveDevice(t) } }
            live.startObserving()
            await saveDevice(live.tokens) // a token that arrived before sign-in
            await engine.startRealtime(userID: userID) { [weak self] in self?.syncSoon() }
            await refresh()
        } else {
            await engine.stopRealtime()
        }
    }

    /// This phone's stable `device.id`.
    private var deviceID: UUID {
        if let s = defaults.string(forKey: Self.deviceIDKey), let id = UUID(uuidString: s) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: Self.deviceIDKey); return id
    }

    private func saveDevice(_ t: LiveActivities.Tokens) async {
        guard let engine, let userID, t.pushToStart != nil || t.activity != nil else { return }
        let row = DeviceRow(id: deviceID, userID: userID, updatedAt: .now, platform: "ios",
                            pushToStartToken: t.pushToStart, activityToken: t.activity, activitySessionID: t.activitySessionID)
        do { try await engine.saveDevice(row) }
        catch { Self.log.error("device: \(error.localizedDescription, privacy: .public)") }
    }

    private func reconcileLive() async {
        let run = running
        var project: Project?
        if let pid = run?.projectID {
            project = (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == pid })))?.first
        }
        await live.reconcile(running: run, project: project, now: .now)
    }

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
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let engine, let userID else { return }
        if syncing { again = true; return }
        syncing = true; defer { syncing = false }
        let gen = generation
        repeat {
            again = false
            do {
                try await engine.push(userID: userID)
                try await engine.pull()
                let rows = try await engine.sessionTotals(since: cal.weekInterval(containing: .now).start)
                let run = try await engine.runningSession()
                guard gen == generation else { return }
                apply(week: rows, running: run, now: .now)
                lastSync = .now; lastError = nil
                publish()
                await reconcileLive()
            } catch {
                guard gen == generation else { return }
                lastError = error.localizedDescription
                Self.log.error("sync: \(error.localizedDescription, privacy: .public)")
            }
        } while again && gen == generation
    }

    /// Rebuilds `running` and `snapshot` from the server's session feed plus local projects and points.
    func apply(week rows: [SessionTotalsRow], running run: RunningSession?, now: Date) {
        running = run
        var sessions = rows.filter { $0.endedAt != nil }.map(\.summary)
        if let run { sessions.append(run.summary(at: now)) }
        let projects = (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.archivedAt == nil },
                                                                sortBy: [SortDescriptor(\.name)]))) ?? []
        let day = cal.dayInterval(containing: now)
        let start = day.start, end = day.end
        let ledger = ((try? ctx.fetch(FetchDescriptor<PointEvent>(predicate: #Predicate { $0.at >= start && $0.at < end }))) ?? [])
            .reduce(0) { $0 + $1.delta }
        let live = run.map { r -> Int in
            let t = r.totals(at: now)
            return t.focusedSec / 60 * PointRules.perFocusedMinute + t.offtaskSec / 60 * PointRules.perOfftaskMinute
        } ?? 0
        snapshot = WidgetSnapshot.build(
            projects: projects.map { .init(id: $0.id, name: $0.name, colorHex: $0.colorHex, weeklyHoursGoal: $0.weeklyHoursGoal,
                                           dailyHoursGoal: $0.dailyHoursGoal, dailyGoalDays: $0.dailyGoalDays) },
            sessions: sessions, pointsToday: ledger + live, now: now, calendar: cal)
    }

    /// Hands the snapshot to the widgets (spec §6.9: refresh on foreground and on realtime updates).
    private func publish() {
        guard let url = SnapshotStore.defaultURL else {
            if !loggedGroupMissing { Self.log.notice("App Group unavailable; widgets keep their placeholder"); loggedGroupMissing = true }
            return
        }
        do {
            if let s = snapshot { try SnapshotStore.write(s, to: url) } else { try? FileManager.default.removeItem(at: url) }
        } catch { Self.log.error("snapshot: \(error.localizedDescription, privacy: .public)") }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: commands (spec §6.3)

    func send(_ cmd: SessionCommand) async {
        guard let engine, let userID else { return }
        guard !waiting else { commandStatus = "Still waiting on your last request…"; return }
        waiting = true; defer { waiting = false }
        commandStatus = "Waiting for your Mac…"
        do {
            let id = try await engine.sendCommand(cmd, userID: userID)
            // awaitCommandOutcome ignores cancellation: a cancelled sleep returns at once, so make the poll throw
            // (it counts as pending, no network) and discard the outcome below.
            let outcome = await awaitCommandOutcome(attempts: 10, sleep: { try? await Task.sleep(for: .seconds(1)) },
                                                    poll: { try Task.checkCancellation(); return try await engine.command(id) })
            guard !Task.isCancelled else {
                // §6.3: an abandoned command must not run later. Unstructured so the delete isn't cancelled too.
                Task { try? await engine.deleteCommand(id) }
                commandStatus = nil; return
            }
            switch outcome {
            case .accepted: commandStatus = nil; syncSoon()
            case .rejected(let reason): commandStatus = reason
            case .unreachable: commandStatus = "Mac not reachable"
            }
            if outcome != .accepted { try? await engine.deleteCommand(id) }
        } catch {
            commandStatus = "Couldn't send to your Mac: \(error.localizedDescription)"
        }
    }
}
