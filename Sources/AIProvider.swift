import Foundation

/// Which API family the user's key belongs to. Drives which provider fields
/// the UI shows and whether the pipeline runs a separate LLM cleanup step:
/// Gemini returns polished text directly, so cleanup is built in.
enum AIProvider: String, CaseIterable, Identifiable {
    case gemini
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openAICompatible: return "Groq / OpenAI-compatible"
        }
    }

    var subtitle: String {
        switch self {
        case .gemini:
            return "Transcription, live streaming and cleanup — one key for everything"
        case .openAICompatible:
            return "Whisper transcription plus a separate cleanup LLM"
        }
    }

    var sfSymbol: String {
        switch self {
        case .gemini: return "sparkles"
        case .openAICompatible: return "cpu"
        }
    }

    /// True when the pipeline must not call the LLM cleanup endpoint because
    /// the transcription provider already returns final text. Gemini only
    /// qualifies in smart mode — a verbatim transcript is literal speech that
    /// OmniFlow's own cleanup then shapes (ADR-0010).
    func skipsLLMCleanup(geminiTranscriptionMode: GeminiTranscriptionMode) -> Bool {
        self == .gemini && geminiTranscriptionMode == .smart
    }

    static let storageKey = "ai_provider"
    static let geminiBatchModel = "gemini-3.5-transcribe"
    static let geminiLiveModel = "gemini-3.5-transcribe-live"
    static let openAIBatchModel = "whisper-large-v3"

    /// Google's OpenAI-compatible endpoint, used only for API key validation:
    /// the transcription itself routes through the native Gemini API, which
    /// ignores the stored OpenAI-compatible base URL.
    static let geminiValidationBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    /// LLM for the Gemini provider's OpenAI-compatible paths (Edit Mode,
    /// verbatim translation). Vision-capable, so it also serves context.
    /// Free-tier friendly: Google deprecated the 2.x ids below and auto-routes
    /// gemini-2.5-flash requests to gemini-3.5-flash-lite from 2026-12-01.
    static let geminiLLMModel = "gemini-3.5-flash-lite"
    static let geminiContextModels = ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash"]
    private static let deprecatedGeminiLLMModels: Set<String> = [
        "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash",
    ]

    /// First-run migration: an install without the stored key keeps whatever
    /// behaviour its transcription model implies (Gemini models already route
    /// to the Gemini API).
    static func migrate(stored: String?, transcriptionModel: String) -> AIProvider {
        if stored == AIProvider.gemini.rawValue { return .gemini }
        if stored == AIProvider.openAICompatible.rawValue { return .openAICompatible }
        return transcriptionModel.lowercased().contains("gemini") ? .gemini : .openAICompatible
    }

    /// Keep the stored batch transcription model coherent when the user
    /// switches provider (a Whisper model id means nothing to the Gemini API
    /// and vice versa).
    static func adjustedBatchModel(current: String, provider: AIProvider) -> String {
        let isGeminiModel = current.lowercased().contains("gemini")
        switch provider {
        case .gemini:
            return isGeminiModel ? current : geminiBatchModel
        case .openAICompatible:
            return isGeminiModel ? openAIBatchModel : current
        }
    }

    /// Edit Mode, verbatim translation and context inference run through the
    /// provider's OpenAI-compatible endpoint: a Groq model id means nothing to
    /// Gemini and vice versa.
    static func adjustedLLMModel(current: String, provider: AIProvider, fallback: String) -> String {
        let isGeminiModel = current.lowercased().contains("gemini")
        switch provider {
        case .gemini:
            return isGeminiModel && !deprecatedGeminiLLMModels.contains(current.lowercased())
                ? current : geminiLLMModel
        case .openAICompatible:
            return isGeminiModel ? fallback : current
        }
    }

    /// Empty means "provider default" for OpenAI realtime, so a Gemini live
    /// model must not leak into the OpenAI-compatible configuration and an
    /// OpenAI realtime model must not leak into the Gemini one.
    static func adjustedLiveModel(current: String, provider: AIProvider) -> String {
        let isGeminiModel = current.lowercased().contains("gemini")
        switch provider {
        case .gemini:
            return isGeminiModel ? current : geminiLiveModel
        case .openAICompatible:
            return isGeminiModel ? "" : current
        }
    }
}

/// The two transcription modes Gemini transcribe models accept on the wire
/// (ADR-0010). `smart` runs the provider's built-in cleanup and OmniFlow's
/// LLM cleanup stays off; `verbatim` returns literal speech (fillers,
/// repetitions, false starts) that OmniFlow's own cleanup then shapes —
/// that is the only "cleanup aggressiveness" dial the API exposes.
enum GeminiTranscriptionMode: String, CaseIterable, Identifiable {
    case smart
    case verbatim

    var id: String { rawValue }

    /// Live API (`inputAudioTranscription.mode`) wants uppercase.
    var liveWireValue: String { rawValue.uppercased() }
    /// Interactions batch API (`transcription_config.mode.type`) wants lowercase.
    var batchWireValue: String { rawValue }

    var title: String {
        switch self {
        case .smart: return "Smart"
        case .verbatim: return "Verbatim"
        }
    }
}
