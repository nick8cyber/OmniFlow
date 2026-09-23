import Foundation
import os

private let transcriptTextCoreLog = OSLog(subsystem: "com.nick8cyber.omniflow", category: "Transcription")

enum TranscriptionResponseParsingError: Error, Equatable {
    case invalidResponse
}

enum TranscriptionResponseParser {
    // Stock Whisper silence/background-noise phrases; compared against the fully
    // normalized transcript (lowercased, edge punctuation/whitespace trimmed).
    private static let hallucinationPhrases: Set<String> = [
        "thank you",
        "thank you for watching",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitles by the amara.org community",
        "you"
    ]

    private static let hallucinationNoSpeechThreshold = 0.1

    static func parse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw TranscriptionResponseParsingError.invalidResponse
        }
        if let object = json as? [String: Any], let text = object["text"] as? String {
            if isHallucination(text: text, json: object) {
                return ""
            }
            return text
        }
        // Provider or gateway answered with plain text (or a JSON object without a
        // transcript field): fall back to the raw body, newlines collapsed to spaces.
        let body = String(data: data, encoding: .utf8) ?? ""
        let collapsed = body
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            throw TranscriptionResponseParsingError.invalidResponse
        }
        return collapsed
    }

    private static func isHallucination(text: String, json: [String: Any]) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        guard hallucinationPhrases.contains(normalized) else { return false }
        guard let segments = json["segments"] as? [[String: Any]], let first = segments.first else {
            os_log(.info, log: transcriptTextCoreLog,
                   "provider response has no segments/no_speech metadata — hallucination filter skipped")
            return false
        }
        guard let noSpeechProb = first["no_speech_prob"] as? Double else {
            os_log(.info, log: transcriptTextCoreLog,
                   "provider response omitted no_speech_prob — hallucination filter skipped")
            return false
        }
        return noSpeechProb >= hallucinationNoSpeechThreshold
    }
}

enum TranscriptOutputSanitizer {
    static func verbatimTranslation(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // "EMPTY" is intentionally NOT converted here: in a literal translation the
        // word may be legitimate spoken content.
        return result
    }

    static func postProcessedTranscript(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result == "EMPTY" {
            return ""
        }
        return result
    }

    static func commandModeTranscript(_ value: String) -> String {
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func appearsToHaveExecutedInstruction(rawTranscript: String,
                                                 cleanedTranscript: String,
                                                 outputLanguage: String) -> Bool {
        // A set output language legitimately rewrites the lexicon — guard is silent.
        guard outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let rawTokens = significantTokens(in: rawTranscript)
        let cleanedTokens = significantTokens(in: cleanedTranscript)
        guard !rawTokens.isEmpty, !cleanedTokens.isEmpty else { return false }
        let instructionMarkers: Set<String> = [
            "ask", "answer", "compose", "create", "draft", "email", "generate", "make",
            "message", "prompt", "reply", "respond", "response", "summarize", "tell",
            "translate", "write", "claude", "chatgpt", "ai", "llm"
        ]
        let rawMarkers = rawTokens.intersection(instructionMarkers)
        guard !rawMarkers.isEmpty else { return false }

        let preservedMarkers = rawMarkers.intersection(cleanedTokens)
        let overlap = rawTokens.intersection(cleanedTokens)
        let overlapRatio = Double(overlap.count) / Double(max(rawTokens.count, 1))

        let assistantPreamblePattern =
            "(?i)^\\s*(sure|certainly|absolutely|here(?:'s| is)|i(?:'d| would) be happy to|i can)\\b"
        let cleanedHasAssistantPreamble =
            cleanedTranscript.range(of: assistantPreamblePattern, options: .regularExpression) != nil
        let rawHasSamePreamble =
            rawTranscript.range(of: assistantPreamblePattern, options: .regularExpression) != nil

        if cleanedHasAssistantPreamble && !rawHasSamePreamble {
            return true
        }
        return preservedMarkers.isEmpty && overlapRatio < 0.35
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could",
        "for", "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
        "in", "into", "is", "it", "its", "just", "me", "my", "of", "on", "or", "our",
        "please", "she", "so", "that", "the", "their", "them", "then", "there", "this",
        "to", "um", "uh", "was", "we", "were", "what", "when", "where", "who", "with",
        "would", "you", "your"
    ]

    private static func significantTokens(in value: String) -> Set<String> {
        let lowered = value.lowercased()
        var tokens = Set<String>()
        var current = ""
        func flush() {
            let token = current
            current = ""
            guard token.count > 1, !stopWords.contains(token) else { return }
            tokens.insert(token)
        }
        for character in lowered {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
