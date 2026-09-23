import Foundation

enum ModelConfigurationTests {
    static func run() {
        testProviderlessAliasesMatchCanonicalModels()
        testKnownModelSettingsRemainStable()
        testModelListsAreConsistent()
        testThinkTagStripping()
    }

    // MARK: - 1

    private static func testProviderlessAliasesMatchCanonicalModels() {
        assertSameConfig(alias: " GPT-OSS-20B ", canonical: "openai/gpt-oss-20b")
        assertSameConfig(alias: "gpt-oss-120b", canonical: "openai/gpt-oss-120b")
        assertSameConfig(alias: "gpt-oss-safeguard-20b", canonical: "openai/gpt-oss-safeguard-20b")
        assertSameConfig(alias: "qwen3-32b", canonical: "qwen/qwen3-32b")
        assertSameConfig(alias: " QWEN3.6-27B ", canonical: "qwen/qwen3.6-27b")
    }

    private static func assertSameConfig(alias: String, canonical: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let aliasConfig = ModelConfiguration.config(for: alias)
        let canonicalConfig = ModelConfiguration.config(for: canonical)
        expectEqual(aliasConfig.maxCompletionTokens, canonicalConfig.maxCompletionTokens,
                    "maxCompletionTokens mismatch for \(alias)", file: file, line: line)
        expectEqual(aliasConfig.reasoningEffort, canonicalConfig.reasoningEffort,
                    "reasoningEffort mismatch for \(alias)", file: file, line: line)
        expectEqual(aliasConfig.includeReasoning, canonicalConfig.includeReasoning,
                    "includeReasoning mismatch for \(alias)", file: file, line: line)
        expectEqual(aliasConfig.shouldStripThinkTags, canonicalConfig.shouldStripThinkTags,
                    "shouldStripThinkTags mismatch for \(alias)", file: file, line: line)
    }

    // MARK: - 2

    private static func testKnownModelSettingsRemainStable() {
        let gptOss20b = ModelConfiguration.config(for: "openai/gpt-oss-20b")
        expectEqual(gptOss20b.maxCompletionTokens, 4096, "gpt-oss-20b max completion tokens")
        expectEqual(gptOss20b.reasoningEffort, "low", "gpt-oss-20b reasoning effort")
        expectEqual(gptOss20b.includeReasoning, false, "gpt-oss-20b include reasoning")
        expectEqual(gptOss20b.shouldStripThinkTags, false, "gpt-oss-20b strip think tags")

        let qwen27b = ModelConfiguration.config(for: "qwen/qwen3.6-27b")
        expectEqual(qwen27b.reasoningEffort, "none", "qwen3.6-27b reasoning effort")
        expectEqual(qwen27b.includeReasoning, false, "qwen3.6-27b include reasoning")
        expectEqual(qwen27b.shouldStripThinkTags, true, "qwen3.6-27b strip think tags")

        let unknown = ModelConfiguration.config(for: "example/unknown-model")
        expectEqual(unknown.maxCompletionTokens, Int?.none, "unknown max completion tokens")
        expectEqual(unknown.reasoningEffort, String?.none, "unknown reasoning effort")
        expectEqual(unknown.includeReasoning, Bool?.none, "unknown include reasoning")
        expectEqual(unknown.shouldStripThinkTags, false, "unknown strip think tags")
    }

    // MARK: - 3

    private static func testModelListsAreConsistent() {
        expectEqual(Set(ModelConfiguration.llmModels).count, ModelConfiguration.llmModels.count,
                    "llmModels contains duplicates")
        expectEqual(Set(ModelConfiguration.visionModels).count, ModelConfiguration.visionModels.count,
                    "visionModels contains duplicates")
        expectEqual(Set(ModelConfiguration.transcriptionModels).count,
                    ModelConfiguration.transcriptionModels.count,
                    "transcriptionModels contains duplicates")
        expect(Set(ModelConfiguration.visionModels).isSubset(of: Set(ModelConfiguration.llmModels)),
               "visionModels must be a subset of llmModels")
    }

    // MARK: - 4

    private static func testThinkTagStripping() {
        expectEqual(ModelConfiguration.stripThinkTags("<think>hidden</think> Visible output"),
                    "Visible output",
                    "single closed think block")
        expectEqual(ModelConfiguration.stripThinkTags("<think>one</think>\n<think>two</think> Tail"),
                    "Tail",
                    "multiple closed think blocks")
        expectEqual(ModelConfiguration.stripThinkTags("<think>unfinished"),
                    "",
                    "unclosed think block removes everything")
        expectEqual(ModelConfiguration.stripThinkTags("Visible <think> mid-marker stays"),
                    "Visible <think> mid-marker stays",
                    "unanchored think marker is not stripped")
    }
}
