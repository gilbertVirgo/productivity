import ActivityKit
import Foundation
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
        let sessionID = UUID(uuidString: activity.attributes.sessionID)
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self else { return }
                self.tokens.activity = data.hexString
                self.tokens.activitySessionID = sessionID
                self.onTokens?(self.tokens)
            }
        }
    }

    /// Makes the activities match the session feed: one for the running session, none otherwise.
    func reconcile(running: RunningSession?, projectName: String?, taskTitle: String?, now: Date) async {
        let all = Activity<StintActivityAttributes>.activities
        let plan = Self.plan(existing: all.map { (id: $0.id, sessionID: $0.attributes.sessionID) },
                             runningSessionID: running?.id.uuidString)
        for a in all where plan.end.contains(a.id) {
            await Self.end(a.id, ActivityContent(state: .ended(taskTitle: a.content.state.taskTitle), staleDate: nil))
        }
        guard let running else { return }
        let state = LiveSessionState.make(remainingSec: running.remainingSec(at: now), onBreak: running.onBreak,
                                          offTask: running.offTask, taskTitle: taskTitle, now: now)
        if plan.start {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attrs = StintActivityAttributes(sessionID: running.id.uuidString, projectName: projectName ?? "Stint",
                                                plannedMin: running.plannedMin)
            do {
                let a = try Activity.request(attributes: attrs, content: ActivityContent(state: state, staleDate: nil), pushType: .token)
                watch(a)
            } catch {
                print("Live Activity request failed: \(error.localizedDescription)")
            }
        } else if let a = all.first(where: { $0.attributes.sessionID == running.id.uuidString && !plan.end.contains($0.id) }),
                  a.content.state.differs(from: state) {
            await Self.update(a.id, ActivityContent(state: state, staleDate: nil))
        }
    }

    // Activity isn't Sendable: look it up again off the main actor instead of sending it.
    nonisolated private static func end(_ id: String, _ c: ActivityContent<LiveSessionState>) async {
        await Activity<StintActivityAttributes>.activities.first { $0.id == id }?.end(c, dismissalPolicy: .default)
    }
    nonisolated private static func update(_ id: String, _ c: ActivityContent<LiveSessionState>) async {
        await Activity<StintActivityAttributes>.activities.first { $0.id == id }?.update(c)
    }

    /// Pure: keep the first activity for the running session, end every other one, start one if none is kept.
    nonisolated static func plan(existing: [(id: String, sessionID: String)], runningSessionID: String?) -> (start: Bool, end: Set<String>) {
        var end = Set<String>()
        var kept = false
        for e in existing {
            if e.sessionID == runningSessionID && !kept { kept = true } else { end.insert(e.id) }
        }
        return (runningSessionID != nil && !kept, end)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
