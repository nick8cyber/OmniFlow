import SwiftUI

// Processing tab: what happens to the transcript between speech and paste.
// Cleanup, prompts and the instruction guard are hidden only while Gemini's
// smart mode does the polishing itself; a Gemini verbatim transcript goes
// through OmniFlow's own cleanup, so the cards apply there too.
// Vocabulary and context are common.

struct ProcessingSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if appState.aiProvider == .gemini && appState.geminiTranscriptionMode == .smart {
                    InfoBanner(icon: "sparkles",
                               text: "Gemini provider active in Smart mode. Cleanup is built into the transcription — switch Transcription Mode to Verbatim on the AI Provider tab to use OmniFlow's own cleanup.")
                } else {
                    CleanupCard()
                    SystemPromptCard()
                    InstructionGuardCard()
                }
                VocabularyCard()
                ContextPromptCard()
            }
            .padding(20)
        }
    }
}

private struct CleanupCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: "Cleanup", icon: "sparkles") {
            VStack(spacing: 8) {
                FormRow(title: "LLM cleanup") {
                    Toggle("", isOn: Binding(
                        get: { !appState.preserveExactWording },
                        set: { appState.preserveExactWording = !$0 }))
                        .toggleStyle(.switch)
                }
                Text("When off, your words are pasted verbatim with no LLM cleanup. Voice macros and Edit Mode still work. Output Language still translates, but literally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct InstructionGuardCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(title: "Safety", icon: "shield.lefthalf.filled") {
            VStack(spacing: 8) {
                FormRow(title: "Prevent dictated prompts from being executed") {
                    Toggle("", isOn: $appState.instructionExecutionGuardEnabled)
                        .toggleStyle(.switch)
                }
                Text("If post-processing looks like it answered your dictation instead of cleaning it, OmniFlow retries and falls back to the literal transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct VocabularyCard: View {
    @EnvironmentObject private var appState: AppState

    @State private var draft = ""
    @State private var notice: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        SettingsCard(title: "Custom Vocabulary", icon: "text.book.closed.fill",
                     subtitle: "Names, jargon, and spellings the model should prefer") {
            VStack(spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .focused($fieldFocused)
                    .onExitCommand {
                        commit()
                    }
                HStack {
                    Text("Separate terms with commas, new lines, or semicolons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add from Clipboard") {
                        // Commit the draft first: with the editor focused, the
                        // external-write sync is suppressed and onDisappear
                        // would otherwise roll the added term back.
                        commit()
                        if appState.pasteWordToVocabulary() != nil {
                            VocabularyNotificationManager.shared.flashCheckmark()
                            notice = nil
                        } else {
                            notice = "Nothing to add — the clipboard is empty or its words are already in the vocabulary."
                        }
                    }
                    .font(.caption)
                }
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .onAppear {
            draft = appState.customVocabulary
        }
        .onDisappear {
            commit()
        }
        .onChange(of: appState.customVocabulary) { newValue in
            // External writes (e.g. vocabulary added elsewhere) must not be
            // rolled back by the onDisappear commit.
            if !fieldFocused {
                draft = newValue
            }
        }
    }

    private func commit() {
        appState.customVocabulary = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SystemPromptCard: View {
    @EnvironmentObject private var appState: AppState

    @State private var draft = ""
    @State private var showDefault = false
    @State private var testInput = "Um, so I was like, thinking we should uh, refactor the authentication module, you know?"
    @State private var testRunning = false
    @State private var testResult: String?
    @State private var testPrompt: String?
    @State private var testError: String?

    var body: some View {
        SettingsCard(title: "System Prompt", icon: "text.bubble.fill",
                     subtitle: "How the LLM cleans your raw transcript") {
            VStack(spacing: 10) {
                promptStatusBadge(custom: appState.customSystemPrompt)
                TextEditor(text: $draft)
                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .onExitCommand { commit() }
                HStack {
                    if !appState.customSystemPrompt.isEmpty {
                        Button("Reset to Default") {
                            appState.customSystemPrompt = ""
                            appState.customSystemPromptLastModified = ""
                            draft = PostProcessingService.defaultSystemPrompt
                        }
                    }
                    Spacer()
                    Button {
                        showDefault.toggle()
                    } label: {
                        Text(showDefault ? "Hide Default" : "View Default")
                    }
                }
                if showDefault {
                    ScrollView {
                        Text(PostProcessingService.defaultSystemPrompt)
                            .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                }
                newerDefaultNotice(custom: appState.customSystemPrompt,
                                   lastModified: appState.customSystemPromptLastModified,
                                   defaultDate: PostProcessingService.defaultSystemPromptDate,
                                   reset: {
                                       appState.customSystemPrompt = ""
                                       appState.customSystemPromptLastModified = ""
                                       draft = PostProcessingService.defaultSystemPrompt
                                   })
                Divider()
                Text("Test how the prompt cleans a raw transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Test transcript", text: $testInput)
                    .textFieldStyle(.roundedBorder)
                Button {
                    runTest()
                } label: {
                    HStack(spacing: 6) {
                        if testRunning {
                            ProgressView().controlSize(.small)
                            Text("Running...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Test System Prompt")
                        }
                    }
                }
                .disabled(testRunning || appState.apiKey.isEmpty || testInput.isEmpty)
                if appState.apiKey.isEmpty {
                    Label("API key required to test", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if let testError {
                    Label(testError, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                if let testResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Result: \(testResult.isEmpty ? "(empty — no output)" : testResult)",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        if let testPrompt {
                            DisclosureGroup("Full prompt sent") {
                                ScrollView {
                                    Text(testPrompt)
                                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 160)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .onAppear {
            draft = appState.customSystemPrompt.isEmpty
                ? PostProcessingService.defaultSystemPrompt
                : appState.customSystemPrompt
        }
        .onDisappear {
            commit()
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == PostProcessingService.defaultSystemPrompt {
            appState.customSystemPrompt = ""
            appState.customSystemPromptLastModified = ""
        } else {
            appState.customSystemPrompt = trimmed
            appState.customSystemPromptLastModified = Self.dateFormatter.string(from: Date())
        }
    }

    private func runTest() {
        commit()
        testRunning = true
        testResult = nil
        testPrompt = nil
        testError = nil
        let service = PostProcessingService(
            apiKey: appState.apiKey,
            baseURL: appState.resolvedLLMBaseURL,
            preferredModel: appState.postProcessingModel,
            preferredFallbackModel: appState.postProcessingFallbackModel,
            instructionExecutionGuardEnabled: appState.instructionExecutionGuardEnabled)
        let context = AppContext(appName: "\(AppName.displayName) Settings",
                                 bundleIdentifier: "com.nick8cyber.omniflow",
                                 windowTitle: "System Prompt Test",
                                 selectedText: nil,
                                 currentActivity: "User is testing the system prompt in \(AppName.displayName) settings.",
                                 contextSystemPrompt: nil,
                                 contextPrompt: nil,
                                 screenshotDataURL: nil,
                                 screenshotMimeType: nil,
                                 screenshotError: nil)
        let vocabulary = appState.customVocabulary
        let prompt = appState.customSystemPrompt
        Task {
            do {
                let result = try await service.postProcess(transcript: testInput,
                                                           context: context,
                                                           customVocabulary: vocabulary,
                                                           customSystemPrompt: prompt)
                await MainActor.run {
                    testRunning = false
                    testResult = result.transcript
                    testPrompt = result.prompt
                }
            } catch {
                await MainActor.run {
                    testRunning = false
                    testError = error.localizedDescription
                }
            }
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct ContextPromptCard: View {
    @EnvironmentObject private var appState: AppState

    @State private var draft = ""
    @State private var showDefault = false
    @State private var testRunning = false
    @State private var testSummary: String?
    @State private var testPrompt: String?
    @State private var testError: String?

    var body: some View {
        SettingsCard(title: "Context Prompt", icon: "eye.fill",
                     subtitle: "How OmniFlow reads the target app's on-screen context") {
            VStack(spacing: 10) {
                promptStatusBadge(custom: appState.customContextPrompt)
                TextEditor(text: $draft)
                    .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .onExitCommand { commit() }
                HStack {
                    if !appState.customContextPrompt.isEmpty {
                        Button("Reset to Default") {
                            appState.customContextPrompt = ""
                            appState.customContextPromptLastModified = ""
                            draft = AppContextService.defaultContextPrompt
                        }
                    }
                    Spacer()
                    Button {
                        showDefault.toggle()
                    } label: {
                        Text(showDefault ? "Hide Default" : "View Default")
                    }
                }
                if showDefault {
                    ScrollView {
                        Text(AppContextService.defaultContextPrompt)
                            .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                }
                newerDefaultNotice(custom: appState.customContextPrompt,
                                   lastModified: appState.customContextPromptLastModified,
                                   defaultDate: AppContextService.defaultContextPromptDate,
                                   reset: {
                                       appState.customContextPrompt = ""
                                       appState.customContextPromptLastModified = ""
                                       draft = AppContextService.defaultContextPrompt
                                   })
                Divider()
                Picker("Screenshot Resolution", selection: $appState.contextScreenshotMaxDimension) {
                    ForEach(AppState.contextScreenshotDimensionOptions, id: \.self) { dimension in
                        Text("\(dimension) px").tag(dimension)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text(appState.contextScreenshotMaxDimension
                        == AppState.defaultContextScreenshotMaxDimension ? "Using default" : "Using custom value")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if appState.contextScreenshotMaxDimension
                        != AppState.defaultContextScreenshotMaxDimension {
                        Button("Reset to Default") {
                            appState.contextScreenshotMaxDimension = AppState.defaultContextScreenshotMaxDimension
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
                Divider()
                Button {
                    runTest()
                } label: {
                    HStack(spacing: 6) {
                        if testRunning {
                            ProgressView().controlSize(.small)
                            Text("Running...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Test Context Prompt")
                        }
                    }
                }
                .disabled(testRunning || appState.apiKey.isEmpty)
                if let testError {
                    Label(testError, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                if let testSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result:")
                            .font(.caption.weight(.semibold))
                        Text(testSummary)
                            .font(.caption)
                        if let testPrompt {
                            DisclosureGroup("Full prompt sent") {
                                ScrollView {
                                    Text(testPrompt)
                                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 160)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .onAppear {
            draft = appState.customContextPrompt.isEmpty
                ? AppContextService.defaultContextPrompt
                : appState.customContextPrompt
        }
        .onDisappear {
            commit()
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == AppContextService.defaultContextPrompt {
            appState.customContextPrompt = ""
            appState.customContextPromptLastModified = ""
        } else {
            appState.customContextPrompt = trimmed
            appState.customContextPromptLastModified = SystemPromptCard.dateFormatter.string(from: Date())
        }
    }

    private func runTest() {
        commit()
        testRunning = true
        testSummary = nil
        testPrompt = nil
        testError = nil
        let service = appState.makeAppContextService()
        Task {
            let context = await service.collectContext()
            await MainActor.run {
                testRunning = false
                testSummary = context.currentActivity
                testPrompt = context.contextPrompt
                if context.contextPrompt == nil {
                    testError = "Context inference returned no result. This may be a permissions issue or the API could not be reached."
                }
            }
        }
    }
}
