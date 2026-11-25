import Testing
import Foundation
@testable import StintData

@Suite struct SyncIDsTests {
    let sid = UUID()

    @Test func deterministicAndDistinct() {
        #expect(SyncIDs.derived(sid, "event", 0) == SyncIDs.derived(sid, "event", 0))
        #expect(SyncIDs.derived(sid, "event", 0) != SyncIDs.derived(sid, "event", 1))
        #expect(SyncIDs.derived(sid, "event", 0) != SyncIDs.derived(sid, "allow", 0))
    }

    @Test func versionAndVariant() {
        for i in 0..<20 {
            let s = SyncIDs.derived(sid, "event", i).uuidString
            let chars = Array(s)
            #expect(chars[14] == "5")
            #expect("89AB".contains(chars[19]))
        }
    }
}
