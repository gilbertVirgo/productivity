import StintData
import SwiftUI
import SwiftData
import Core

struct MenuBarLabel: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if let p = app.project {
            if app.tracker.onBreak {
                Text("Break \(app.todayStats().breakLeftSec / 60)m").monospacedDigit()
            } else {
                HStack(spacing: 4) {
                    Image(systemName: p.icon ?? "circle.fill")
                    Text("\(p.menuTitle) \(hoursMinutes(app.focusedToday(p.id)))").monospacedDigit()
                }
            }
        } else {
            Image(systemName: "timer")
        }
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]

    var body: some View {
        let stats = app.todayStats()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WORKING ON").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Today \(hoursMinutes(stats.focusedSec)) · \(stats.points >= 0 ? "+" : "")\(stats.points) pts")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if projects.isEmpty {
                Text("Add a project in Stint to start tracking.").foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(Array(projects.prefix(9).enumerated()), id: \.element.id) { i, p in
                    ProjectRowButton(project: p, number: i + 1)
                }
            }
            if app.nudge != nil {
                HStack {
                    Text("Off task").foregroundStyle(Theme.warn).bold()
                    Spacer()
                    Button("Back to work") { app.backToTask() }
                }
                .padding(8).background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if app.automationDenied {
                Text("Site checks are off — allow Stint to control Safari/Chrome in System Settings › Privacy & Security › Automation")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            Divider()
            HStack {
                Button { app.tracker.onBreak ? app.resume() : app.takeBreak() } label: {
                    VStack(spacing: 1) {
                        Text(app.tracker.onBreak ? "Resume" : "Break").bold()
                        Text("\(stats.breakLeftSec / 60) min left today").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
                Button(role: .destructive) { app.stop() } label: { Text("Stop").bold().frame(maxWidth: .infinity) }
            }
            .controlSize(.large)
            .disabled(!app.isTracking)
            HStack {
                Text(app.hotkeyUnavailable ? "Hotkey unavailable" : "Switch anywhere: ⌃⌥Space").foregroundStyle(.secondary)
                Spacer()
                Button("Open Stint") { NSApp.activate(); openWindow(id: "main") }.buttonStyle(.link)
                Button("Quit") { app.stop(); NSApplication.shared.terminate(nil) }.buttonStyle(.link)
            }.font(.caption)
        }
        .padding(14).frame(width: 340)
        .onAppear { app.now = Date() }
    }
}

/// One project row: a click switches to it (spec §6.2). Number keys 1–9 work while the panel is open.
private struct ProjectRowButton: View {
    @Environment(AppState.self) private var app
    let project: Project
    let number: Int

    var body: some View {
        let on = app.tracker.currentID == project.id
        let tint = Color(hex: project.colorHex)
        Button { app.switchTo(project) } label: {
            HStack(spacing: 12) {
                ProjectIcon(name: project.name, colorHex: project.colorHex, icon: project.icon, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.callout.weight(.semibold))
                    if on { Text("Tracking now").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(hoursMinutes(app.focusedToday(project.id))).monospacedDigit().fontWeight(on ? .bold : .regular)
                Text("\(number)").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
            }
            .padding(.horizontal, 10).frame(minHeight: 48)
            .background(on ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? tint : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
        .accessibilityLabel("\(project.name), \(hoursMinutes(app.focusedToday(project.id))) today\(on ? ", tracking now" : "")")
    }
}
