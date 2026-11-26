import Testing
@testable import Core

@Suite struct TranscriptAccumulatorTests {
    private func run(_ results: [(String, Bool)], base: String = "") -> String {
        var acc = TranscriptAccumulator(base: base)
        for (text, ended) in results { acc.add(text, segmentEnded: ended) }
        return acc.text
    }

    @Test func partialsWithinOneSegmentReplaceEachOther() {
        #expect(run([("by", false), ("Buy milk", false), ("Buy milk and eggs", false)]) == "Buy milk and eggs")
    }

    /// The reported bug: after a pause the recognizer starts over, which dropped the first segment.
    @Test func pauseResetKeepsEarlierSegment() {
        #expect(run([("Buy milk", false), ("Buy milk and eggs", true),
                     ("Call", false), ("Call the plumber", false)]) == "Buy milk and eggs Call the plumber")
    }

    @Test func pauseResetWithoutSignalStillKeepsEarlierSegment() {
        #expect(run([("Buy milk and eggs", false), ("Call", false), ("Call the plumber", false)])
                == "Buy milk and eggs Call the plumber")
    }

    /// The second half of the bug: the final result after Stop holds only the last segment, or nothing.
    @Test func finalOnStopWithLastSegmentOnly() {
        #expect(run([("Buy milk and eggs", true), ("Call the plumber", false), ("Call the plumber.", true)])
                == "Buy milk and eggs Call the plumber.")
    }

    @Test func emptyFinalOnStopKeepsEverything() {
        #expect(run([("Buy milk and eggs", true), ("Call the plumber", false), ("", true)])
                == "Buy milk and eggs Call the plumber")
    }

    @Test func cumulativeFinalDoesNotDuplicate() {
        #expect(run([("Buy milk and eggs", true), ("Call the plumber", false),
                     ("Buy milk and eggs. Call the plumber.", true)]) == "Buy milk and eggs. Call the plumber.")
    }

    @Test func keepsTextFromBeforeTheTake() {
        #expect(run([("Buy milk", true), ("", true)], base: "Earlier note ") == "Earlier note Buy milk")
        #expect(run([], base: "Earlier note") == "Earlier note")
    }
}
