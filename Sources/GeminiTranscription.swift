import Foundation

enum GeminiTranscription {
    static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"
    private static let smartMode = "smart"
    private static let customVocabularyLimit = 1000

    // Batch Interactions API handles gemini-*transcribe* models except the *-live ones.
    static func handlesModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("gemini-"), normalized.contains("transcribe") else { return false }
        return !normalized.hasSuffix("-live")
    }

    // Existing installs keep a Groq URL in settings; any non-Google host is replaced
    // with the default Gemini base, an explicitly configured Google host is preserved.
    static func resolvedBaseURL(from configuredBaseURL: String) -> String {
        let trimmed = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host?.lowercased() else {
            return defaultBaseURL
        }
        let isGoogleHost = host == "generativelanguage.googleapis.com"
            || host.hasSuffix(".googleapis.com")
        return isGoogleHost ? trimmed : defaultBaseURL
    }

    static func endpoint(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("interactions")
    }

    // MARK: - Request body (Interactions API)

    private struct InteractionRequest: Encodable {
        let model: String
        let input: [AudioInput]
        let generationConfig: GenerationConfig

        enum CodingKeys: String, CodingKey {
            case model
            case input
            case generationConfig = "generation_config"
        }
    }

    private struct AudioInput: Encodable {
        let type: String
        let data: String
        let mimeType: String

        enum CodingKeys: String, CodingKey {
            case type
            case data
            case mimeType = "mime_type"
        }
    }

    private struct GenerationConfig: Encodable {
        let transcriptionConfig: TranscriptionConfig

        enum CodingKeys: String, CodingKey {
            case transcriptionConfig = "transcription_config"
        }
    }

    private struct TranscriptionConfig: Encodable {
        let mode: Mode
        let customVocabulary: [String]?

        enum CodingKeys: String, CodingKey {
            case mode
            case customVocabulary = "custom_vocabulary"
        }
    }

    private struct Mode: Encodable {
        let type: String
    }

    static func requestBody(model: String,
                            audioData: Data,
                            mimeType: String,
                            customVocabulary: String) throws -> Data {
        let terms = vocabularyTerms(from: customVocabulary)
        let request = InteractionRequest(
            model: model,
            input: [
                AudioInput(type: "audio",
                           data: audioData.base64EncodedString(),
                           mimeType: mimeType)
            ],
            generationConfig: GenerationConfig(
                transcriptionConfig: TranscriptionConfig(
                    mode: Mode(type: smartMode),
                    customVocabulary: terms.isEmpty ? nil : terms)))
        return try JSONEncoder().encode(request)
    }

    static func vocabularyTerms(from rawVocabulary: String) -> [String] {
        let terms = rawVocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let deduplicated = terms.filter { seen.insert($0.lowercased()).inserted }
        return Array(deduplicated.prefix(customVocabularyLimit))
    }

    // MARK: - Response parsing

    private struct InteractionResponse: Decodable {
        let status: String?
        let steps: [Step]?
    }

    private struct Step: Decodable {
        let type: String?
        let content: [Content]?
    }

    private struct Content: Decodable {
        let text: String?
    }

    static func transcript(fromResponse data: Data) throws -> String {
        // Some error envelopes arrive with HTTP 200 — check before parsing text.
        if let message = errorMessage(from: data), !message.isEmpty {
            throw TranscriptionError.transcriptionFailed(message)
        }
        guard let response = try? JSONDecoder().decode(InteractionResponse.self, from: data) else {
            throw TranscriptionError.transcriptionFailed("Unreadable Gemini transcription response.")
        }
        if let status = response.status, status != "completed" {
            throw TranscriptionError.transcriptionFailed("Gemini transcription \(status).")
        }
        let transcript = (response.steps ?? [])
            .filter { $0.type == nil || $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .compactMap { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty {
            throw TranscriptionError.transcriptionFailed("Gemini returned an empty transcript.")
        }
        return transcript
    }

    static func failureMessage(fromResponse data: Data, fallback: String) -> String {
        if let message = errorMessage(from: data), !message.isEmpty {
            return message
        }
        return fallback
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = json as? [String: Any] {
            return (object["error"] as? [String: Any])?["message"] as? String
        }
        // Auth errors arrive wrapped in an array.
        if let array = json as? [[String: Any]] {
            for entry in array {
                if let message = (entry["error"] as? [String: Any])?["message"] as? String,
                   !message.isEmpty {
                    return message
                }
            }
            return nil
        }
        return nil
    }
}
