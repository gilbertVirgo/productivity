import Foundation

/// Start widget → app: `stint://start?project=<uuid>`. The app sends a 50 min start (spec §6.9) and shows the outcome.
enum StartLink {
    static let plannedMin = 50

    static func url(projectID: UUID) -> URL { URL(string: "stint://start?project=\(projectID.uuidString)")! }

    static func parse(_ url: URL) -> UUID? {
        guard url.scheme == "stint", url.host() == "start",
              let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "project" })?.value
        else { return nil }
        return UUID(uuidString: v)
    }
}
