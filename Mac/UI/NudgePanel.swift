import AppKit
import SwiftUI
import Core

func offTaskLine(elapsedSec: Int) -> String {
    let s = max(0, elapsedSec)
    return "Off task so far \(remainingText(s)) · −\(s / 60 * -PointRules.perOfftaskMinute) pts"
}

func appName(_ bundleID: String) -> String {
    if let n = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName { return n }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: url.path)
    }
    return bundleID
}

@MainActor
final class NudgePanelController {
    private var panel: NSPanel?
    private let content: (AppState) -> AnyView

    init(content: @escaping (AppState) -> AnyView) { self.content = content }

    func show(_ app: AppState) {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 10),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content(app))
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let f = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - p.frame.height - 16))
        }
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
    }

    func hide() { panel?.close(); panel = nil }

    func refit() { if let p = panel, let v = p.contentView { p.setContentSize(v.fittingSize) } }
}

struct NudgeView: View {
    @Environment(AppState.self) private var app
    @State private var reason = ""

    var body: some View {
        if let n = app.nudge {
            let name = n.host ?? appName(n.bundleID)
            VStack(alignment: .leading, spacing: 10) {
                Text("\(name) isn't on \(app.project?.name ?? "this project")'s list").font(.headline)
                Text("Off-task time doesn't count toward your goal and costs \(-PointRules.perOfftaskMinute) points a minute.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(offTaskLine(elapsedSec: Int(app.now.timeIntervalSince(n.startedAt))))
                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.warn)
                TextField("What are you doing here?", text: $reason).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Back to \(app.tracker.engine?.lastOnTaskBundleID.map(appName) ?? "work")") { app.backToTask() }
                        .buttonStyle(.borderedProminent)
                    Button("It's work: allow for \(app.project?.menuTitle ?? "this project")") { app.allowCurrent(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16).frame(width: 340, alignment: .leading)
        }
    }
}

/// "Looks like Freelance — switch?" (spec 2026-11-26 §5.4; mockup "Mac · suggested switch").
struct SuggestView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if let s = app.suggestion, let to = app.findProject(s.projectID) {
                let here = app.project?.menuTitle ?? "this project"
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        ProjectIcon(name: to.name, colorHex: to.colorHex, icon: to.icon, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Looks like \(to.name)").font(.headline)
                            Text("\(s.host ?? appName(s.bundleID)) is on \(to.name)'s list. You're tracking \(app.project?.name ?? "another project").")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Switch from \(s.since.formatted(date: .omitted, time: .shortened))") { app.acceptSuggestion() }
                            .buttonStyle(.borderedProminent).tint(Color(hex: to.colorHex))
                        Button("Stay on \(here)") { app.staySuggestion() }
                    }
                    Text("Ignore it and the time stays on \(here) as off-task.").font(.caption).foregroundStyle(.secondary)
                }
            } else if let u = app.undo, let to = app.project {
                HStack {
                    Text("Switched to \(to.name) · counted from \(u.since.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Button("Undo") { app.undoSwitch() }
                }
            }
        }
        .padding(16).frame(width: 340, alignment: .leading)
    }
}
