import Foundation

public enum AllowKind: String, Codable, Sendable {
    case app, domain
}

/// One on-task rule: an app bundle ID or a website domain. Values are stored lowercased.
public struct AllowEntry: Hashable, Codable, Sendable {
    public var kind: AllowKind
    public var value: String

    public init(_ kind: AllowKind, _ value: String) {
        self.kind = kind
        self.value = value.lowercased()
    }
}

public enum Browsers {
    public static let safari = "com.apple.safari"
    public static let chrome = "com.google.chrome"
    /// Browsers whose active-tab URL the Mac app can read via AppleScript.
    public static let supported: Set<String> = [safari, chrome]
}

public struct Allowlist: Sendable {
    public var entries: Set<AllowEntry>
    private let alwaysAllowed: Set<String>
    /// Extra always-on-task bundle IDs that the host app can change at runtime (stored lowercased).
    public var extraAllowed: Set<String>

    static let systemAlwaysAllowed: Set<String> = ["com.apple.loginwindow", "com.apple.screensaver.engine"]

    public init(entries: [AllowEntry], ownBundleID: String, extraAllowed: Set<String> = []) {
        self.entries = Set(entries)
        self.alwaysAllowed = Self.systemAlwaysAllowed
            .union([ownBundleID.lowercased()])
        self.extraAllowed = Set(extraAllowed.map { $0.lowercased() })
    }

    /// - Parameters:
    ///   - bundleID: the frontmost app.
    ///   - host: the active tab's host when `bundleID` is a supported browser and it could be read; otherwise nil.
    public func isOnTask(bundleID: String, host: String?) -> Bool {
        let id = bundleID.lowercased()
        if alwaysAllowed.contains(id) || extraAllowed.contains(id) || entries.contains(AllowEntry(.app, id)) { return true }
        guard Browsers.supported.contains(id) else { return false }
        let domains = entries.filter { $0.kind == .domain }.map(\.value)
        guard let host = host?.lowercased() else { return !domains.isEmpty } // spec 6.4: benefit of the doubt
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
