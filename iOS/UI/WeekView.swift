import SwiftUI
import SwiftData
import StintData

struct WeekView: View {
    @Environment(PhoneSync.self) private var sync
    @Query(sort: \GoalResultRecord.periodStart, order: .reverse) private var results: [GoalResultRecord]
    @Query private var allProjects: [Project]

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty { Text("Goal results appear after each day and week closes.").foregroundStyle(.secondary) }
                ForEach(goalHistory(results)) { w in
                    Section("Week of \(w.weekStart.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))") {
                        ForEach(w.results) { r in GoalLine(result: r, name: allProjects.first { $0.id == r.projectID }?.name ?? "Project") }
                    }
                }
            }
            .navigationTitle("Week")
            .refreshable { await sync.refresh() }
        }
    }
}

struct GoalLine: View {
    let result: GoalResultRecord
    let name: String
    var body: some View {
        let hours = result.goalKind == "hours"
        let when = result.period == "week" ? "week" : result.periodStart.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.abbreviated))
        HStack {
            Image(systemName: result.met ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(result.met ? Color.green : Color.secondary)
            Text("\(name) · \(when) \(result.goalKind)")
            Spacer()
            Text(String(format: "%g / %g", result.actual, result.target) + (hours ? " h" : ""))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
