import SwiftUI
import SwiftData
import Core

struct MenuBarLabel: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if app.isRunning { Text(app.remainingText).monospacedDigit() } else { Image(systemName: "timer") }
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var endSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = app.engine, let p = app.project { running(e, p) } else { idle }
            Divider()
            Button("Open Stint") { NSApp.activate(); openWindow(id: "main") }.buttonStyle(.plain)
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
        }
        .padding(14).frame(width: 300)
        .onChange(of: app.isRunning) { _, running in if !running { endSheet = false } }
        .sheet(isPresented: $endSheet) {
            EndEarlySheet(onEnd: { app.endEarly(reason: $0); endSheet = false }, onCancel: { endSheet = false })
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = app.lastResult {
                Text(r.completed ? "Session complete · \(r.points >= 0 ? "+" : "")\(r.points) points"
                                 : "Session ended · \(r.points >= 0 ? "+" : "")\(r.points) points").font(.callout)
            }
            Text("Start session").font(.headline)
            StartSessionControls()
        }
    }

    private func running(_ e: SessionEngine, _ p: Project) -> some View {
        let total = Double(e.plannedMin * 60)
        let stats = app.todayStats()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: p.colorHex)).frame(width: 9, height: 9)
                Text(p.name).font(.headline)
                Spacer()
                Text("\(e.plannedMin) min session").font(.caption).foregroundStyle(.secondary)
            }
            Text(app.remainingText).font(.system(size: 44, weight: .semibold).monospacedDigit())
            ProgressView(value: min(total, total - Double(e.remainingSec(at: app.now))), total: total)
            if let t = app.firstTask {
                Text("Working on").font(.caption).foregroundStyle(.secondary)
                Text(t.title)
            }
            FlowChips(items: e.allowlist.entries.map(\.value).sorted())
            HStack {
                stat("Focused", "\(stats.focusedSec / 60)m")
                stat("Break left", "\(stats.breakLeftSec / 60)m")
                stat("Points", "\(stats.points)")
            }
            if app.nudge != nil {
                HStack {
                    Text("Off task").foregroundStyle(Theme.warn).bold()
                    Spacer()
                    Button("Back to task") { app.backToTask() }
                }
                .padding(8).background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if app.automationDenied {
                Text("Site checks are off — allow Stint to control Safari/Chrome in System Settings › Privacy & Security › Automation")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            HStack {
                Button(e.onBreak ? "Resume" : "Take a break") { e.onBreak ? app.resume() : app.takeBreak() }
                Button("End early…") { endSheet = true }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.callout.monospacedDigit()).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlowChips: View {
    let items: [String]
    var body: some View {
        Text(items.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }
}
