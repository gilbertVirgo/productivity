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
