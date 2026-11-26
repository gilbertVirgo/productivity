import SwiftUI
import SwiftData
import Core
import StintData

/// Live Dictate (design 2026-11-26): speak, and task rows appear each time you pause.
/// After Stop the rows are editable in place and "Add N tasks" saves them.
struct DictateView: View {
    let onSaved: @MainActor (Int) -> Void

    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @State private var model: DictateModel

    init(parse: @escaping @MainActor (String, [Project]) async throws -> [ParsedTask], onSaved: @escaping @MainActor (Int) -> Void) {
        self.onSaved = onSaved
        _model = State(initialValue: DictateModel(parse: parse))
    }

    var body: some View {
        VStack(spacing: 0) {
            rowsArea
            notes
            if model.phase == .typing { typingBox } else { caption }
            bottomBar
        }
        .onAppear { model.projects = projects }
        .onChange(of: projects) { _, new in model.projects = new }
        .onDisappear { model.disappear() }
    }

    // MARK: rows

    @ViewBuilder private var rowsArea: some View {
        if model.rows.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Text(model.phase == .listening ? "Listening…" : "Say what you need to do. Name the project if you can.")
                    .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if model.sorting { ProgressView() }
                Spacer()
            }
            .frame(maxWidth: .infinity).padding()
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach($model.rows) { $d in
                        Group {
                            if model.phase == .review { editableRow($d) } else { liveRow(d) }
                        }
                        .id(d.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if model.sorting {
                        Label("Sorting…", systemImage: "sparkles").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .animation(.default, value: model.rows.map(\.id))
                .onChange(of: model.rows.count) { _, _ in
                    if let last = model.rows.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
    }

    private func liveRow(_ d: DraftTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(d.title).font(.body)
            HStack(spacing: 8) {
                if let p = projects.first(where: { $0.id == d.projectID }) {
                    let c = Color(hex: p.colorHex)
                    Text(p.name).font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(c.opacity(0.15), in: Capsule()).foregroundStyle(c)
                } else {
                    Text("Choose project").font(.caption).foregroundStyle(Theme.warn)
                }
                if let m = d.estimateMin {
                    Text("~\(m) min").font(.caption).foregroundStyle(.secondary).opacity(d.estimateGuessed ? 0.6 : 1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func editableRow(_ d: Binding<DraftTask>) -> some View {
        HStack(alignment: .top) {
            Button { d.wrappedValue.checked.toggle() } label: {
                Image(systemName: d.wrappedValue.checked ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(d.wrappedValue.checked ? Theme.accent : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(d.wrappedValue.checked ? "Included" : "Left out")
            VStack(alignment: .leading, spacing: 6) {
                TextField("Task", text: d.title)
                Picker("Project", selection: d.projectID) {
                    Text("Choose project").tag(UUID?.none)
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .foregroundStyle(d.wrappedValue.projectID == nil && d.wrappedValue.checked ? Theme.warn : .primary)
                HStack {
                    TextField("Minutes", value: Binding(
                        get: { d.wrappedValue.estimateMin },
                        set: { d.wrappedValue.estimateMin = $0.flatMap { $0 > 0 ? $0 : nil }; d.wrappedValue.estimateGuessed = false }
                    ), format: .number)
                    .frame(maxWidth: 80)
                    Text("min").foregroundStyle(.secondary)
                    if d.wrappedValue.estimateGuessed { Text("guessed").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .opacity(d.wrappedValue.checked ? 1 : 0.5)
        }
    }

    // MARK: notes, caption, typing

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = model.message { Text(message).foregroundStyle(Theme.warn) }
            if case let .unavailable(why) = model.speech.mode { Text(why).foregroundStyle(Theme.warn) }
            if model.edited { Text("Recording again will re-sort your tasks.").foregroundStyle(.secondary) }
            if model.phase == .review && projects.isEmpty {
                Text("Add a project first, then add these tasks.").foregroundStyle(Theme.warn)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    @ViewBuilder private var caption: some View {
        if !model.transcript.isEmpty {
            HStack(alignment: .top) {
                Text(model.transcript)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.phase == .review { Button("Start over") { model.startOver() }.font(.callout) }
            }
            .padding(.horizontal).padding(.top, 8)
        }
    }

    private var typingBox: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $model.transcript)
                .frame(minHeight: 100, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .disabled(model.sorting)
            Button("Make tasks") { model.makeTasks() }
                .buttonStyle(.bordered)
                .disabled(model.sorting || model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal).padding(.top, 8)
    }

    // MARK: bottom bar

    private var bottomBar: some View {
        let n = VoiceTasks.checkedCount(model.rows)
        let busy = model.phase == .listening || model.phase == .finishing
        return ZStack {
            if model.phase != .typing {
                ListeningOrb(phase: model.phase, speech: model.speech) {
                    if model.phase == .listening { model.stop() } else { Task { await model.record() } }
                }
            }
            HStack {
                Button { model.toggleTyping() } label: {
                    Image(systemName: model.phase == .typing ? "mic" : "keyboard").font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(busy)
                .accessibilityLabel(model.phase == .typing ? "Dictate instead" : "Type instead")
                Spacer()
                if !model.rows.isEmpty {
                    Button(n == 1 ? "Add 1 task" : "Add \(n) tasks") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.phase != .review || model.sorting || !VoiceTasks.canSave(model.rows))
                }
            }
        }
        .frame(minHeight: 64)
        .padding()
    }

    private func save() {
        do { onSaved(try model.save(in: ctx)) } catch { model.message = "Couldn't save: \(error.localizedDescription)" }
    }
}

/// Mic button that pulses with the speaker's loudness. Reads `speech.level` in its own body so only
/// the orb redraws as the level changes.
private struct ListeningOrb: View {
    let phase: DictateModel.Phase
    let speech: SpeechCapture
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = phase == .listening
        let l = CGFloat(live ? speech.level : 0)
        VStack(spacing: 4) {
            Button(action: action) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(live ? 0.2 : 0.1))
                        .frame(width: 64, height: 64)
                        .scaleEffect(reduceMotion ? 1 : 1 + l * 0.6)
                        .opacity(reduceMotion ? 0.4 + Double(l) * 0.6 : 1)
                    Circle().fill(Theme.accent).frame(width: 56, height: 56)
                    if phase == .finishing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: live ? "stop.fill" : "mic.fill").font(.title2).foregroundStyle(.white)
                    }
                }
                .frame(width: 104, height: 104)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.12), value: l)
            }
            .buttonStyle(.plain)
            .disabled(phase == .finishing)
            .accessibilityLabel(live ? "Stop recording" : phase == .review ? "Record more" : "Record")
            Text(live ? "Listening" : phase == .finishing ? "Sorting…" : phase == .review ? "Record more" : "Tap to talk")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
