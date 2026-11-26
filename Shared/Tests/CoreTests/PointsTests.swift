import Testing
@testable import Core

@Suite struct PointsTests {
    @Test func redeemGuard() {
        #expect(canRedeem(cost: 150, balance: 1240))
        #expect(!canRedeem(cost: 2000, balance: 1240))
        #expect(!canRedeem(cost: 150, balance: -20))
    }

    @Test func rawValuesMatchDatabase() {
        let expected: [PointKind: String] = [
            .focus: "focus", .sessionComplete: "session_complete", .dailyGoal: "daily_goal",
            .weeklyGoal: "weekly_goal", .offtask: "offtask", .breakOver: "break_over", .redeem: "redeem",
        ]
        #expect(expected.count == 7)
        for (k, v) in expected { #expect(k.rawValue == v) }
    }

    @Test func thirtyShortStretchesScoreLikeOneLongOne() {
        var written: [PointKind: Int] = [:]
        var today = SessionTotals()
        var total = 0
        for _ in 0..<30 {
            today = today + SessionTotals(focusedSec: 90)
            for l in dayPoints(today: today, allowanceSec: 3600, written: written) {
                written[l.kind, default: 0] += l.delta; total += l.delta
            }
        }
        #expect(total == 45)
        #expect(dayPoints(today: SessionTotals(focusedSec: 2700), allowanceSec: 3600, written: [:]) == [PointLine(kind: .focus, delta: 45)])
    }

    @Test func dayPointsPenaltiesAndNoRepeats() {
        let t = SessionTotals(focusedSec: 600, offtaskSec: 150, breakSec: 3725)
        let lines = dayPoints(today: t, allowanceSec: 3600, written: [:])
        #expect(lines == [PointLine(kind: .focus, delta: 10), PointLine(kind: .offtask, delta: -4), PointLine(kind: .breakOver, delta: -2)])
        #expect(dayPoints(today: t, allowanceSec: 3600, written: [.focus: 10, .offtask: -4, .breakOver: -2]).isEmpty)
    }
}
