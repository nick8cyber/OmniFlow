import Foundation

/// Accumulates realtime transcripts across voice-activity segments. The Live
/// server's `interimInputTranscription` REPLACES the current segment's text
/// (not a delta), and a pause starts a new segment — without accumulation every
/// new segment would overwrite the transcript and lose the start of the
/// dictation (observed on gemini-3.5-transcribe-live; ported from the Windows
/// build's LiveTranscriptAccumulator).
final class LiveTranscriptAccumulator {
    private var committedSegments: [String] = []
    private var currentSegment = ""

    /// Server's interim text for the open segment (full replacement).
    func feedInterim(_ text: String) {
        currentSegment = text
    }

    /// Delta text from the older protocol (`inputTranscription` chunks append).
    func feedDelta(_ text: String) {
        currentSegment += text
    }

    /// Server's final text for the open segment, when it emits one.
    func feedFinal(_ text: String) {
        currentSegment = text
    }

    /// Closes the open segment into the committed text (idempotent when empty).
    func endSegment() {
        let trimmed = currentSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            committedSegments.append(trimmed)
        }
        currentSegment = ""
    }

    /// Closes any open segment before a new one begins.
    func startSegment() {
        endSegment()
    }

    /// Everything transcribed so far: committed segments + the open one.
    func current() -> String {
        var parts = committedSegments
        let trimmed = currentSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts.joined(separator: " ")
    }

    /// Final transcript for the whole session.
    func finalText() -> String {
        current()
    }

    func reset() {
        committedSegments = []
        currentSegment = ""
    }
}
