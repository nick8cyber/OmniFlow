import Foundation

enum GeminiLiveTranscription {
    struct ServerFrame {
        var transcript: String?
        var isComplete: Bool = false
        var errorMessage: String?
        var isSetupComplete: Bool = false
    }

    static let defaultBaseURL = "wss://generativelanguage.googleapis.com"
    private static let servicePath =
        "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    // Uppercase here — the Interactions batch API uses lowercase "smart".
    private static let smartMode = "SMART"

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

    static func setupMessage(model: String, customVocabulary: String) throws -> String {
        let terms = GeminiTranscription.vocabularyTerms(from: customVocabulary)
        var inputAudioTranscription: [String: Any] = ["mode": smartMode]
        if !terms.isEmpty {
            inputAudioTranscription["custom_vocabulary"] = terms
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
        guard let server = root["serverContent"] as? [String: Any] else { return frame }
        var transcriptText: String?
        if let inputTranscription = server["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String {
            transcriptText = text
        } else if let modelTurn = server["modelTurn"] as? [String: Any],
                  let parts = modelTurn["parts"] as? [[String: Any]] {
            let joined = parts
                .compactMap { $0["text"] as? String }
                .filter { !$0.isEmpty }
                .joined()
            transcriptText = joined.isEmpty ? nil : joined
        }
        frame.transcript = transcriptText
        frame.isComplete = (server["turnComplete"] as? Bool ?? false)
            || (server["generationComplete"] as? Bool ?? false)
        return frame
    }
}
