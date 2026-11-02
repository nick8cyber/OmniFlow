import Foundation

enum SpeechHeuristicsTests {
    static func run() {
        testSilenceYieldsNoSpeech()
        testSustainedSpeechAboveFloorIsCounted()
        testBriefCoughIsNotSpeech()
        testDeadCalmRoomHissIsNotSpeech()
        testEmptyInputsAreSafe()
    }

    private static func testSilenceYieldsNoSpeech() {
        let samples = [Float](repeating: 0.001, count: 100)
        let a = SpeechHeuristics.analyze(rmsSamples: samples, totalDuration: 2.0)
        TestSupport.expect(a.speechSeconds < 0.05,
                           "flat room noise yields ~0 speech seconds, got \(a.speechSeconds)")
    }

    private static func testSustainedSpeechAboveFloorIsCounted() {
        var samples = [Float](repeating: 0.001, count: 60)
        samples.append(contentsOf: [Float](repeating: 0.25, count: 40))
        let a = SpeechHeuristics.analyze(rmsSamples: samples, totalDuration: 2.0)
        TestSupport.expectApproximatelyEqual(a.speechSeconds, 0.8, accuracy: 0.01,
                                             "40% of the capture above the floor = 0.8s of speech")
        TestSupport.expect(a.noiseFloorRMS < 0.01, "noise floor tracks the quiet part")
    }

    private static func testBriefCoughIsNotSpeech() {
        var samples = [Float](repeating: 0.002, count: 99)
        samples[50] = 0.5
        let a = SpeechHeuristics.analyze(rmsSamples: samples, totalDuration: 3.0)
        TestSupport.expect(a.speechSeconds < 0.3,
                           "a single loud transient is not sustained speech, got \(a.speechSeconds)")
    }

    private static func testDeadCalmRoomHissIsNotSpeech() {
        let samples = [Float](repeating: 0.0005, count: 100)
        let a = SpeechHeuristics.analyze(rmsSamples: samples, totalDuration: 2.0)
        TestSupport.expect(a.speechSeconds < 0.05,
                           "the absolute floor keeps dead-calm hiss from counting as speech")
    }

    private static func testEmptyInputsAreSafe() {
        let a = SpeechHeuristics.analyze(rmsSamples: [], totalDuration: 2.0)
        TestSupport.expectEqual(a.speechSeconds, 0, "no samples = no speech")
        let b = SpeechHeuristics.analyze(rmsSamples: [0.5, 0.1], totalDuration: 0)
        TestSupport.expectEqual(b.speechSeconds, 0, "zero duration = no speech")
    }
}
