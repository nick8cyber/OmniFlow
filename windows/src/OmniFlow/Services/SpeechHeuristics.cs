namespace OmniFlow.Services;

/// <summary>
/// Speech detection from raw per-buffer RMS samples (pre-normalizer). The UI
/// level is adaptively normalized, so plain room noise reads as audible — a
/// "thought about it and decided not to speak" hold then reaches the provider
/// and waits 20-40 s for an empty answer. This heuristic instead measures how
/// long the capture stood out above its own noise floor: speech is sustained,
/// a click/cough/breath is not. Port of the macOS SpeechHeuristics.
/// </summary>
public static class SpeechHeuristics
{
    public sealed record Analysis(double SpeechSeconds, double NoiseFloorRms);

    /// <summary>Threshold = max(3× the 15th-percentile RMS floor, 0.003) — the
    /// absolute term keeps a dead-calm room (floor ≈ 0) from classifying its
    /// own hiss as speech. Samples are uniform slices of totalDuration.</summary>
    public static Analysis Analyze(IReadOnlyList<double> rmsSamples, double totalDuration)
    {
        if (totalDuration <= 0 || rmsSamples.Count == 0) return new Analysis(0, 0);
        var sorted = rmsSamples.OrderBy(x => x).ToArray();
        var floor = sorted[Math.Max(0, (int)(sorted.Length * 0.15) - 1)];
        var threshold = Math.Max(floor * 3, 0.003);
        var above = 0;
        foreach (var s in sorted) if (s > threshold) above++;
        return new Analysis(totalDuration * ((double)above / sorted.Length), floor);
    }
}
