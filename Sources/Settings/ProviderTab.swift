import SwiftUI

// AI Provider tab: the provider switch (Gemini vs OpenAI-compatible) is the
// primary fork — the API key card and the fields below adapt to it.

struct AIProviderSettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var apiKeyInput = ""
    @State private var isValidatingKey = false
    @State private var keyValidationSucceeded = false
    @State private var keyValidationFailureMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                providerCard
                if appState.aiProvider == .gemini && appState.geminiTranscriptionMode == .smart {
                    InfoBanner(icon: "sparkles",
                               text: "No post-processing to configure in Smart mode. Gemini returns polished text directly — switch Transcription Mode to Verbatim below to clean transcripts with OmniFlow's own LLM pipeline instead.")
                }
                apiKeyCard
                ProviderSettingsFields()
            }
            .padding(20)
        }
        .onAppear {
            apiKeyInput = appState.apiKey
            appState.refreshAvailableModels()
        }
        .onChange(of: appState.aiProvider) { _ in
            // Validation outcomes belong to the provider that produced them.
            keyValidationSucceeded = false
            keyValidationFailureMessage = nil
        }
    }

    private var providerCard: some View {
        SettingsCard(title: "Provider", icon: "cpu",
                     subtitle: "Pick the API family your key belongs to — fields adapt") {
            ProviderCardPair(selection: Binding(
                get: { appState.aiProvider },
                set: { appState.setAIProvider($0) }))
        }
    }

    private var keyValidationBaseURL: String {
        appState.aiProvider == .gemini
            ? AIProvider.geminiValidationBaseURL
            : (appState.apiBaseURL.isEmpty ? AppState.defaultAPIBaseURL : appState.apiBaseURL)
    }

    private var apiKeyCard: some View {
        SettingsCard(title: appState.aiProvider == .gemini ? "Gemini API Key" : "Provider API Key",
                     icon: "key.fill",
                     subtitle: appState.aiProvider == .gemini
                         ? "One key for transcription, live streaming and context — aistudio.google.com"
                         : "Paste the API key of your OpenAI-compatible speech provider") {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    SecureField(appState.aiProvider == .gemini ? "Paste your Gemini API key" : "Enter your Groq API key",
                                text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .onChange(of: apiKeyInput) { _ in
                            keyValidationSucceeded = false
                            keyValidationFailureMessage = nil
                        }
                    Button(isValidatingKey ? "Validating..." : "Save") {
                        validateAndSaveKey()
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingKey)
                }
                if keyValidationSucceeded {
                    Label("API key saved", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
                if let keyValidationFailureMessage {
                    Text(keyValidationFailureMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func validateAndSaveKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isValidatingKey = true
        keyValidationSucceeded = false
        keyValidationFailureMessage = nil
        let baseURL = keyValidationBaseURL
        Task {
            let outcome = await TranscriptionService.validateAPIKey(trimmed, baseURL: baseURL)
            await MainActor.run {
                isValidatingKey = false
                switch outcome {
                case .valid:
                    appState.apiKey = trimmed
                    keyValidationSucceeded = true
                case .invalidKey:
                    keyValidationFailureMessage = "The provider rejected this API key. Check the key and provider settings, then try again."
                case .unavailable(let detail):
                    keyValidationFailureMessage = "Provider is unreachable — check your connection. \(detail)"
                }
            }
        }
    }
}
