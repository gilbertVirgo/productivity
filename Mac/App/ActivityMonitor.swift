import AppKit
import Core

@MainActor
final class ActivityMonitor {
    private let onFront: (String, String?) -> Void
    private let onIdle: (Bool) -> Void
    private let onSleep: (Bool) -> Void
    private let onAutomationDenied: () -> Void
    private var tokens: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastFront: String?
    private var lastHost: String?
    private var idle = false

    init(onFront: @escaping (String, String?) -> Void, onIdle: @escaping (Bool) -> Void,
         onSleep: @escaping (Bool) -> Void, onAutomationDenied: @escaping () -> Void) {
        self.onFront = onFront; self.onIdle = onIdle; self.onSleep = onSleep; self.onAutomationDenied = onAutomationDenied
    }

    func start() {
        stop()
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in if let id { self?.report(id, force: true) } }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onSleep(true) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onSleep(false) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        timer?.invalidate(); timer = nil
        lastFront = nil; lastHost = nil; idle = false
    }

    /// Report the current frontmost app regardless of change (used at session start).
    func reportCurrent() {
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { report(id, force: true) }
    }

    private func poll() {
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Browsers.supported.contains(id.lowercased()) {
            report(id, force: false)
        }
        let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let nowIdle = secs >= 300
        if nowIdle != idle { idle = nowIdle; onIdle(nowIdle) }
    }

    private func report(_ id: String, force: Bool) {
        var host: String?
        if Browsers.supported.contains(id.lowercased()) {
            switch BrowserHost.host(for: id) {
            case .success(let h): host = h
            case .failure: onAutomationDenied()
            }
        }
        guard force || id != lastFront || host != lastHost else { return }
        lastFront = id; lastHost = host
        onFront(id, host)
    }
}
