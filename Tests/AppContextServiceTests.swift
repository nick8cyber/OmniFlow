import Foundation

enum AppContextServiceTests {
    static func run() {
        testQwenRawOutputIsSummarized()
        testQwenReasoningOutputIsStripped()
        testNonStrippingModelPreservesExistingBehavior()
        testDeprecatedGroqModelsAreNotPredefined()
        testQwenCleanupDisablesReasoning()
    }

    // MARK: - 1

    private static func testQwenRawOutputIsSummarized() {
        let content = """
        The synthetic launch ships on Friday. QA rehearses the rollout steps. Marketing drafts the announcement.
        """
        let summary = AppContextService.activitySummary(from: content, model: "qwen/qwen3.6-27b")
        expectEqual(summary,
                    "The synthetic launch ships on Friday. QA rehearses the rollout steps.",
                    "Qwen output must be truncated to the first two sentences")
    }

    // MARK: - 2

    private static func testQwenReasoningOutputIsStripped() {
        let content = "<think>\nHidden chain of thought\n</think>\nOnly the clean summary survives. A second sentence follows. A third sentence is dropped."
        let summary = AppContextService.activitySummary(from: content, model: "qwen/qwen3.6-27b")
        expect(summary?.contains("Hidden chain of thought") != true,
               "think block must be stripped for models that require it")
        expectEqual(summary,
                    "Only the clean summary survives. A second sentence follows.",
                    "stripped output must still be truncated to two sentences")
    }

    // MARK: - 3

    private static func testNonStrippingModelPreservesExistingBehavior() {
        let content = "<think>kept</think> Raw answer stays intact. Second sentence remains."
        let summary = AppContextService.activitySummary(
            from: content, model: "meta-llama/llama-4-scout-17b-16e-instruct")
        expectEqual(summary, content.trimmingCharacters(in: .whitespacesAndNewlines),
                    "non-stripping model output must be returned as is")
        expect(summary?.contains("<think>kept</think>") == true,
               "think block must be preserved for non-stripping models")
    }

    // MARK: - 4

    private static func testDeprecatedGroqModelsAreNotPredefined() {
        let deprecatedModels = [
            "qwen/qwen3-32b",
            "meta-llama/llama-4-scout-17b-16e-instruct",
            "llama-3.1-8b-instant",
            "llama-3.3-70b-versatile"
        ]
        for deprecatedModel in deprecatedModels {
            expect(!ModelConfiguration.llmModels.contains(deprecatedModel),
                   "deprecated model must not be predefined: \(deprecatedModel)")
        }
        expect(ModelConfiguration.llmModels.contains("qwen/qwen3.6-27b"),
               "new fallback model must be predefined")
    }

    // MARK: - 5

    private static func testQwenCleanupDisablesReasoning() {
        let config = ModelConfiguration.config(for: "qwen/qwen3.6-27b")
        expectEqual(config.reasoningEffort, "none", "Qwen cleanup must disable reasoning effort")
        expectEqual(config.includeReasoning, false, "Qwen cleanup must not request reasoning")
    }
}
