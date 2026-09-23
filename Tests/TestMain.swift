@main
struct OmniFlowTests {
    static func main() {
        // Suites whose production logic is implemented in this wave. The full
        // runner per spec 32 also calls AppContextServiceTests.run() and
        // ShortcutCoreTests.run() once those suites land.
        GeminiLiveTranscriptionTests.run()
        GeminiTranscriptionTests.run()
        ModelConfigurationTests.run()
        SemanticVersionTests.run()
        LLMCooldownManagerTests.run()
        TranscriptTextCoreTests.run()
        print("OmniFlowTests passed")
    }
}
