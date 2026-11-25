import SwiftUI

struct EndEarlySheet: View {
    let onEnd: (String) -> Void
    let onCancel: () -> Void
    @State private var start = Date()
    @State private var reason = ""

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { ctx in
            let left = max(0, 60 - Int(ctx.date.timeIntervalSince(start)))
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 6)
                    Circle().trim(from: 0, to: Double(60 - left) / 60)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(left)").font(.title2.monospacedDigit())
                }
                .frame(width: 72, height: 72)
                Text("Why end early?").font(.headline)
                TextField("Reason (required)", text: $reason, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                Text("Keep your minutes · lose the +10 finish bonus").font(.caption).foregroundStyle(.secondary)
                Button("Keep working", action: onCancel).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button(left > 0 ? "End session in \(remainingText(left))" : "End session") { onEnd(reason) }
                    .disabled(left > 0 || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20).frame(width: 280)
        }
    }
}
