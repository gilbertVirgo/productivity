import Foundation
import Core

/// The widgets' only data: one JSON file in the App Group container, written by the app after each refresh.
enum SnapshotStore {
    static let appGroup = "group.dev.stint"

    /// nil when the App Group container isn't available (entitlement not granted).
    static var defaultURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "widget-snapshot.json")
    }

    static func write(_ s: WidgetSnapshot, to url: URL) throws { try JSONEncoder().encode(s).write(to: url, options: .atomic) }

    static func read(from url: URL) -> WidgetSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }
}
