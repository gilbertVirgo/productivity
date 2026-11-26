import ActivityKit
import WidgetKit
import SwiftUI
import Core

struct LiveSessionWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StintActivityAttributes.self) { ctx in
            LockScreen(state: ctx.state).padding()
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(ctx.state.projectName).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.trailing) { Clock(state: ctx.state).font(.title3) }
                DynamicIslandExpandedRegion(.bottom) { Status(state: ctx.state) }
            } compactLeading: {
                Image(systemName: symbol(ctx.state.status)).foregroundStyle(statusTint(ctx.state.status))
            } compactTrailing: {
                Clock(state: ctx.state).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: symbol(ctx.state.status)).foregroundStyle(statusTint(ctx.state.status))
            }
        }
    }
}

private struct LockScreen: View {
    let state: LiveSessionState
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: state.icon ?? "circle.fill").foregroundStyle(Color(hex: state.colorHex))
                    Text(state.projectName).font(.headline).lineLimit(1)
                }
                Status(state: state)
            }
            Spacer()
            Clock(state: state).font(.system(size: 34, weight: .semibold))
        }
    }
}

/// Counts up from the stretch start without pushes. Stopped (break, paused, off task): a still focused-time number.
private struct Clock: View {
    let state: LiveSessionState
    var body: some View {
        Group {
            if let from = state.countFromDate {
                Text(from, style: .timer)
            } else if state.status == .ended {
                Image(systemName: "checkmark.circle.fill")
            } else {
                Text(remainingText(state.focusedSec))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

private struct Status: View {
    let state: LiveSessionState
    var body: some View {
        Text(label(state.status)).font(.caption.weight(.semibold)).foregroundStyle(statusTint(state.status))
    }
}

private func label(_ s: LiveSessionState.Status) -> String {
    switch s {
    case .focused: "Focused"
    case .offTask: "Off task"
    case .onBreak: "On break"
    case .paused: "Paused"
    case .ended: "Stopped"
    }
}

private func symbol(_ s: LiveSessionState.Status) -> String {
    switch s {
    case .focused: "timer"
    case .offTask: "exclamationmark.circle"
    case .onBreak: "cup.and.saucer"
    case .paused: "pause.circle"
    case .ended: "checkmark.circle"
    }
}

private func statusTint(_ s: LiveSessionState.Status) -> Color { s == .offTask ? Theme.warn : .accentColor }
