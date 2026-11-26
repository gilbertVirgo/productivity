import Testing
import Foundation
@testable import StintData

@Suite struct DeviceRowTests {
    @Test func encodesSnakeCaseWithExplicitNulls() throws {
        let id = UUID(), uid = UUID()
        let row = DeviceRow(id: id, userID: uid, updatedAt: Date(timeIntervalSince1970: 0), platform: "ios",
                            pushToStartToken: "aa11", activityToken: nil, activitySessionID: nil)
        let o = try #require(try JSONSerialization.jsonObject(with: SyncCoding.encoder.encode(row)) as? [String: Any])
        #expect(Set(o.keys) == ["id", "user_id", "updated_at", "platform", "push_to_start_token", "activity_token", "activity_session_id"])
        #expect(o["platform"] as? String == "ios" && o["push_to_start_token"] as? String == "aa11")
        #expect(o["activity_token"] is NSNull && o["activity_session_id"] is NSNull) // clearing reaches the server
    }
}
