import WidgetKit
import SwiftUI
import Core

struct Entry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot? }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) { completion(load()) }
    /// Spec §6.9: otherwise refresh via the timeline every 15 min. The app reloads timelines after each sync.
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
    private func load() -> Entry {
        let now = Date.now
        let s = SnapshotStore.defaultURL.flatMap(SnapshotStore.read(from:))
        return Entry(date: now, snapshot: s?.asOf(now, calendar: PeriodCalendar(timeZone: .current)))
    }
}

private struct OpenStint: View {
    var body: some View { Text("Open Stint to sign in").font(.caption).foregroundStyle(.secondary) }
}

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "week", provider: Provider()) { e in
            Group {
                if let s = e.snapshot {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This week").font(.caption.bold())
                        WeekBars(lines: Array(s.lines.prefix(4)))
                        Spacer(minLength: 0)
                    }
                } else { OpenStint() }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("This week")
        .description("Hours per project against your weekly goals.")
        .supportedFamilies([.systemMedium])
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: Provider()) { e in
            Group {
                if let s = e.snapshot {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today").font(.caption.bold())
                        Text("\(hours(s.todayFocusedSec)) h").font(.title.bold()).monospacedDigit()
                        Text(s.todayGoalSec > 0 ? "of \(hours(s.todayGoalSec)) h goal" : "no daily goal today")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text("\(s.pointsToday) pts today").font(.caption.bold())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else { OpenStint() }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Focused time against today's goals, and points.")
        .supportedFamilies([.systemSmall])
    }
}

struct StartWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "start", provider: Provider()) { e in
            Group {
                if let s = e.snapshot, let id = s.startProjectID, let l = s.lines.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Furthest behind").font(.caption).foregroundStyle(.secondary)
                        Text(l.name).font(.headline).lineLimit(2)
                        Spacer(minLength: 0)
                        Label("Start \(StartLink.plannedMin) min", systemImage: "play.fill").font(.caption.bold())
                            .foregroundStyle(Color(hex: l.colorHex))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetURL(StartLink.url(projectID: id))
                } else if e.snapshot != nil {
                    Text("Daily goals done").font(.headline)
                } else { OpenStint() }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Start")
        .description("Starts a 50 min Mac session on the project furthest behind today.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct StintWidgets: WidgetBundle {
    var body: some Widget { WeekWidget(); TodayWidget(); StartWidget() }
}
