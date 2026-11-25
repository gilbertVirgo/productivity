import Foundation
import Speech
import AVFoundation
import Observation

/// On-device dictation. `unavailable` means: show the typed field instead (spec §6.8).
@MainActor @Observable
final class SpeechCapture {
    enum Mode: Equatable { case idle, recording, unavailable(String) }
    var mode: Mode = .idle
    var transcript = ""

    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func start() async {
        guard mode != .recording else { return }
        guard await Self.speechAllowed(), await Self.micAllowed() else {
            mode = .unavailable("Dictation is off for Stint. Type your tasks instead, or allow Microphone and Speech Recognition in Settings.")
            return
        }
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
        let input = audio.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(req))
        do { audio.prepare(); try audio.start() } catch {
            input.removeTap(onBus: 0)
            mode = .unavailable("Couldn't use the microphone. Type your tasks instead.")
            return
        }
        let base = transcript.isEmpty ? "" : transcript + " " // keep what was there before this take
        request = req
        mode = .recording
        task = recognizer.recognitionTask(with: req, resultHandler: Self.handler { [weak self] text, done in
            guard let self else { return }
            if let text { self.transcript = base + text }
            if done { self.stop() }
        })
    }

    func stop() {
        guard mode == .recording else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil; task = nil
        mode = .idle
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
