import Foundation

/// The Desk widget's link (spec 2026-11-26 §7.1).
enum DeskLink {
    static let url = URL(string: "stint://desk")!
    static func matches(_ url: URL) -> Bool { url.scheme == "stint" && url.host() == "desk" }
}
