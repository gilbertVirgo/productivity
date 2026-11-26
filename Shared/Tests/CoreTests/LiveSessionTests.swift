import Testing
import Foundation
@testable import Core

@Suite struct LiveSessionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func makeStates() {
        let f = LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: false, taskTitle: "Invoice", now: now)
        #expect(f.status == .focused && f.endsAt == 1_800_000_600 && f.remainingSec == 600 && f.taskTitle == "Invoice")
        #expect(f.endsDate == now.addingTimeInterval(600))
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: true, taskTitle: nil, now: now).status == .offTask)
        let b = LiveSessionState.make(remainingSec: 600, onBreak: true, offTask: true, taskTitle: nil, now: now)
        #expect(b.status == .onBreak && b.endsAt == nil && b.endsDate == nil && b.remainingSec == 600)
        let e = LiveSessionState.ended(taskTitle: "x")
        #expect(e.status == .ended && e.endsAt == nil && e.remainingSec == 0 && e.taskTitle == "x")
    }

    @Test func differsIgnoresSmallDrift() {
        let a = LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: false, taskTitle: nil, now: now)
        // Counting down while focused keeps the same end time.
        #expect(!LiveSessionState.make(remainingSec: 590, onBreak: false, offTask: false, taskTitle: nil, now: now.addingTimeInterval(10)).differs(from: a))
        // A pause pushed the end time out by a minute.
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: false, taskTitle: nil, now: now.addingTimeInterval(60)).differs(from: a))
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: true, taskTitle: nil, now: now).differs(from: a))
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: true, offTask: false, taskTitle: nil, now: now).differs(from: a))
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: false, taskTitle: "New", now: now).differs(from: a))
    }

    @Test func wireShape() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let p = LivePush(event: .start, sessionID: id,
                         attributes: LiveSessionInfo(sessionID: id.uuidString, projectName: "Northwind", plannedMin: 50),
                         contentState: .make(remainingSec: 60, onBreak: false, offTask: false, taskTitle: nil, now: now))
        let o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        #expect(Set(o.keys) == ["event", "session_id", "attributes", "content_state"])
        #expect(o["event"] as? String == "start")
        #expect(o["session_id"] as? String == id.uuidString)
        let attrs = try #require(o["attributes"] as? [String: Any])
        #expect(Set(attrs.keys) == ["sessionID", "projectName", "plannedMin"])
        let cs = try #require(o["content_state"] as? [String: Any])
        #expect(cs["status"] as? String == "focused")
        #expect(cs["endsAt"] as? Double == 1_800_000_060)
        #expect(cs["remainingSec"] as? Int == 60)
        let back = try JSONDecoder().decode(LiveSessionState.self, from: JSONSerialization.data(withJSONObject: cs))
        #expect(back == p.contentState)
        let update = LivePush(event: .update, sessionID: id, attributes: nil, contentState: .ended(taskTitle: nil))
        let u = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        #expect(u["attributes"] == nil && u["event"] as? String == "update")
    }
}
