/// Picks which `parse-tasks` answer to show while dictating: each request gets a number, only the newest
/// is shown, and the same text isn't sent twice in a row (unless forced, e.g. the final sort on Stop).
public struct ParseGate: Sendable {
    private var sent = 0
    private var lastText: String?
    public init() {}

    public mutating func begin(_ text: String, force: Bool = false) -> Int? {
        guard force || text != lastText else { return nil }
        lastText = text; sent += 1
        return sent
    }

    public func isLatest(_ n: Int) -> Bool { n == sent }

    /// A failed newest request lets the same text be sent again.
    public mutating func failed(_ n: Int) { if n == sent { lastText = nil } }
}
