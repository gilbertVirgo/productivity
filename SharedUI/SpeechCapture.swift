import Foundation
import Speech
import AVFoundation
import Observation

/// On-device dictation. `unavailable` means: show the typed field instead (spec §6.8).
@MainActor @Observable
final class SpeechCapture {
    enum Mode: Equatable { case idle, recording, finishing, unavailable(String) }
    var mode: Mode = .idle
    var transcript = ""
    /// Editing, recording and parsing are allowed only when no take is in flight.
    var canEdit: Bool { if case .idle = mode { true } else if case .unavailable = mode { true } else { false } }

    @ObservationIgnored private var audio: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var take = 0
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var abandoned = false

    func start() async {
        guard !starting, mode != .recording, mode != .finishing else { return }
        abandoned = false
        starting = true; defer { starting = false }
        guard await Self.speechAllowed(), await Self.micAllowed() else {
            guard !abandoned else { abandoned = false; return }
            mode = .unavailable("Dictation is off for Stint. Type your tasks instead, or allow Microphone and Speech Recognition in Settings.")
            return
        }
        guard !abandoned else { abandoned = false; return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            mode = .unavailable("On-device dictation isn't available here. Type your tasks instead.")
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateSession()
            mode = .unavailable("No microphone available. Type your tasks instead.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(req))
        do { engine.prepare(); try engine.start() } catch {
            input.removeTap(onBus: 0)
            req.endAudio()
            deactivateSession()
            mode = .unavailable("Couldn't use the microphone. Type your tasks instead.")
            return
        }
        audio = engine
        let base = transcript.isEmpty ? "" : transcript + " " // keep what was there before this take
        request = req
        mode = .recording
        take += 1
        let myTake = take
        task = recognizer.recognitionTask(with: req, resultHandler: Self.handler { [weak self] text, done in
            guard let self, myTake == self.take else { return }
            if let text { self.transcript = base + text }
            if done { self.finish() }
        })
    }

    /// Stops the mic and waits (up to 2s) for the recognizer's final result before going idle.
    func stop() {
        if starting { abandoned = true }
        guard mode == .recording else { return }
        stopAudio()
        request?.endAudio()
        mode = .finishing
        let myTake = take
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if let self, self.take == myTake, self.mode == .finishing { self.finish() }
        }
    }

    /// Hard stop for onDisappear: nothing may land after this.
    func cancel() {
        if starting { abandoned = true }
        guard mode == .recording || mode == .finishing else { return }
        stopAudio()
        take += 1 // drop any late callbacks
        finish()
    }

    private func stopAudio() {
        audio?.stop()
        audio?.inputNode.removeTap(onBus: 0)
        audio = nil
    }

    private func finish() {
        task?.cancel()
        task = nil; request = nil
        mode = .idle
        deactivateSession()
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: off-main callbacks

    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func handler(_ update: @escaping @MainActor (String?, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in update(text, done) }
        }
    }

    nonisolated private static func speechAllowed() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    nonisolated private static func micAllowed() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
