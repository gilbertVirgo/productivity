import ActivityKit
import Foundation
import OSLog
import Core
import StintData

/// Live Activity on the phone (spec §6.9):
/// - uploads push tokens so `push-activity` can start, update and end it from the Mac;
/// - while the app is in the foreground, also starts, updates and ends it from the realtime session feed.
@MainActor
final class LiveActivities {
    struct Tokens: Equatable { var pushToStart: String?; var activity: String?; var activitySessionID: UUID? }
    private(set) var tokens = Tokens()
    var onTokens: ((Tokens) -> Void)?
    /// Sign-out: the next account must not upload this activity's token. A new device id is minted for it anyway.
    func forgetActivity() { tokens.activity = nil; tokens.activitySessionID = nil }
    private var observing = false
    private var watched: Set<String> = []
    private static let log = Logger(subsystem: "dev.stint.ios", category: "live")
    /// First time this phone saw each activity: a young one may have been push-started before its session row arrived.
    private var firstSeen: [String: Date] = [:]
    private var activityTokens: [String: (token: String, sessionID: UUID?)] = [:]
    private var keptID: String?
    private static let youngSec: TimeInterval = 120

    func startObserving() {
        guard !observing else { return }
        observing = true
        Task { [weak self] in
            for await data in Activity<StintActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                self.tokens.pushToStart = data.hexString
                self.onTokens?(self.tokens)
            }
        }
        Task { [weak self] in
            for await activity in Activity<StintActivityAttributes>.activityUpdates { self?.watch(activity) }
        }
        for activity in Activity<StintActivityAttributes>.activities { watch(activity) }
    }

    private func watch(_ activity: Activity<StintActivityAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        firstSeen[activity.id] = firstSeen[activity.id] ?? Date()
        let sessionID = UUID(uuidString: activity.attributes.sessionID)
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self else { return }
                self.activityTokens[activity.id] = (data.hexString, sessionID)
                self.selectToken(arrived: activity.id)
            }
        }
    }

    /// Uploads the kept activity's token (or, before any reconcile, the one that just arrived).
    private func selectToken(arrived: String? = nil) {
        guard let id = keptID ?? arrived, let t = activityTokens[id] else { return }
        var next = tokens
        next.activity = t.token; next.activitySessionID = t.sessionID
        guard next != tokens else { return }
        tokens = next
        onTokens?(tokens)
    }

    /// Makes the activities match the session feed: one for the running session, none otherwise.
    /// `force` also ends young activities (sign-out).
    func reconcile(running: RunningSession?, project: Project?, now: Date, force: Bool = false) async {
        let all = Activity<StintActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        for a in all { firstSeen[a.id] = firstSeen[a.id] ?? now }
        let plan = Self.plan(existing: all.map { (id: $0.id, young: now.timeIntervalSince(firstSeen[$0.id] ?? now) < Self.youngSec) },
                             running: running != nil, force: force)
        for a in all where plan.end.contains(a.id) {
            await Self.end(a.id, ActivityContent(state: .ended(projectName: a.content.state.projectName, colorHex: a.content.state.colorHex,
                                                                 icon: a.content.state.icon, focusedSec: a.content.state.focusedSec), staleDate: nil))
            activityTokens[a.id] = nil; firstSeen[a.id] = nil
            if keptID == a.id { keptID = nil }
        }
        if let k = plan.keep { keptID = k }
        defer { selectToken() }
        guard let running else { return }
        let state = LiveSessionState.make(projectName: project?.name ?? "Stint", colorHex: project?.colorHex ?? "#8E8E93",
                                          icon: project?.icon, focusedSec: running.totals(at: now).focusedSec,
                                          onBreak: running.onBreak, offTask: running.offTask, paused: running.paused, now: now)
        if plan.start {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attrs = StintActivityAttributes(sessionID: running.id.uuidString)
            do {
                let a = try Activity.request(attributes: attrs, content: ActivityContent(state: state, staleDate: nil), pushType: .token)
                firstSeen[a.id] = now
                keptID = a.id
                watch(a)
            } catch {
                Self.log.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            }
        } else if let k = plan.keep, let a = all.first(where: { $0.id == k }), a.content.state.differs(from: state) {
            await Self.update(a.id, ActivityContent(state: state, staleDate: nil))
        }
    }

    // Activity isn't Sendable: look it up again off the main actor instead of sending it.
    nonisolated private static func end(_ id: String, _ c: ActivityContent<LiveSessionState>) async {
        await Activity<StintActivityAttributes>.activities.first { $0.id == id }?.end(c, dismissalPolicy: .after(.now.addingTimeInterval(300)))
    }
    nonisolated private static func update(_ id: String, _ c: ActivityContent<LiveSessionState>) async {
        await Activity<StintActivityAttributes>.activities.first { $0.id == id }?.update(c)
    }

    /// Pure: one activity per tracking run. Keep the first; end every other one except young ones (unless `force`);
    /// start one if tracking and none is kept. A young activity may have been push-started before its row arrived.
    nonisolated static func plan(existing: [(id: String, young: Bool)], running: Bool,
                                 force: Bool = false) -> (start: Bool, end: Set<String>, keep: String?) {
        let keep = running ? existing.first?.id : nil
        let end = Set(existing.filter { $0.id != keep && (force || !$0.young) }.map(\.id))
        return (running && keep == nil, end, keep)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
