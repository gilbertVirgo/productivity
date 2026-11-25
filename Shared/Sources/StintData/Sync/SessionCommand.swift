import Foundation

public enum SessionCommand: Equatable, Sendable {
    case start(projectID: UUID, plannedMin: Int, firstTaskID: UUID?)
    case takeBreak, resume
    case endEarly(reason: String)

    public static func parse(_ row: SessionCommandRow) -> SessionCommand? {
        let p = row.payload
        switch row.kind {
        case "start":
            guard let pid = p["project_id"].flatMap(UUID.init(uuidString:)),
                  let min = p["planned_min"].flatMap(Int.init), min > 0 else { return nil }
            var first: UUID? = nil
            if let s = p["first_task_id"] { guard let t = UUID(uuidString: s) else { return nil }; first = t }
            return .start(projectID: pid, plannedMin: min, firstTaskID: first)
        case "break": return .takeBreak
        case "resume": return .resume
        case "end_early_request":
            guard let r = p["reason"]?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
            return .endEarly(reason: r)
        default: return nil
        }
    }
}

public extension SessionCommand {
    /// Wire form for a `session_command` row; `parse` is its inverse.
    var wire: (kind: String, payload: [String: String]) {
        switch self {
        case let .start(projectID, plannedMin, firstTaskID):
            var p = ["project_id": projectID.uuidString, "planned_min": String(plannedMin)]
            if let firstTaskID { p["first_task_id"] = firstTaskID.uuidString }
            return ("start", p)
        case .takeBreak: return ("break", [:])
        case .resume: return ("resume", [:])
        case let .endEarly(reason): return ("end_early_request", ["reason": reason])
        }
    }
}

public enum CommandOutcome: Equatable, Sendable { case accepted, rejected(String), unreachable }

/// Spec §6.3: polls the sent row until the Mac deletes it (accepted) or marks it rejected; gives up after
/// `attempts` polls (15 × 1 s, outlasting the Mac's 10 s acceptance cutoff). A poll that throws (network) counts as still pending.
@MainActor
public func awaitCommandOutcome(attempts: Int = 15, sleep: () async -> Void,
                                poll: () async throws -> SessionCommandRow?) async -> CommandOutcome {
    for _ in 0..<attempts {
        await sleep()
        do {
            guard let row = try await poll() else { return .accepted }
            if let reason = row.rejectedReason { return .rejected(reason) }
        } catch { continue }
    }
    return .unreachable
}

public enum OwnerCheck: Sendable { case claim, ok, mismatch }
/// Local ids belong to the first account that synced on this device; another account's RLS would reject every push.
public func ownerCheck(stored: String?, current: UUID) -> OwnerCheck {
    guard let stored else { return .claim }
    return stored == current.uuidString ? .ok : .mismatch
}
