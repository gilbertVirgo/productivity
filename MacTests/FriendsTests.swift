import Foundation
import Testing
import StintData
@testable import Stint

@MainActor @Suite struct FriendsTests {
    @Test func shareBaseReadsInfoAndIgnoresUnexpanded() {
        #expect(SyncCoordinator.shareBase(info: ["StintShareURL": "http://127.0.0.1:8787/"]) == "http://127.0.0.1:8787/")
        #expect(SyncCoordinator.shareBase(info: ["StintShareURL": "$(STINT_SHARE_URL)"]) == "")
        #expect(SyncCoordinator.shareBase(info: nil) == "")
    }
}
