import Testing
import Foundation
import SwiftData
import Core
@testable import StintData

@MainActor @Suite struct VoiceSaveTests {
    @Test func savesCheckedDraftsAsVoiceTasksAtTheEnd() throws {
        let container = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let p = Project(name: "Northwind"); ctx.insert(p)
        let old = TaskItem(title: "Old", sort: 4); ctx.insert(old); old.project = p
        try ctx.save()

        var drafts = [
            DraftTask(title: " Send invoice ", projectID: p.id, estimateMin: 15, estimateGuessed: true),
            DraftTask(title: "Skip me", projectID: p.id, estimateMin: nil, estimateGuessed: false),
            DraftTask(title: "Call bank", projectID: p.id, estimateMin: nil, estimateGuessed: true),
        ]
        drafts[1].checked = false
        #expect(try VoiceSave.save(drafts, projects: [p], in: ctx) == 2)

        let new = p.tasks.filter { $0.source == "voice" }.sorted { $0.sort < $1.sort }
        #expect(new.map(\.title) == ["Send invoice", "Call bank"])
        #expect(new.map(\.sort) == [5, 6])
        #expect(new[0].estimateMin == 15 && new[0].estimateGuessed)
        #expect(new[1].estimateMin == nil && !new[1].estimateGuessed) // no estimate → not "guessed"
        #expect(new.allSatisfy { $0.syncedAt == nil })               // dirty, so it syncs
        _ = container
    }

    @Test func skipsDraftsWhoseProjectIsGone() throws {
        let container = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        #expect(try VoiceSave.save([DraftTask(title: "A", projectID: UUID(), estimateMin: nil, estimateGuessed: false)],
                                   projects: [], in: ctx) == 0)
        _ = container
    }
}
