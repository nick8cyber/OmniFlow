import SwiftUI
import AVFoundation

// Shared building blocks used by more than one Settings tab (and by the
// Setup wizard's provider sheet).

// MARK: - Microphone row

struct MicrophoneOptionRow: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(title)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permission row (General tab)

struct PermissionStatusRow: View {
    let icon: String
    let title: String
    let granted: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(title)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant Access", action: onGrant)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Rate-limit cooldown warning

struct CooldownWarningView: View {
    let model: String
    let message: (String) -> String

    @State private var now = Date()
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let expiry = UserDefaults.standard.object(forKey: LLMCooldownManager.udKey(for: model)) as? Double
        Group {
            if let expiry, expiry > now.timeIntervalSince1970 {
                Label(message(Self.formatTime(Date(timeIntervalSince1970: expiry))),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onReceive(timer) { date in
            now = date
        }
    }

    private static func formatTime(_ date: Date) -> String {
        let sameDay = Calendar.current.isDate(date, inSameDayAs: Date())
        return date.formatted(date: sameDay ? .omitted : .abbreviated,
                              time: .shortened)
    }
}

// MARK: - Prompt status helpers

func promptStatusBadge(custom: String) -> some View {
    HStack {
        if custom.isEmpty {
            Label("Using default", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Using custom prompt", systemImage: "pencil")
                .font(.caption)
                .foregroundColor(.blue)
        }
        Spacer()
    }
}

func newerDefaultNotice(custom: String, lastModified: String, defaultDate: String,
                        reset: @escaping () -> Void) -> some View {
    Group {
        if !custom.isEmpty && !lastModified.isEmpty && lastModified < defaultDate {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.blue)
                Text("A newer default prompt is available.")
                    .font(.caption)
                Spacer()
                Button("Switch to Default", action: reset)
                    .font(.caption)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
        }
    }
}

// MARK: - Provider fields
//
// The provider switch is the primary fork: Gemini needs one key and no
// cleanup configuration, OpenAI-compatible endpoints need models for every
// stage. Rendered by the AI Provider tab and by the Setup wizard's sheet.

struct ProviderSettingsFields: View {
    @EnvironmentObject private var appState: AppState
    var showsModelDescription = false

    var body: some View {
        switch appState.aiProvider {
        case .gemini:
            GeminiProviderFields(showsModelDescription: showsModelDescription)
        case .openAICompatible:
            OpenAIProviderFields(showsModelDescription: showsModelDescription)
        }
    }
}

struct GeminiProviderFields: View {
    @EnvironmentObject private var appState: AppState
    let showsModelDescription: Bool

    @State private var transcriptionModelDraft = AIProvider.geminiBatchModel
    @State private var realtimeModelDraft = AIProvider.geminiLiveModel
    @State private var contextModelDraft = AppState.defaultContextModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsModelDescription {
                Text("Gemini handles transcription and cleanup natively; the model IDs below are used against the Gemini API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ModelDropdownView(title: "Batch Transcription Model",
                              subtitle: "File-based fallback transcription when Live streaming is unavailable.",
                              predefinedModels: ModelConfiguration.transcriptionModels,
                              defaultModel: AIProvider.geminiBatchModel,
                              textDraft: $transcriptionModelDraft,
                              onCommit: { appState.transcriptionModel = normalized(transcriptionModelDraft) },
                              onReset: {
                                  transcriptionModelDraft = AIProvider.geminiBatchModel
                                  appState.transcriptionModel = AIProvider.geminiBatchModel
                              })
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Stream audio while recording (Gemini Live)", isOn: $appState.realtimeStreamingEnabled)
                Text("Streams microphone audio to Gemini Live over a WebSocket while recording, falling back to the batch model when the stream fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ModelDropdownView(title: "Live Model",
                              subtitle: "Realtime streaming model.",
                              predefinedModels: ModelConfiguration.transcriptionModels,
                              defaultModel: AIProvider.geminiLiveModel,
                              textDraft: $realtimeModelDraft,
                              onCommit: { appState.realtimeStreamingModel = normalized(realtimeModelDraft) },
                              onReset: {
                                  realtimeModelDraft = AIProvider.geminiLiveModel
                                  appState.realtimeStreamingModel = AIProvider.geminiLiveModel
                              })
            ModelDropdownView(title: "Context Model",
                              subtitle: "Used for context inference, with a text-only retry when screenshot analysis fails. Screenshot analysis requires a model that accepts image input.",
                              predefinedModels: ModelConfiguration.visionModels,
                              defaultModel: AppState.defaultContextModel,
                              textDraft: $contextModelDraft,
                              onCommit: { appState.contextModel = normalized(contextModelDraft) },
                              onReset: {
                                  contextModelDraft = AppState.defaultContextModel
                                  appState.contextModel = AppState.defaultContextModel
                              })
        }
        .onAppear(perform: reloadDrafts)
        .onChange(of: appState.transcriptionModel) { newValue in
            if !isEditing(transcriptionModelDraft, appState.transcriptionModel) { transcriptionModelDraft = newValue }
        }
        .onChange(of: appState.realtimeStreamingModel) { newValue in
            if !isEditing(realtimeModelDraft, appState.realtimeStreamingModel) { realtimeModelDraft = newValue }
        }
    }

    private func isEditing(_ draft: String, _ committed: String) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != committed
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reloadDrafts() {
        transcriptionModelDraft = appState.transcriptionModel
        realtimeModelDraft = appState.realtimeStreamingModel
        contextModelDraft = appState.contextModel
    }
}

struct OpenAIProviderFields: View {
    @EnvironmentObject private var appState: AppState
    let showsModelDescription: Bool

    @State private var baseURLDraft = ""
    @State private var postProcessingModelDraft = AppState.defaultPostProcessingModel
    @State private var postProcessingFallbackModelDraft = AppState.defaultPostProcessingFallbackModel
    @State private var contextModelDraft = AppState.defaultContextModel
    @State private var transcriptionModelDraft = AppState.defaultTranscriptionModel
    @State private var transcriptionAPIURLDraft = ""
    @State private var transcriptionAPIKeyDraft = ""
    @State private var realtimeModelDraft = ""
    @FocusState private var baseURLFieldFocused: Bool
    @FocusState private var transcriptionAPIURLFieldFocused: Bool
    @FocusState private var transcriptionAPIKeyFieldFocused: Bool
    @FocusState private var realtimeModelFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsModelDescription {
                Text("If you use another provider, enter that provider's model IDs here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("API Base URL")
                    .font(.caption.weight(.semibold))
                Text("Change this to use a different OpenAI-compatible API provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField(AppState.defaultAPIBaseURL, text: $baseURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .focused($baseURLFieldFocused)
                        .onSubmit(commitBaseURL)
                    Button("Reset to Default") {
                        baseURLDraft = ""
                        commitBaseURL()
                    }
                    .font(.caption)
                }
                .onChange(of: baseURLFieldFocused) { focused in
                    if !focused { commitBaseURL() }
                }
            }

            ModelDropdownView(title: "Transcription Model",
                              subtitle: "Used for speech-to-text transcription.",
                              predefinedModels: ModelConfiguration.transcriptionModels,
                              defaultModel: AppState.defaultTranscriptionModel,
                              textDraft: $transcriptionModelDraft,
                              onCommit: { appState.transcriptionModel = normalized(transcriptionModelDraft) },
                              onReset: {
                                  transcriptionModelDraft = AppState.defaultTranscriptionModel
                                  appState.transcriptionModel = AppState.defaultTranscriptionModel
                              })
            ModelDropdownView(title: "Post-Processing Model",
                              subtitle: "Used for transcript cleanup and Edit Mode transforms.",
                              predefinedModels: ModelConfiguration.llmModels,
                              defaultModel: AppState.defaultPostProcessingModel,
                              textDraft: $postProcessingModelDraft,
                              onCommit: { appState.postProcessingModel = normalized(postProcessingModelDraft) },
                              onReset: {
                                  postProcessingModelDraft = AppState.defaultPostProcessingModel
                                  appState.postProcessingModel = AppState.defaultPostProcessingModel
                              })
            CooldownWarningView(model: appState.postProcessingModel,
                                message: { time in "Daily limit reached — resets at \(time)" })
            ModelDropdownView(title: "Post-Processing Fallback Model",
                              subtitle: "Used as the explicit retry model when the primary model fails.",
                              predefinedModels: ModelConfiguration.llmModels,
                              defaultModel: AppState.defaultPostProcessingFallbackModel,
                              textDraft: $postProcessingFallbackModelDraft,
                              onCommit: { appState.postProcessingFallbackModel = normalized(postProcessingFallbackModelDraft) },
                              onReset: {
                                  postProcessingFallbackModelDraft = AppState.defaultPostProcessingFallbackModel
                                  appState.postProcessingFallbackModel = AppState.defaultPostProcessingFallbackModel
                              })
            CooldownWarningView(model: appState.postProcessingFallbackModel,
                                message: { time in "Fallback daily limit reached — resets at \(time)" })
            ModelDropdownView(title: "Context Model",
                              subtitle: "Used for context inference, with a text-only retry when screenshot analysis fails. Screenshot analysis requires a model that accepts image input.",
                              predefinedModels: ModelConfiguration.visionModels,
                              defaultModel: AppState.defaultContextModel,
                              textDraft: $contextModelDraft,
                              onCommit: { appState.contextModel = normalized(contextModelDraft) },
                              onReset: {
                                  contextModelDraft = AppState.defaultContextModel
                                  appState.contextModel = AppState.defaultContextModel
                              })

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription API URL")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Uses API Base URL when empty", text: $transcriptionAPIURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .focused($transcriptionAPIURLFieldFocused)
                        .onSubmit(commitTranscriptionAPIURL)
                    if !transcriptionAPIURLDraft.isEmpty {
                        Button("Clear") {
                            transcriptionAPIURLDraft = ""
                            commitTranscriptionAPIURL()
                        }
                        .font(.caption)
                    }
                }
                .onChange(of: transcriptionAPIURLFieldFocused) { focused in
                    if !focused { commitTranscriptionAPIURL() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription API Key")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    SecureField("Uses API Key when empty", text: $transcriptionAPIKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .focused($transcriptionAPIKeyFieldFocused)
                        .onSubmit(commitTranscriptionAPIKey)
                    if !transcriptionAPIKeyDraft.isEmpty {
                        Button("Clear") {
                            transcriptionAPIKeyDraft = ""
                            commitTranscriptionAPIKey()
                        }
                        .font(.caption)
                    }
                }
                .onChange(of: transcriptionAPIKeyFieldFocused) { focused in
                    if !focused { commitTranscriptionAPIKey() }
                }
            }

            Divider()

            Toggle("Stream audio while recording (realtime)", isOn: $appState.realtimeStreamingEnabled)
            Text("Streams microphone audio over the provider's /v1/realtime WebSocket while recording, falling back to file transcription when the stream fails.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Realtime Transcription Model")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Required by some providers, e.g. gpt-4o-transcribe", text: $realtimeModelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: NSFont.systemFontSize(for: .small), design: .monospaced))
                        .focused($realtimeModelFieldFocused)
                        .onSubmit(commitRealtimeModel)
                    if !realtimeModelDraft.isEmpty {
                        Button("Reset") {
                            realtimeModelDraft = ""
                            commitRealtimeModel()
                        }
                        .font(.caption)
                    }
                }
                .onChange(of: realtimeModelFieldFocused) { focused in
                    if !focused { commitRealtimeModel() }
                }
                Text("Used only for realtime streaming; the file pipeline always uses the Transcription Model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reloadDrafts)
        .onChange(of: appState.postProcessingModel) { newValue in
            if !isEditing(postProcessingModelDraft, appState.postProcessingModel) { postProcessingModelDraft = newValue }
        }
        .onChange(of: appState.transcriptionAPIURL) { newValue in
            if !transcriptionAPIURLFieldFocused { transcriptionAPIURLDraft = newValue }
        }
        .onChange(of: appState.transcriptionAPIKey) { newValue in
            if !transcriptionAPIKeyFieldFocused { transcriptionAPIKeyDraft = newValue }
        }
    }

    private func isEditing(_ draft: String, _ committed: String) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != committed
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reloadDrafts() {
        baseURLDraft = appState.apiBaseURL
        postProcessingModelDraft = appState.postProcessingModel
        postProcessingFallbackModelDraft = appState.postProcessingFallbackModel
        contextModelDraft = appState.contextModel
        transcriptionModelDraft = appState.transcriptionModel
        transcriptionAPIURLDraft = appState.transcriptionAPIURL
        transcriptionAPIKeyDraft = appState.transcriptionAPIKey
        realtimeModelDraft = appState.realtimeStreamingModel
    }

    private func commitBaseURL() {
        let trimmed = normalized(baseURLDraft)
        appState.apiBaseURL = trimmed
        baseURLDraft = trimmed
    }

    private func commitTranscriptionAPIURL() {
        let trimmed = normalized(transcriptionAPIURLDraft)
        appState.transcriptionAPIURL = trimmed
        transcriptionAPIURLDraft = trimmed
    }

    private func commitTranscriptionAPIKey() {
        let trimmed = normalized(transcriptionAPIKeyDraft)
        appState.transcriptionAPIKey = trimmed
        transcriptionAPIKeyDraft = trimmed
    }

    private func commitRealtimeModel() {
        appState.realtimeStreamingModel = normalized(realtimeModelDraft)
    }
}
