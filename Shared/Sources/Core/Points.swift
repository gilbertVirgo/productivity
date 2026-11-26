import Foundation

/// Point values (spec 6.7). Tune here; plan 2's SQL period-close job mirrors the goal values.
public enum PointRules {
    public static let perFocusedMinute = 1
    public static let sessionComplete = 10
    public static let dailyGoalMet = 20
    public static let weeklyGoalMet = 100
    public static let perOfftaskMinute = -2
    public static let perOverBreakMinute = -1
}

public enum PointKind: String, Codable, Sendable {
    case focus, offtask, redeem
    case sessionComplete = "session_complete"
    case dailyGoal = "daily_goal"
    case weeklyGoal = "weekly_goal"
    case breakOver = "break_over"
}

public struct PointLine: Equatable, Sendable {
    public var kind: PointKind
    public var delta: Int

    public init(kind: PointKind, delta: Int) {
        self.kind = kind
        self.delta = delta
    }
}

/// Seconds of this session's break that fall beyond today's allowance.
public func breakOverAllowance(usedEarlierSec: Int, sessionBreakSec: Int, allowanceSec: Int) -> Int {
    max(0, sessionBreakSec - max(0, allowanceSec - usedEarlierSec))
}

/// Ledger lines written when a session ends. Partial minutes round down; zero lines are omitted.
public func sessionPoints(totals: SessionTotals, completed: Bool, breakOverSec: Int) -> [PointLine] {
    let candidates: [PointLine] = [
        PointLine(kind: .focus, delta: totals.focusedSec / 60 * PointRules.perFocusedMinute),
        PointLine(kind: .sessionComplete, delta: completed ? PointRules.sessionComplete : 0),
        PointLine(kind: .offtask, delta: totals.offtaskSec / 60 * PointRules.perOfftaskMinute),
        PointLine(kind: .breakOver, delta: breakOverSec / 60 * PointRules.perOverBreakMinute),
    ]
    return candidates.filter { $0.delta != 0 }
}

public func canRedeem(cost: Int, balance: Int) -> Bool {
    cost <= balance
}

/// Ledger lines that bring today's focus, off-task and over-break points up to date (spec 2026-11-26 §4).
/// `today` sums all of today's stretches, including the one just closed. `written` is what today's ledger already
/// holds per kind. Rounding happens on the day total, so short stretches lose nothing.
public func dayPoints(today: SessionTotals, allowanceSec: Int, written: [PointKind: Int]) -> [PointLine] {
    let targets: [(PointKind, Int)] = [
        (.focus, today.focusedSec / 60 * PointRules.perFocusedMinute),
        (.offtask, today.offtaskSec / 60 * PointRules.perOfftaskMinute),
        (.breakOver, max(0, today.breakSec - allowanceSec) / 60 * PointRules.perOverBreakMinute),
    ]
    return targets.map { PointLine(kind: $0.0, delta: $0.1 - (written[$0.0] ?? 0)) }.filter { $0.delta != 0 }
}
