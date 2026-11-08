import Foundation

/// Service-logic coverage for the Gemini Live adaptive finish (the tail the
/// 2026-11-04 audit flagged): the pure finish decision that used to live inline
/// in `scheduleAdaptiveFinishCheck`. The constants come from the service itself
/// (min 0.8 s post-stop, 1.0 s interim settle, 6.0 s absolute cap).
enum LiveFinishDecisionTests {
    static func run() {
        testKeepsWaitingEarlyAndRecent()
        testKeepsWaitingEarlyButQuiet()
        testKeepsWaitingPastMinWaitWhileInterimStillFresh()
        testFinishesWhenMinWaitAndSettlePass()
        testFinishesOnAbsoluteTimeoutEvenWithFreshInterim()
        testTimeoutBoundaryIsInclusive()
        testSettleBoundaryIsInclusive()
    }

    private static func testKeepsWaitingEarlyAndRecent() {
        let d = GeminiLiveTranscriptionService.shouldFinishLiveTranscript(sinceStop: 0.3,
                                                                          sinceLastInterim: 0.2)
        expectEqual(d.finish, false, "early stop + fresh interim: keep polling")
    }

    private static func testKeepsWaitingEarlyButQuiet() {
        let d = GeminiLiveTranscriptionService.shouldFinishLiveTranscript(sinceStop: 0.5,
                                                                          sinceLastInterim: 5.0)
        expectEqual(d.finish, false, "quiet interim cannot finish before the min post-stop wait")
    }

    private static func testKeepsWaitingPastMinWaitWhileInterimStillFresh() {
        let d = GeminiLiveTranscriptionService.shouldFinishLiveTranscript(sinceStop: 2.0,
                                                                          sinceLastInterim: 0.4)
        expectEqual(d.finish, false, "past min wait but interim still refining: keep polling")
    }

    private static func testFinishesWhenMinWaitAndSettlePass() {
        let d = GeminiLiveTranscriptionService.shouldFinishLiveTranscript(sinceStop: 2.0,
                                                                          sinceLastInterim: 1.2)
        expectEqual(d.finish, true, "min wait + settle passed: finish settled transcript")
        expectEqual(d.timedOut, false, "settled finish is not a timeout")
    }

    private static func testFinishesOnAbsoluteTimeoutEvenWithFreshInterim() {
        let d = GeminiLiveTranscriptionService.shouldFinishLiveTranscript(sinceStop: 7.0,
                                                                          sinceLastInterim: 0.1)
        expectEqual(d.finish, true, "absolute cap finishes regardless of interim freshness")
        expectEqual(d.timedOut, true, "cap hit is reported as a timeout")
    }

    private static func testTimeoutBoundaryIsInclusive() {
        let d = GeminiLiveTranscriptionService.shouldFinishLiveTranscript(sinceStop: 6.0,
                                                                          sinceLastInterim: 0.0)
        expectEqual(d.finish, true, "6 s exactly is the cap boundary — finish")
        expectEqual(d.timedOut, true, "boundary counts as timeout")
    }

    private static func testSettleBoundaryIsInclusive() {
        let d = GeminiLiveTranscriptionService.shouldFinishLiveTranscript(sinceStop: 0.8,
                                                                          sinceLastInterim: 1.0)
        expectEqual(d.finish, true, "0.8 s stop + 1.0 s quiet — both boundaries hit: finish")
    }
}
