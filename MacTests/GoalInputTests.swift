import Testing
import Foundation
@testable import Stint

@Suite struct GoalInputTests {
    @Test func parsing() {
        #expect(GoalInput.parse("  ") == .empty)
        #expect(GoalInput.parse("2.5") == .value(2.5))
        #expect(GoalInput.parse("2,5") == .value(2.5))
        #expect(GoalInput.parse("0") == .invalid("Must be more than 0"))
        #expect(GoalInput.parse("-3") == .invalid("Must be more than 0"))
        #expect(GoalInput.parse("abc") == .invalid("Enter a number"))
        #expect(GoalInput.parse("inf") == .invalid("Enter a number"))
        #expect(GoalInput.parse("2.5", wholeNumber: true) == .invalid("Enter a whole number"))
        #expect(GoalInput.parse("4", wholeNumber: true) == .value(4))
    }

    @Test func doneCounting() {
        let day = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 100)
        let dates: [Date?] = [nil, Date(timeIntervalSince1970: 1000), Date(timeIntervalSince1970: 1099),
                              Date(timeIntervalSince1970: 1100), Date(timeIntervalSince1970: 999)]
        #expect(tasksDone(dates, in: day) == 2)
    }
}
