import Foundation

public enum SessionCommand: Equatable, Sendable {
    case switchTo(projectID: UUID)
    case stop
    case breakStart, breakEnd
    /// A kind from a phone that predates switch-first tracking; the Mac rejects it.
    case legacy

    public static func parse(_ row: SessionCommandRow) -> SessionCommand? {
        switch row.kind {
        case "switch": return row.payload["project_id"].flatMap(UUID.init(uuidString:)).map { .switchTo(projectID: $0) }
        case "stop": return .stop
        case "break_start": return .breakStart
        case "break_end": return .breakEnd
        case "start", "break", "resume", "end_early_request": return .legacy
        default: return nil
        }
    }
}

public extension SessionCommand {
    /// Wire form for a `session_command` row; `parse` is its inverse. `.legacy` is never sent.
    var wire: (kind: String, payload: [String: String]) {
        switch self {
        case let .switchTo(id): return ("switch", ["project_id": id.uuidString])
        case .stop: return ("stop", [:])
        case .breakStart: return ("break_start", [:])
        case .breakEnd: return ("break_end", [:])
        case .legacy: return ("start", [:])
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
