import Foundation

/// One task as `parse-tasks` returns it.
public struct ParsedTask: Codable, Equatable, Sendable {
    public var title: String
    public var projectID: UUID?
    public var estimateMin: Int?
    public var estimateGuessed: Bool
    public init(title: String, projectID: UUID?, estimateMin: Int?, estimateGuessed: Bool) {
        self.title = title; self.projectID = projectID; self.estimateMin = estimateMin; self.estimateGuessed = estimateGuessed
    }
    enum CodingKeys: String, CodingKey {
        case title, projectID = "project_id", estimateMin = "estimate_min", estimateGuessed = "estimate_guessed"
    }
}

/// A row on the confirm screen.
public struct DraftTask: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var projectID: UUID?
    public var estimateMin: Int?
    public var estimateGuessed: Bool
    public var checked: Bool
    public init(title: String, projectID: UUID?, estimateMin: Int?, estimateGuessed: Bool, checked: Bool = true) {
        id = UUID(); self.title = title; self.projectID = projectID
        self.estimateMin = estimateMin; self.estimateGuessed = estimateGuessed; self.checked = checked
    }
}

/// Spec §6.8: voice → confirm → save.
public enum VoiceTasks {
    public static let maxTranscript = 4000 // Unicode scalars; parse-tasks counts the same way
    public enum TranscriptError: Error, Equatable { case empty, tooLong }

    public static func check(_ s: String) -> Result<String, TranscriptError> {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .failure(.empty) }
        if t.unicodeScalars.count > maxTranscript { return .failure(.tooLong) }
        return .success(t)
    }

    /// Projects the phone or Mac doesn't know become "Choose project".
    public static func drafts(_ parsed: [ParsedTask], projectIDs: Set<UUID>) -> [DraftTask] {
        parsed.compactMap { p in
            let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return DraftTask(title: title, projectID: p.projectID.flatMap { projectIDs.contains($0) ? $0 : nil },
                             estimateMin: p.estimateMin, estimateGuessed: p.estimateMin != nil && p.estimateGuessed)
        }
    }

    /// Network/AI failure: the transcript becomes one editable task.
    public static func fallback(_ transcript: String) -> [DraftTask] {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return [DraftTask(title: String(t.prefix(200)), projectID: nil, estimateMin: nil, estimateGuessed: false)]
    }

    public static func checkedCount(_ drafts: [DraftTask]) -> Int { drafts.filter(\.checked).count }

    public static func canSave(_ drafts: [DraftTask]) -> Bool {
        let checked = drafts.filter(\.checked)
        return !checked.isEmpty && checked.allSatisfy {
            $0.projectID != nil && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
