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
        let host = NSHostingView(rootView: NudgeView().environment(app))
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
}

struct NudgeView: View {
    @Environment(AppState.self) private var app
    @State private var reason = ""

    var body: some View {
        if let n = app.nudge {
            let name = n.host ?? appName(n.bundleID)
            let left = app.engine.map { remainingText($0.remainingSec(at: app.now)) } ?? ""
            VStack(alignment: .leading, spacing: 10) {
                Text("\(name) isn't on this session's list").font(.headline)
                Text("\(app.project?.name ?? "") · \(left) left. Off-task time doesn't count toward your goal and costs \(-PointRules.perOfftaskMinute) points a minute.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(offTaskLine(elapsedSec: Int(app.now.timeIntervalSince(n.startedAt))))
                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.warn)
                TextField("What are you doing here?", text: $reason).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Back to \(app.engine?.lastOnTaskBundleID.map(appName) ?? "task")") { app.backToTask() }
                        .buttonStyle(.borderedProminent)
                    Button("It's work: allow for this session") { app.allowCurrent(reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16).frame(width: 340, alignment: .leading)
        }
    }
}
