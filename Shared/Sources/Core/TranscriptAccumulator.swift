import Foundation

/// Builds one dictation take's transcript from speech-recognizer results.
///
/// A result's text is not always cumulative for the whole take. On-device recognition restarts it
/// after a pause (the segment's last result carries `speechRecognitionMetadata`), and the final
/// result after `endAudio()` can hold only the last segment or nothing. Taking each result's text
/// as the whole transcript lost earlier segments, so this keeps finished segments and appends.
public struct TranscriptAccumulator: Equatable, Sendable {
    private let base: String
    private var committed: [String] = []
    private var live = ""

    /// `base` is text already in the field before this take; it is kept in front.
    public init(base: String = "") { self.base = base.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var text: String { ([base] + committed + [live]).filter { !$0.isEmpty }.joined(separator: " ") }

    /// `segmentEnded`: the result closes a segment (`speechRecognitionMetadata != nil` or `isFinal`).
    public mutating func add(_ result: String, segmentEnded: Bool) {
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty {
            let words = Self.words(result)
            if !committed.isEmpty, words.starts(with: Self.words(committed.joined(separator: " "))) {
                committed = [] // cumulative result: it already holds the finished segments
            } else if !live.isEmpty, Self.restarted(from: Self.words(live), to: words) {
                committed.append(live) // reset without a segment-end signal
            }
            live = result
        }
        if segmentEnded, !live.isEmpty { committed.append(live); live = "" }
    }

    // ponytail: word-count heuristic, only a fallback for a reset with no segment-end signal.
    // A revision that both drops words and changes the first word would be read as a new segment.
    private static func restarted(from old: [String], to new: [String]) -> Bool {
        guard new.count < old.count else { return false }
        return new.first != old.first || new.count * 2 < old.count
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
    }
}
