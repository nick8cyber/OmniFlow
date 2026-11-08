@main
struct OmniFlowTests {
    static func main() {
        OverlayTextFitterTests.run()
        PasteGateTests.run()
        AIProviderTests.run()
        AppContextServiceTests.run()
        AppSettingsDefaultsTests.run()
        GeminiLiveTranscriptionTests.run()
        GeminiTranscriptionTests.run()
        LiveAudioLevelNormalizerTests.run()
        LiveTranscriptAccumulatorTests.run()
        ModelConfigurationTests.run()
        PostProcessingFallbackTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        SpeechHeuristicsTests.run()
        LLMCooldownManagerTests.run()
        TranscriptionServiceTests.run()
        TranscriptTextCoreTests.run()
        print("OmniFlowTests passed")
    }
}
