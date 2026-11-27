import SwiftUI
import SwiftData
import UIKit
import Core
import StintData

/// Phone-on-a-stand switch panel (spec 2026-11-26 §7.1; mockup "iPhone · Desk mode").
/// Taps send commands; nothing changes here until the Mac acts and its row syncs back.
struct DeskView: View {
    @Environment(PhoneSync.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @Query private var tasks: [TaskItem]
    @State private var sending: String?
    @State private var shake: String?

    var body: some View {
        let running = sync.running
        let lines = sync.snapshot?.lines ?? []
        let board = sync.board(tasks)
        GeometryReader { geo in
            let columns = geo.size.width > geo.size.height ? 3 : 2
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(running, projects: projects, lines: lines)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(board.active) { t in
                            card(t, on: t.id == board.current?.id)
                        }
                        tile(key: "break", on: running?.onBreak == true, color: .gray,
                             title: running?.onBreak == true ? "On break" : "Break", sub: "Pause the current project") {
                            symbol("cup.and.saucer")
                        } action: { running?.onBreak == true ? .breakEnd : .breakStart }
                        .disabled(running == nil)
                        tile(key: "stop", on: running == nil, color: Color(red: 1, green: 0.54, blue: 0.5),
                             title: running == nil ? "Stopped" : "Stop", sub: running == nil ? "Tap a project to start" : "Done for now") {
                            symbol("stop.fill")
                        } action: { .stop }
                    }
                    if board.active.isEmpty {
                        Text("Active cards show here. Tap a card on the board to make it active.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let s = sync.commandStatus, sending == nil { Text(s).font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(24)
            }
        }
        .background(Color(red: 0.055, green: 0.059, blue: 0.071).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) { Button("Done") { dismiss() }.padding() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func header(_ running: RunningSession?, projects: [Project], lines: [WidgetSnapshot.Line]) -> some View {
        let p = projects.first { $0.id == running?.projectID }
        let now = HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(running == nil ? "NOT TRACKING" : running!.onBreak ? "PAUSED" : "WORKING ON")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
            Text(p?.name ?? "Nothing").font(.title2.bold()).lineLimit(1)
            if let running {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    Text(remainingText(running.totals(at: tl.date).focusedSec)).font(.title2.bold().monospacedDigit())
                        .foregroundStyle(Color(hex: p?.colorHex ?? "#A1A1AA"))
                }.fixedSize()
            }
        }
        let status = HStack(spacing: 12) {
            Text("Today \(hoursMinutes(sync.snapshot?.todayFocusedSec ?? 0)) · \(sync.snapshot?.pointsToday ?? 0) pts")
            Label(running.map { $0.isStale(at: .now) } == true ? "Mac quiet" : "Mac connected", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .font(.footnote).foregroundStyle(.secondary).fixedSize()
        // Landscape: one row. Portrait: two.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) { now.fixedSize(); Spacer(); status }
            VStack(alignment: .leading, spacing: 6) { now; status }
        }
        .padding(.trailing, 60) // clear of Done
    }

    /// An Active card: tap runs the board's tap flow (current card, switch if needed).
    private func card(_ t: TaskItem, on: Bool) -> some View {
        let color = Color(hex: t.project?.colorHex ?? "#8E8E93")
        return Button { sync.tap(t) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(t.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    ProjectChip(project: t.project, size: 24)
                    Spacer()
                    if on { Text("Now").font(.subheadline.weight(.semibold)) }
                }
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(on ? color.opacity(0.35) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(on ? color : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sync.waiting)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 26, weight: .semibold)).frame(width: 52, height: 52)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tile<Icon: View>(key: String, on: Bool, color: Color, title: String, sub: String,
                                  @ViewBuilder icon: () -> Icon, action: @escaping () -> SessionCommand) -> some View {
        Button {
            guard sending == nil else { return }
            sending = key
            Task {
                await sync.send(action())
                if sync.commandStatus != nil { shake = nil; shake = key }
                sending = nil
            }
        } label: {
            HStack(spacing: 14) {
                icon()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(sub).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if sending == key { ProgressView() }
            }
            .padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(on ? color.opacity(0.35) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(on ? color : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .phaseAnimator([0, 8, -8, 0], trigger: shake == key) { v, x in v.offset(x: x) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
