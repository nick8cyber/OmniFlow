import Foundation

public struct ModelConfig {
    public let maxCompletionTokens: Int?
    public let reasoningEffort: String?
    public let includeReasoning: Bool?
    public let shouldStripThinkTags: Bool

    init(maxCompletionTokens: Int? = nil,
         reasoningEffort: String? = nil,
         includeReasoning: Bool? = nil,
         shouldStripThinkTags: Bool = false) {
        self.maxCompletionTokens = maxCompletionTokens
        self.reasoningEffort = reasoningEffort
        self.includeReasoning = includeReasoning
        self.shouldStripThinkTags = shouldStripThinkTags
    }
}

public struct ModelConfiguration {
    public static let llmModels = [
        "openai/gpt-oss-20b",
        "openai/gpt-oss-120b",
        "openai/gpt-oss-safeguard-20b",
        "qwen/qwen3.6-27b",
        "groq/compound",
        "groq/compound-mini"
    ]

    public static let visionModels = [
        "qwen/qwen3.6-27b"
    ]

    public static let transcriptionModels = [
        "whisper-large-v3",
        "whisper-large-v3-turbo",
        "gemini-3.5-transcribe"
    ]

    public static func config(for model: String) -> ModelConfig {
        var normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "qwen3-32b":
            normalized = "qwen/qwen3-32b"
        case "qwen3.6-27b":
            normalized = "qwen/qwen3.6-27b"
        case "gpt-oss-20b":
            normalized = "openai/gpt-oss-20b"
        case "gpt-oss-120b":
            normalized = "openai/gpt-oss-120b"
        case "gpt-oss-safeguard-20b":
            normalized = "openai/gpt-oss-safeguard-20b"
        default:
            break
        }
        switch normalized {
        case "openai/gpt-oss-20b":
            return ModelConfig(maxCompletionTokens: 4096,
                               reasoningEffort: "low",
                               includeReasoning: false,
                               shouldStripThinkTags: false)
        case "qwen/qwen3.6-27b":
            return ModelConfig(maxCompletionTokens: nil,
                               reasoningEffort: "none",
                               includeReasoning: false,
                               shouldStripThinkTags: true)
        case "qwen/qwen3-32b":
            return ModelConfig(maxCompletionTokens: nil,
                               reasoningEffort: nil,
                               includeReasoning: nil,
                               shouldStripThinkTags: true)
        default:
            return ModelConfig(maxCompletionTokens: nil,
                               reasoningEffort: nil,
                               includeReasoning: nil,
                               shouldStripThinkTags: false)
        }
    }

    public static func stripThinkTags(_ text: String) -> String {
        let closedRegexPattern = "^(?:\\s*<think>[\\s\\S]*?</think>)+"
        let openRegexPattern = "^\\s*<think>[\\s\\S]*$"
        var cleaned = text.replacingOccurrences(of: closedRegexPattern,
                                                with: "",
                                                options: .regularExpression,
                                                range: nil)
        cleaned = cleaned.replacingOccurrences(of: openRegexPattern,
                                               with: "",
                                               options: .regularExpression,
                                               range: nil)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
