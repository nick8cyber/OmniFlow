import Foundation

enum LiveTranscriptAccumulatorTests {
    static func run() {
        testInterimReplacesCurrentSegmentNotAccumulates()
        testEndSegmentCommitsAndNextSegmentStartsClean()
        testStartSegmentClosesAnyOpenSegment()
        testEmptySegmentsAreNotCommitted()
        testFinalIncludesOpenSegmentTail()
        testDeltaAppendsWithinSegment()
    }

    // Regression tests for the lost-beginning bug: transcribe-live's interim
    // text REPLACES the current voice-activity segment, so segments must be
    // committed on their boundaries — otherwise every segment after the first
    // overwrites the transcript and only the tail gets pasted. Ported from the
    // Windows build's LiveTranscriptAccumulatorTests.

    private static func testInterimReplacesCurrentSegmentNotAccumulates() {
        let acc = LiveTranscriptAccumulator()
        acc.feedInterim("первый")
        acc.feedInterim("первый текст")
        TestSupport.expectEqual(acc.current(), "первый текст",
                                "interim replaces, not accumulates")
    }

    private static func testEndSegmentCommitsAndNextSegmentStartsClean() {
        let acc = LiveTranscriptAccumulator()
        acc.feedInterim("первая фраза целиком")
        acc.endSegment()
        acc.feedInterim("вторая")
        TestSupport.expectEqual(acc.current(), "первая фраза целиком вторая",
                                "committed segments join with a space")
    }

    private static func testStartSegmentClosesAnyOpenSegment() {
        let acc = LiveTranscriptAccumulator()
        acc.feedInterim("раз")
        acc.startSegment()
        acc.feedInterim("два")
        TestSupport.expectEqual(acc.current(), "раз два",
                                "start closes the open segment")
    }

    private static func testEmptySegmentsAreNotCommitted() {
        let acc = LiveTranscriptAccumulator()
        acc.startSegment()
        acc.endSegment()
        acc.feedInterim("текст")
        acc.endSegment()
        acc.endSegment()
        TestSupport.expectEqual(acc.finalText(), "текст",
                                "empty segments are idempotent no-ops")
    }

    private static func testFinalIncludesOpenSegmentTail() {
        let acc = LiveTranscriptAccumulator()
        acc.feedInterim("раз")
        acc.endSegment()
        acc.feedInterim("два три")
        TestSupport.expectEqual(acc.finalText(), "раз два три",
                                "open segment still counts in the final text")
    }

    private static func testDeltaAppendsWithinSegment() {
        let acc = LiveTranscriptAccumulator()
        acc.feedDelta("пер")
        acc.feedDelta("вый текст")
        TestSupport.expectEqual(acc.current(), "первый текст",
                                "delta chunks append (old protocol)")
    }
}
