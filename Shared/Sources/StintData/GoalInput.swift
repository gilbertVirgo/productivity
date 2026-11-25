import Foundation
import SwiftData
import os

/// Parsing for goal text fields: empty = no goal, positive number = goal, anything else is rejected.
public enum GoalInput: Equatable {
    case empty
    case value(Double)
    case invalid(String)

    public static func parse(_ text: String, wholeNumber: Bool = false) -> GoalInput {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return .empty }
        guard let v = Double(t), v.isFinite else { return .invalid("Enter a number") }
        if v <= 0 { return .invalid("Must be more than 0") }
        if wholeNumber && v != v.rounded() { return .invalid("Enter a whole number") }
        return .value(v)
    }
}

/// Tasks whose `doneAt` falls inside `interval`.
public func tasksDone(_ doneDates: [Date?], in interval: DateInterval) -> Int {
    doneDates.filter { d in d.map { $0 >= interval.start && $0 < interval.end } ?? false }.count
}

public extension ModelContext {
    func saveLogged() {
        do { try save() } catch { Logger(subsystem: "dev.stint", category: "ui").error("save: \(error)") }
    }
}
