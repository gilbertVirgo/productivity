import Testing
import Foundation
@testable import StintData

@Suite struct SyncFieldsTests {
    @Test func isDirtyTracksSyncedAt() {
        let t = Treat(name: "Coffee", cost: 5)
        #expect(t.syncedAt == nil)
        #expect(t.isDirty)
        t.syncedAt = t.updatedAt
        #expect(!t.isDirty)
        t.updatedAt = t.updatedAt.addingTimeInterval(1)
        #expect(t.isDirty)
    }
}
