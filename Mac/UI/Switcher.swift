import AppKit
import SwiftUI
import StintData
import Core

enum Switcher {
    enum Press: Equatable { case open, close, flipBack }

    /// The previous project first (Return flips back), then the rest by name.
    static func order(_ projects: [Project], current: UUID?, previous: UUID?) -> [Project] {
        let sorted = projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let previous, previous != current, let p = sorted.first(where: { $0.id == previous }) else { return sorted }
        return [p] + sorted.filter { $0.id != previous }
    }

    static func filter(_ projects: [Project], query: String) -> [Project] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.shortName ?? "").localizedCaseInsensitiveContains(q) }
    }

    /// A second press within 0.4 s of the first, while the panel is open, flips back to the previous project.
    static func pressAction(sinceLast: TimeInterval?, isOpen: Bool) -> Press {
        guard isOpen else { return .open }
        if let s = sinceLast, s < 0.4 { return .flipBack }
        return .close
    }
}

/// A panel that can take typing without activating Stint.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SwitcherController {
    private var panel: NSPanel?
    private var lastPress: Date?
    private var resignObserver: NSObjectProtocol?

    func hotkeyPressed(_ app: AppState) {
        let now = Date()
        let action = Switcher.pressAction(sinceLast: lastPress.map { now.timeIntervalSince($0) }, isOpen: panel != nil)
        lastPress = now
        switch action {
        case .open: show(app)
        case .close: hide()
        case .flipBack: hide(); app.switchToPrevious()
        }
    }

    private func show(_ app: AppState) {
        let rows = Switcher.order(app.activeProjects, current: app.tracker.currentID, previous: app.tracker.previousID)
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 10),
                         styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true; p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: SwitcherView(projects: rows, close: { [weak self] in self?.hide() }).environment(app))
        p.contentView = host
        p.setContentSize(host.fittingSize)
        p.center()
        p.makeKeyAndOrderFront(nil)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        panel = p
    }

    func hide() {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        panel?.close(); panel = nil
    }
}

/// Spotlight-style switcher (mockup "Mac · ⌃⌥Space switcher"). 1–9 or Return switches, ⌘S stops, ⌘B breaks, Esc closes.
struct SwitcherView: View {
    @Environment(AppState.self) private var app
    let projects: [Project]
    let close: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let rows = Array(Switcher.filter(projects, query: query).prefix(9))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                TextField("Switch to…", text: $query)
                    .textFieldStyle(.plain).font(.title2).focused($focused)
                    .onSubmit { pick(rows.first) }
                    .onKeyPress(characters: .decimalDigits) { press in
                        guard let n = Int(press.characters), n >= 1, n <= rows.count else { return .ignored }
                        pick(rows[n - 1]); return .handled
                    }
                    .onExitCommand(perform: close)
                Text("On: \(app.project?.name ?? "nothing")").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, p in row(i, p) }
            }.padding(8)
            Divider()
            HStack(spacing: 16) {
                hint("1–\(max(1, rows.count))", "switch")
                hint("⌃⌥Space", "again: back to \(app.previousProject?.name ?? "previous")")
                hint("⌘S", "stop"); hint("⌘B", "break"); hint("esc", "cancel")
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 520)
        .background {
            Button("Stop") { app.stop(); close() }.keyboardShortcut("s", modifiers: .command).hidden()
            Button("Break") { app.tracker.onBreak ? app.resume() : app.takeBreak(); close() }
                .keyboardShortcut("b", modifiers: .command).hidden()
        }
        .onAppear { DispatchQueue.main.async { focused = true } } // the non-activating panel isn't key yet
    }

    private func row(_ i: Int, _ p: Project) -> some View {
        let first = i == 0
        let tag = p.id == app.tracker.currentID ? "current" : p.id == app.tracker.previousID ? "previous" : ""
        return Button { pick(p) } label: {
            HStack(spacing: 14) {
                Text("\(i + 1)").font(.callout.weight(.bold)).monospacedDigit().frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(first ? .white.opacity(0.7) : .secondary, lineWidth: 1.5))
                ProjectIcon(name: p.name, colorHex: p.colorHex, icon: p.icon, size: 34)
                Text(p.name).font(.body.weight(.semibold))
                Spacer()
                Text(tag).font(.caption).opacity(0.85)
                Text(hoursMinutes(app.focusedToday(p.id))).monospacedDigit()
            }
            .padding(.horizontal, 12).frame(minHeight: 52)
            .foregroundStyle(first ? .white : .primary)
            .background(first ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) { Text(key).bold().foregroundStyle(.primary); Text(label) }
    }

    private func pick(_ p: Project?) {
        if let p { app.switchTo(p) }
        close()
    }
}
