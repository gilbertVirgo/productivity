import SwiftUI
import SwiftData
import Core
import StintData

/// Spec §6.8: record or type → Make tasks → confirm → "Add N tasks".
struct DictateView: View {
    let parse: @MainActor (String, [Project]) async throws -> [ParsedTask]
    let onSaved: @MainActor (Int) -> Void

    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @State private var speech = SpeechCapture()
    @State private var drafts: [DraftTask]?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Group {
            if let drafts { confirm(drafts) } else { capture }
        }
        .onDisappear { speech.stop() }
    }

    // MARK: capture

    private var capture: some View {
        @Bindable var speech = speech
        return VStack(alignment: .leading, spacing: 12) {
            Text("Say what you need to do. Name the project if you can.").foregroundStyle(.secondary)
            TextEditor(text: $speech.transcript)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .disabled(speech.mode == .recording)
            if case let .unavailable(why) = speech.mode { Text(why).font(.footnote).foregroundStyle(Theme.warn) }
            if let message { Text(message).font(.footnote).foregroundStyle(Theme.warn) }
            HStack {
                if speech.mode == .recording {
                    Button("Stop", systemImage: "stop.circle.fill") { speech.stop() }
                } else if !isUnavailable {
                    Button("Record", systemImage: "mic.circle.fill") { Task { await speech.start() } }
                }
                Spacer()
                Button("Make tasks") { Task { await makeTasks() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || speech.mode == .recording || speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if working { ProgressView("Sorting your tasks…") }
        }
        .padding()
    }

    private var isUnavailable: Bool { if case .unavailable = speech.mode { true } else { false } }

    private func makeTasks() async {
        message = nil
        switch VoiceTasks.check(speech.transcript) {
        case .failure(.tooLong):
            message = "That's over \(VoiceTasks.maxTranscript) characters. Shorten it and try again."
        case .failure(.empty):
            break
        case let .success(text):
            working = true; defer { working = false }
            do {
                let parsed = try await parse(text, projects)
                let d = VoiceTasks.drafts(parsed, projectIDs: Set(projects.map(\.id)))
                if d.isEmpty { drafts = VoiceTasks.fallback(text); message = "No separate tasks found. Edit the one below." }
                else { drafts = d }
            } catch {
                drafts = VoiceTasks.fallback(text)
                message = "Couldn't sort this automatically. Edit the task below."
            }
        }
    }

    // MARK: confirm

    private func confirm(_ current: [DraftTask]) -> some View {
        let binding = Binding(get: { drafts ?? [] }, set: { drafts = $0 })
        let n = VoiceTasks.checkedCount(current)
        return VStack(spacing: 0) {
            if let message { Text(message).font(.footnote).foregroundStyle(Theme.warn).padding(.top) }
            List {
                ForEach(binding) { $d in row($d) }
            }
            HStack {
                Button("Back") { drafts = nil; message = nil }
                Spacer()
                Button(n == 1 ? "Add 1 task" : "Add \(n) tasks") { save(current) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!VoiceTasks.canSave(current))
            }
            .padding()
        }
    }

    private func row(_ d: Binding<DraftTask>) -> some View {
        HStack(alignment: .top) {
            Toggle("", isOn: d.checked).labelsHidden()
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

    private func save(_ current: [DraftTask]) {
        do {
            let n = try VoiceSave.save(current, projects: projects, in: ctx)
            drafts = nil; message = nil; speech.transcript = ""
            onSaved(n)
        } catch { message = "Couldn't save: \(error.localizedDescription)" }
    }
}
