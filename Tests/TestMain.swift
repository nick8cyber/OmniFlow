@main
struct OmniFlowTests {
    static func main() {
        AppContextServiceTests.run()
        AppSettingsDefaultsTests.run()
        GeminiLiveTranscriptionTests.run()
        GeminiTranscriptionTests.run()
        LiveAudioLevelNormalizerTests.run()
        ModelConfigurationTests.run()
        PostProcessingFallbackTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        LLMCooldownManagerTests.run()
        TranscriptionServiceTests.run()
        TranscriptTextCoreTests.run()
        print("OmniFlowTests passed")
    }
}
