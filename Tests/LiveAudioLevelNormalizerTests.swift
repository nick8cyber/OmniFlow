import Foundation

/// Suite for `LiveAudioLevelNormalizer` (spec 20 §9): the 13 constants, the
/// noise/speech gates, and the attack/release smoothing.
enum LiveAudioLevelNormalizerTests {
    static func run() {
        testConstantsMatchSpec()
        testSilenceStaysAtZero()
        testNoiseGateSilencesQuietInput()
        testFirstLoudSampleUsesAttackBlend()
        testActiveSpeechIsVisible()
        testAttackIsFasterThanRelease()
        testCeilingAdaptationKeepsLoudInputBelowFullScale()
        testResetRestoresInitialState()
    }

    private static func rmsForDB(_ db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }

    // MARK: - 1

    private static func testConstantsMatchSpec() {
        expectEqual(LiveAudioLevelNormalizer.minimumRMS, Float(0.00001), "minimumRMS")
        expectEqual(LiveAudioLevelNormalizer.minSpanDB, Float(18), "minSpanDB")
        expectEqual(LiveAudioLevelNormalizer.peakHeadroomDB, Float(8), "peakHeadroomDB")
        expectEqual(LiveAudioLevelNormalizer.speechGateMarginDB, Float(3), "speechGateMarginDB")
        expectEqual(LiveAudioLevelNormalizer.minimumVisibleActiveLevel, Float(0.12), "minimumVisibleActiveLevel")
        expectEqual(LiveAudioLevelNormalizer.noiseGateNormalizedThreshold, Float(0.06), "noiseGateNormalizedThreshold")
        expectEqual(LiveAudioLevelNormalizer.floorRiseWindowDB, Float(4), "floorRiseWindowDB")
        expectEqual(LiveAudioLevelNormalizer.floorFallBlend, Float(0.12), "floorFallBlend")
        expectEqual(LiveAudioLevelNormalizer.floorRiseBlend, Float(0.02), "floorRiseBlend")
        expectEqual(LiveAudioLevelNormalizer.peakAttackBlend, Float(0.55), "peakAttackBlend")
        expectEqual(LiveAudioLevelNormalizer.peakReleaseBlend, Float(0.04), "peakReleaseBlend")
        expectEqual(LiveAudioLevelNormalizer.displayAttackBlend, Float(0.45), "displayAttackBlend")
        expectEqual(LiveAudioLevelNormalizer.displayReleaseBlend, Float(0.12), "displayReleaseBlend")
    }

    // MARK: - 2

    private static func testSilenceStaysAtZero() {
        var normalizer = LiveAudioLevelNormalizer()
        for _ in 0..<10 {
            expectEqual(Double(normalizer.normalizedLevel(forRMS: 0)), 0.0,
                        "digital silence must normalize to 0")
        }
    }

    // MARK: - 3

    private static func testNoiseGateSilencesQuietInput() {
        // -54 dB sits below the floor + 3 dB speech margin, so the 0.06 gate
        // zeroes the (already small) normalized value.
        var normalizer = LiveAudioLevelNormalizer()
        for _ in 0..<10 {
            expectEqual(Double(normalizer.normalizedLevel(forRMS: rmsForDB(-54))), 0.0,
                        "input below the speech margin must gate to 0")
        }
    }

    // MARK: - 4

    private static func testFirstLoudSampleUsesAttackBlend() {
        // -6 dB on a fresh normalizer clamps to normalized 1.0; the first
        // displayed value is therefore exactly 0 (initial) + 1 * 0.45.
        var normalizer = LiveAudioLevelNormalizer()
        let first = Double(normalizer.normalizedLevel(forRMS: 0.5))
        expectApproximatelyEqual(first, 0.45, accuracy: 0.001,
                                 "first loud sample must move by the 0.45 attack blend")
    }

    // MARK: - 5

    private static func testActiveSpeechIsVisible() {
        // -51.9 dB is inside the speech margin (>= floor + 3) while its raw
        // normalized value (0.119) sits below the 0.12 visibility floor: the
        // bump must apply, so the first sample is exactly 0.12 * 0.45.
        var normalizer = LiveAudioLevelNormalizer()
        let first = Double(normalizer.normalizedLevel(forRMS: rmsForDB(-51.9)))
        expectApproximatelyEqual(first, 0.12 * 0.45, accuracy: 0.001,
                                 "active speech below the visibility floor is bumped to 0.12")
        // The displayed level converges toward the 0.12 visibility floor.
        var converged: Float = 0
        for _ in 0..<60 {
            converged = normalizer.normalizedLevel(forRMS: rmsForDB(-51.9))
        }
        expect(Double(converged) >= 0.119,
               "sustained active speech must converge to at least the 0.12 visibility floor, got \(converged)")
    }

    // MARK: - 6

    private static func testAttackIsFasterThanRelease() {
        // The input rises fast enough (+12 dB per frame) that the adapted
        // ceiling always trails it: the normalized value stays pinned at 1.0
        // and the display attacks to full scale.
        var normalizer = LiveAudioLevelNormalizer()
        var level: Float = 0
        var rms: Float = 0.1
        for _ in 0..<40 {
            level = normalizer.normalizedLevel(forRMS: rms)
            rms *= 4
        }
        expect(Double(level) > 0.99, "sustained attack must reach near full scale, got \(level)")

        // One silent frame drops the display by only the 0.12 release blend.
        let afterSilence = Double(normalizer.normalizedLevel(forRMS: 0))
        expectApproximatelyEqual(afterSilence, Double(level) * (1 - 0.12), accuracy: 0.01,
                                 "release must decay by the 0.12 blend per frame")
        expect(afterSilence > 0.45,
               "release must retain more per frame than a single attack step (0.45)")
    }

    // MARK: - 7

    private static func testCeilingAdaptationKeepsLoudInputBelowFullScale() {
        // A constant -26 dB input walks the peak ceiling up (-37 -> -26), so
        // the normalized value settles well below 1 instead of pinning there.
        var normalizer = LiveAudioLevelNormalizer()
        var level: Float = 0
        for _ in 0..<200 {
            level = normalizer.normalizedLevel(forRMS: 0.05)
        }
        expect(Double(level) > 0.5 && Double(level) < 0.9,
               "ceiling adaptation must settle constant loud input below full scale, got \(level)")
    }

    // MARK: - 8

    private static func testResetRestoresInitialState() {
        var normalizer = LiveAudioLevelNormalizer()
        for _ in 0..<20 {
            _ = normalizer.normalizedLevel(forRMS: 0.5)
        }
        normalizer.reset()
        let afterReset = Double(normalizer.normalizedLevel(forRMS: 0.5))
        expectApproximatelyEqual(afterReset, 0.45, accuracy: 0.001,
                                 "reset must restore the initial floor/ceiling/display state")
    }
}
