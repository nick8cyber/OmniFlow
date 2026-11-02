import Foundation

/// Speech detection from raw per-buffer RMS samples (pre-normalizer).
///
/// The UI audio level is adaptively normalized, so plain room noise reads as
/// audible — a "thought about it and decided not to speak" hold then reaches
/// the provider and waits 20-40 s for an empty answer. This heuristic instead
/// measures how long the capture stood out above its own noise floor: speech
/// is sustained, a click/cough/breath is not.
enum SpeechHeuristics {
    struct Analysis {
        /// Seconds of capture above the adaptive speech threshold.
        let speechSeconds: Double
        /// 15th-percentile RMS — the session's noise floor (for diagnostics).
        let noiseFloorRMS: Float
    }

    /// Threshold = max(3× the 15th-percentile RMS floor, 0.003) — the absolute
    /// term keeps a perfectly dead-calm room (floor ≈ 0) from classifying its
    /// own hiss as speech. Samples are treated as uniform slices of
    /// `totalDuration`.
    static func analyze(rmsSamples: [Float], totalDuration: Double) -> Analysis {
        guard totalDuration > 0, !rmsSamples.isEmpty else {
            return Analysis(speechSeconds: 0, noiseFloorRMS: 0)
        }
        let sorted = rmsSamples.sorted()
        let floorRMS = sorted[max(0, Int(Double(sorted.count) * 0.15) - 1)]
        let threshold = max(floorRMS * 3, 0.003)
        let above = sorted.reduce(0) { $0 + ($1 > threshold ? 1 : 0) }
        let speech = totalDuration * (Double(above) / Double(sorted.count))
        return Analysis(speechSeconds: speech, noiseFloorRMS: floorRMS)
    }
}
