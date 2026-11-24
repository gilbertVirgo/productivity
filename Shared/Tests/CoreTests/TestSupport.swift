import Foundation

/// Parse an ISO-8601 timestamp with offset, e.g. "2026-11-24T16:52:00Z" or "2026-11-24T10:30:00+11:00".
func date(_ iso: String) -> Date {
    guard let d = ISO8601DateFormatter().date(from: iso) else { fatalError("bad test date \(iso)") }
    return d
}
