import Foundation

enum GeminiLiveTranscription {
    struct ServerFrame {
        var transcript: String?
        var interimTranscript: String?
        var activityStartsSegment = false
        var activityEndsSegment = false
        var isComplete: Bool = false
        var errorMessage: String?
        var isSetupComplete: Bool = false
    }

    static let defaultBaseURL = "wss://generativelanguage.googleapis.com"
    private static let servicePath =
        "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    // The mode goes out uppercase here — the Interactions batch API uses
    // lowercase (`GeminiTranscriptionMode.liveWireValue`/`batchWireValue`).

    static func handlesModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("gemini-") && normalized.hasSuffix("-transcribe-live")
    }

    static func socketURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? defaultBaseURL : trimmed
        guard var components = URLComponents(string: effective) else { return nil }
        switch components.scheme?.lowercased() {
        case "https", "wss":
            components.scheme = "wss"
        case "http", "ws":
            components.scheme = "ws"
        default:
            return nil
        }
        guard let host = components.host, !host.isEmpty else { return nil }
        // A non-Google host would never speak this protocol — fall back to the
        // default socket instead of opening a dead connection.
        guard host.hasSuffix("googleapis.com") else {
            return URL(string: defaultBaseURL + servicePath)
        }
        components.path = servicePath
        components.query = nil
        return components.url
    }

    static func setupMessage(model: String, customVocabulary: String,
                             languageCodes: [String]? = nil,
                             mode: GeminiTranscriptionMode) throws -> String {
        let terms = GeminiTranscription.vocabularyTerms(from: customVocabulary)
        var inputAudioTranscription: [String: Any] = ["mode": mode.liveWireValue]
        if !terms.isEmpty {
            inputAudioTranscription["custom_vocabulary"] = terms
        }
        // Spoken-language hint, Windows-parity wire format: `languageCodes` INSIDE
        // inputAudioTranscription (a `language` string field makes the server
        // never answer setupComplete). Empty/nil = server-side auto-detection.
        if let languageCodes, !languageCodes.isEmpty {
            inputAudioTranscription["languageCodes"] = languageCodes
        }
        let message: [String: Any] = [
            "setup": [
                "model": normalizedModelPath(model),
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": inputAudioTranscription
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func audioMessage(pcm16: Data, sampleRate: Int) throws -> String {
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=\(sampleRate)",
                    "data": pcm16.base64EncodedString()
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func audioStreamEndMessage() throws -> String {
        let message: [String: Any] = [
            "realtimeInput": ["audioStreamEnd": true]
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func normalizedModelPath(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("models/") {
            return trimmed
        }
        return "models/\(trimmed)"
    }

    static func parseServerFrame(_ text: String) -> ServerFrame {
        var frame = ServerFrame()
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return frame
        }
        if let error = root["error"] as? [String: Any] {
            frame.errorMessage = error["message"] as? String ?? "Gemini live transcription failed."
            frame.isComplete = true
            return frame
        }
        if root["setupComplete"] != nil {
            frame.isSetupComplete = true
        }
        if let voiceActivity = root["voiceActivity"] as? [String: Any],
           let kind = voiceActivity["type"] as? String {
            // gemini-3.5-transcribe-live has no turnComplete: segment boundaries
            // arrive as voice activity events instead.
            frame.activityStartsSegment = kind == "ACTIVITY_START"
            frame.activityEndsSegment = kind == "ACTIVITY_END"
        }
        guard let server = root["serverContent"] as? [String: Any] else { return frame }
        // Windows parity: only the two transcription fields are consumed —
        // modelTurn (model's own output) is ignored entirely.
        if let inputTranscription = server["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String {
            frame.transcript = text
        }
        if let interim = server["interimInputTranscription"] as? [String: Any],
           let text = interim["text"] as? String {
            // transcribe-live models: interim text REPLACES the current segment.
            // An empty string is a valid segment reset — fed as-is (Windows parity).
            frame.interimTranscript = text
        }
        frame.isComplete = (server["turnComplete"] as? Bool ?? false)
            || (server["generationComplete"] as? Bool ?? false)
        return frame
    }
}
