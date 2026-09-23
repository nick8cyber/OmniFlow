import Foundation

/// Adaptive RMS-to-0...1 normalizer for the live recording indicator.
struct LiveAudioLevelNormalizer {
    static let minimumRMS: Float = 0.00001
    static let minSpanDB: Float = 18
    static let peakHeadroomDB: Float = 8
    static let speechGateMarginDB: Float = 3
    static let minimumVisibleActiveLevel: Float = 0.12
    static let noiseGateNormalizedThreshold: Float = 0.06
    static let floorRiseWindowDB: Float = 4
    static let floorFallBlend: Float = 0.12
    static let floorRiseBlend: Float = 0.02
    static let peakAttackBlend: Float = 0.55
    static let peakReleaseBlend: Float = 0.04
    static let displayAttackBlend: Float = 0.45
    static let displayReleaseBlend: Float = 0.12

    private static let initialNoiseFloorDB: Float = -55
    private static let initialPeakCeilingDB: Float = -37

    private var noiseFloorDB: Float = LiveAudioLevelNormalizer.initialNoiseFloorDB
    private var peakCeilingDB: Float = LiveAudioLevelNormalizer.initialPeakCeilingDB
    private var displayLevel: Float = 0

    init() {}

    mutating func reset() {
        noiseFloorDB = Self.initialNoiseFloorDB
        peakCeilingDB = Self.initialPeakCeilingDB
        displayLevel = 0
    }

    mutating func normalizedLevel(forRMS rms: Float) -> Float {
        let levelDB = 20 * log10f(max(rms, Self.minimumRMS))
        updateNoiseFloor(levelDB)
        updatePeakCeiling(levelDB)
        let displayCeilingDB = peakCeilingDB + Self.peakHeadroomDB
        let dynamicSpan = max(displayCeilingDB - noiseFloorDB, Self.minSpanDB + Self.peakHeadroomDB)
        var normalized = min(max((levelDB - noiseFloorDB) / dynamicSpan, 0), 1)
        let isActiveSpeech = levelDB >= noiseFloorDB + Self.speechGateMarginDB
        if normalized < Self.noiseGateNormalizedThreshold && levelDB <= noiseFloorDB + Self.speechGateMarginDB {
            normalized = 0
        } else if isActiveSpeech {
            normalized = max(normalized, Self.minimumVisibleActiveLevel)
        }
        let blend: Float = normalized > displayLevel ? Self.displayAttackBlend : Self.displayReleaseBlend
        displayLevel = displayLevel + (normalized - displayLevel) * blend
        return displayLevel
    }

    private mutating func updateNoiseFloor(_ levelDB: Float) {
        let ceilingLimitedLevel = min(levelDB, peakCeilingDB - Self.minSpanDB)
        if ceilingLimitedLevel <= noiseFloorDB {
            noiseFloorDB = Self.mix(noiseFloorDB, ceilingLimitedLevel, Self.floorFallBlend)
        } else if ceilingLimitedLevel <= noiseFloorDB + Self.floorRiseWindowDB {
            noiseFloorDB = Self.mix(noiseFloorDB, ceilingLimitedLevel, Self.floorRiseBlend)
        }
    }

    private mutating func updatePeakCeiling(_ levelDB: Float) {
        let minimumCeiling = noiseFloorDB + Self.minSpanDB
        if levelDB >= peakCeilingDB {
            peakCeilingDB = Self.mix(peakCeilingDB, levelDB, Self.peakAttackBlend)
        } else {
            peakCeilingDB = Self.mix(peakCeilingDB, max(levelDB, minimumCeiling), Self.peakReleaseBlend)
        }
        peakCeilingDB = max(peakCeilingDB, minimumCeiling)
    }

    private static func mix(_ current: Float, _ target: Float, _ blend: Float) -> Float {
        current + (target - current) * blend
    }
}
