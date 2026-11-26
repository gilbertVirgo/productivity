import Testing
import Foundation
@testable import StintData

@Suite struct ShareLinkTests {
    @Test func decodesServerRow() throws {
        let json = #"{"id":"6b0e1c9a-2f43-4c5e-9b1a-0d9f3c2e7a11","token":"\#(String(repeating: "a", count: 43))","friend_label":"Sam","created_at":"2026-11-26T10:00:00.123456+00:00"}"#
        let row = try SyncCoding.decoder.decode(ShareLinkRow.self, from: Data(json.utf8))
        #expect(row.friendLabel == "Sam" && row.token.count == 43)
    }

    @Test func urlAppendsToken() {
        let row = ShareLinkRow(id: UUID(), token: "abc_-DEF", friendLabel: "", createdAt: .now)
        #expect(row.url(base: "https://gilbertvirgo.github.io/productivity/")?.absoluteString
                == "https://gilbertvirgo.github.io/productivity/?t=abc_-DEF")
        #expect(row.url(base: "") == nil)
    }
}
