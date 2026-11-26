#if canImport(ActivityKit)
import ActivityKit
import Core

/// The type name is part of the APNs push-to-start payload ("attributes-type"); don't rename it.
/// Property names must match `LiveSessionInfo` (LiveActivityTests checks this).
struct StintActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveSessionState
    var sessionID: String
}
#endif
