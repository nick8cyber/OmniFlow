import Foundation

enum AIProviderTests {
    static func run() {
        testMigrationFromStoredValues()
        testMigrationInfersFromTranscriptionModelWhenUnstored()
        testBatchModelAdjustmentOnSwitch()
        testLiveModelAdjustmentOnSwitch()
        testLLMModelAdjustmentOnSwitch()
        testGeminiSkipsLLMCleanup()
    }

    private static func testMigrationFromStoredValues() {
        TestSupport.expectEqual(AIProvider.migrate(stored: "gemini", transcriptionModel: "whisper-large-v3"),
                                .gemini)
        TestSupport.expectEqual(AIProvider.migrate(stored: "openAICompatible", transcriptionModel: "gemini-3.5-transcribe"),
                                .openAICompatible)
    }

    private static func testMigrationInfersFromTranscriptionModelWhenUnstored() {
        TestSupport.expectEqual(AIProvider.migrate(stored: nil, transcriptionModel: "gemini-3.5-transcribe"),
                                .gemini)
        TestSupport.expectEqual(AIProvider.migrate(stored: nil, transcriptionModel: "Gemini-2.5-Flash"),
                                .gemini)
        TestSupport.expectEqual(AIProvider.migrate(stored: nil, transcriptionModel: "whisper-large-v3"),
                                .openAICompatible)
        TestSupport.expectEqual(AIProvider.migrate(stored: nil, transcriptionModel: "gpt-4o-transcribe"),
                                .openAICompatible)
    }

    private static func testBatchModelAdjustmentOnSwitch() {
        TestSupport.expectEqual(AIProvider.adjustedBatchModel(current: "whisper-large-v3", provider: .gemini),
                                AIProvider.geminiBatchModel)
        TestSupport.expectEqual(AIProvider.adjustedBatchModel(current: "gemini-3.5-transcribe", provider: .gemini),
                                "gemini-3.5-transcribe")
        TestSupport.expectEqual(AIProvider.adjustedBatchModel(current: "gemini-3.5-transcribe", provider: .openAICompatible),
                                AIProvider.openAIBatchModel)
        TestSupport.expectEqual(AIProvider.adjustedBatchModel(current: "whisper-large-v3", provider: .openAICompatible),
                                "whisper-large-v3")
    }

    private static func testLiveModelAdjustmentOnSwitch() {
        TestSupport.expectEqual(AIProvider.adjustedLiveModel(current: "gpt-4o-transcribe", provider: .gemini),
                                AIProvider.geminiLiveModel)
        TestSupport.expectEqual(AIProvider.adjustedLiveModel(current: "gemini-3.5-transcribe-live", provider: .openAICompatible),
                                "")
        TestSupport.expectEqual(AIProvider.adjustedLiveModel(current: "gpt-4o-transcribe", provider: .openAICompatible),
                                "gpt-4o-transcribe")
    }

    private static func testLLMModelAdjustmentOnSwitch() {
        TestSupport.expectEqual(AIProvider.adjustedLLMModel(current: "openai/gpt-oss-20b", provider: .gemini,
                                                            fallback: "openai/gpt-oss-20b"),
                                AIProvider.geminiLLMModel)
        TestSupport.expectEqual(AIProvider.adjustedLLMModel(current: "gemini-2.5-flash", provider: .gemini,
                                                            fallback: "x"), AIProvider.geminiLLMModel)
        TestSupport.expectEqual(AIProvider.adjustedLLMModel(current: "gemini-3.6-flash", provider: .gemini,
                                                            fallback: "x"), "gemini-3.6-flash")
        TestSupport.expectEqual(AIProvider.adjustedLLMModel(current: "gemini-2.5-flash", provider: .openAICompatible,
                                                            fallback: "qwen/qwen3.6-27b"), "qwen/qwen3.6-27b")
        TestSupport.expectEqual(AIProvider.adjustedLLMModel(current: "openai/gpt-oss-20b", provider: .openAICompatible,
                                                            fallback: "qwen/qwen3.6-27b"), "openai/gpt-oss-20b")
    }

    private static func testGeminiSkipsLLMCleanup() {
        TestSupport.expect(AIProvider.gemini.skipsLLMCleanup(geminiTranscriptionMode: .smart),
                           "Gemini smart mode must skip LLM cleanup")
        TestSupport.expect(!AIProvider.gemini.skipsLLMCleanup(geminiTranscriptionMode: .verbatim),
                           "Gemini verbatim mode must run OmniFlow's LLM cleanup")
        TestSupport.expect(!AIProvider.openAICompatible.skipsLLMCleanup(geminiTranscriptionMode: .smart),
                           "OpenAI-compatible must keep LLM cleanup")
        TestSupport.expect(!AIProvider.openAICompatible.skipsLLMCleanup(geminiTranscriptionMode: .verbatim),
                           "OpenAI-compatible ignores the Gemini mode")
    }
}
