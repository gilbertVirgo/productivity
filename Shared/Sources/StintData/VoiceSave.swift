import Foundation
import SwiftData
import Core

@MainActor
public enum VoiceSave {
    /// Saves checked drafts as `source = "voice"` tasks at the end of each project's list. Returns how many were saved.
    public static func save(_ drafts: [DraftTask], projects: [Project], in ctx: ModelContext) throws -> Int {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [UUID: Int] = [:]
        var saved = 0
        for d in drafts where d.checked {
            let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let pid = d.projectID, let p = byID[pid] else { continue }
            let sort = next[pid] ?? ((p.tasks.map(\.sort).max() ?? -1) + 1)
            next[pid] = sort + 1
            let t = TaskItem(title: title, estimateMin: d.estimateMin, estimateGuessed: d.estimateMin != nil && d.estimateGuessed,
                             source: "voice", sort: sort)
            ctx.insert(t)
            t.project = p
            saved += 1
        }
        try ctx.save()
        return saved
    }
}
