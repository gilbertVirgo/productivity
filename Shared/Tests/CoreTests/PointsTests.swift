import Testing
@testable import Core

@Suite struct PointsTests {
    @Test func earlyEndKeepsFocusMinutesOnly() {
        let lines = sessionPoints(totals: SessionTotals(focusedSec: 32 * 60 + 14), completed: false, breakOverSec: 0)
        #expect(lines == [PointLine(kind: .focus, delta: 32)])
    }

    @Test func completedSessionGetsBonus() {
        let lines = sessionPoints(totals: SessionTotals(focusedSec: 3000), completed: true, breakOverSec: 0)
        #expect(lines == [PointLine(kind: .focus, delta: 50), PointLine(kind: .sessionComplete, delta: 10)])
    }

    @Test func offTaskAndOverBreakCost() {
        let lines = sessionPoints(totals: SessionTotals(focusedSec: 2820, offtaskSec: 3 * 60 + 59),
                                  completed: true, breakOverSec: 12 * 60)
        #expect(lines == [
            PointLine(kind: .focus, delta: 47),
            PointLine(kind: .sessionComplete, delta: 10),
            PointLine(kind: .offtask, delta: -6),
            PointLine(kind: .breakOver, delta: -12),
        ])
    }

    @Test func breakAllowance() {
        let hour = 3600
        #expect(breakOverAllowance(usedEarlierSec: 0, sessionBreakSec: 22 * 60, allowanceSec: hour) == 0)
        #expect(breakOverAllowance(usedEarlierSec: 50 * 60, sessionBreakSec: 22 * 60, allowanceSec: hour) == 12 * 60)
        #expect(breakOverAllowance(usedEarlierSec: 70 * 60, sessionBreakSec: 22 * 60, allowanceSec: hour) == 22 * 60)
    }

    @Test func redeemGuard() {
        #expect(canRedeem(cost: 150, balance: 1240))
        #expect(!canRedeem(cost: 2000, balance: 1240))
        #expect(!canRedeem(cost: 150, balance: -20))
    }
}
