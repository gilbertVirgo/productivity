import Foundation
import Speech
import AVFoundation
import Observation
import Core

/// On-device dictation. `unavailable` means: show the typed field instead (spec §6.8).
@MainActor @Observable
final class SpeechCapture {
    enum Mode: Equatable { case idle, recording, finishing, unavailable(String) }
    var mode: Mode = .idle
    /// Mic loudness, 0…1, for the listening orb.
    var level: Float = 0
    /// The take's transcript so far (text from before the take, then everything heard).
    @ObservationIgnored var onText: ((String) -> Void)?
    /// The take ended by Stop, the recognizer finishing, or the Stop timeout. Not called after `cancel()`.
    @ObservationIgnored var onEnded: (() -> Void)?

    @ObservationIgnored private var audio: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var take = 0
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var abandoned = false

    func start(base: String) async {
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(req) { [weak self] v in
            Task { @MainActor in self?.level = v }
        })
        do { engine.prepare(); try engine.start() } catch {
            input.removeTap(onBus: 0)
            req.endAudio()
            deactivateSession()
            mode = .unavailable("Couldn't use the microphone. Type your tasks instead.")
            return
        }
        audio = engine
        var text = TranscriptAccumulator(base: base) // keep what was there before this take
        request = req
        mode = .recording
        take += 1
        let myTake = take
        task = recognizer.recognitionTask(with: req, resultHandler: Self.handler { [weak self] result, segmentEnded, done in
            guard let self, myTake == self.take else { return }
            if let result { text.add(result, segmentEnded: segmentEnded); self.onText?(text.text) }
            if done { self.finish(notify: true) }
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
            if let self, self.take == myTake, self.mode == .finishing { self.finish(notify: true) }
        }
    }

    /// Hard stop for onDisappear: nothing may land after this.
    func cancel() {
        if starting { abandoned = true }
        guard mode == .recording || mode == .finishing else { return }
        finish(notify: false) // stops audio and drops late callbacks
    }

    private func stopAudio() {
        audio?.stop()
        audio?.inputNode.removeTap(onBus: 0)
        audio = nil
    }

    /// Also reached when the recognizer ends on its own mid-recording, so it stops the mic too.
    private func finish(notify: Bool) {
        stopAudio()
        take += 1 // the cancel below fires one more callback; drop it
        task?.cancel()
        task = nil; request = nil
        level = 0
        mode = .idle
        deactivateSession()
        if notify { onEnded?() }
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: off-main callbacks

    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in req.append(buffer); level(Self.level(buffer)) }
    }

    /// RMS mapped from -50…-10 dBFS to 0…1.
    nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-6))
        return min(1, max(0, (db + 50) / 40))
    }

    /// `update(text, segmentEnded, done)`. Each result's text may cover only the current segment;
    /// `TranscriptAccumulator` stitches segments together.
    nonisolated private static func handler(_ update: @escaping @MainActor (String?, Bool, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let segmentEnded = isFinal || result?.speechRecognitionMetadata != nil
            let done = error != nil || isFinal
            Task { @MainActor in update(text, segmentEnded, done) }
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
