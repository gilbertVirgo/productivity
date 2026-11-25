import SwiftUI
import Core

/// This week's focused hours per project against the weekly goal (Today screen and medium widget). iOS only.
struct WeekBars: View {
    let lines: [WidgetSnapshot.Line]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines) { l in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(l.name).lineLimit(1)
                        Spacer()
                        Text(l.weeklyGoalSec.map { "\(hours(l.weekFocusedSec)) / \(hours($0)) h" } ?? "\(hours(l.weekFocusedSec)) h")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    if let goal = l.weeklyGoalSec, goal > 0 {
                        ProgressView(value: min(1, Double(l.weekFocusedSec) / Double(goal))).tint(Color(hex: l.colorHex))
                    }
                }
            }
        }
    }
}
