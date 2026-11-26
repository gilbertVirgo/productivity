import Foundation

/// Spec 2026-11-26 §5.4: when the app or site in front belongs to exactly one other project, suggest switching to it
/// once it has been in front for `dwell` seconds. Pure: the caller feeds observations and clock ticks.
public struct SwitchSuggester: Sendable {
    public struct Candidate: Sendable {
        public var id: UUID
        public var allowlist: Allowlist
        public init(id: UUID, allowlist: Allowlist) { self.id = id; self.allowlist = allowlist }
    }

    public struct Suggestion: Equatable, Sendable {
        public var projectID: UUID
        /// When the app came to the front. An accepted switch is backdated to here.
        public var since: Date
        public var bundleID: String
        public var host: String?
    }

    let dwell: TimeInterval
    public private(set) var pending: Suggestion?
    var fired = false
    var muted: Set<String> = []

    public init(dwell: TimeInterval = 10) { self.dwell = dwell }

    /// Projects that own what's in front. A domain match beats an app match; apps nobody lists have no owner.
    public static func owners(bundleID: String, host: String?, among projects: [Candidate]) -> [UUID] {
        if Browsers.supported.contains(bundleID.lowercased()), let host {
            let byDomain = projects.filter { $0.allowlist.listsDomain(of: host) }.map(\.id)
            if !byDomain.isEmpty { return byDomain }
        }
        return projects.filter { $0.allowlist.listsApp(bundleID) }.map(\.id)
    }

    /// Call when the app or tab in front changes. Returns a suggestion only once it is due.
    public mutating func observe(bundleID: String, host: String?, current: UUID?, projects: [Candidate], at now: Date) -> Suggestion? {
        let owners = Self.owners(bundleID: bundleID, host: host, among: projects)
        guard owners.count == 1, let owner = owners.first, owner != current,
              !muted.contains(Self.key(bundleID: bundleID, host: host)) else {
            pending = nil; fired = false
            return nil
        }
        if let p = pending, p.projectID == owner, p.bundleID == bundleID, p.host == host { return tick(at: now) }
        pending = Suggestion(projectID: owner, since: now, bundleID: bundleID, host: host)
        fired = false
        return tick(at: now)
    }

    public mutating func tick(at now: Date) -> Suggestion? {
        guard let p = pending, !fired, now.timeIntervalSince(p.since) >= dwell else { return nil }
        fired = true
        return p
    }

    /// "Stay on X": don't suggest for this app or site again until `reset()`.
    public mutating func mute(_ s: Suggestion) {
        muted.insert(Self.key(bundleID: s.bundleID, host: s.host))
        pending = nil
    }

    /// A new stretch began: forget mutes and anything pending.
    public mutating func reset() { muted = []; pending = nil; fired = false }

    static func key(bundleID: String, host: String?) -> String {
        if Browsers.supported.contains(bundleID.lowercased()), let host { return "domain:" + host.lowercased() }
        return "app:" + bundleID.lowercased()
    }
}
