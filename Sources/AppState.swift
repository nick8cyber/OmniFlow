import Foundation
import AppKit
import Combine
import AVFoundation
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement
import os.log

// MARK: - Supporting types (contracts 01 §2.1)

struct VoiceMacro: Codable, Identifiable, Equatable {
    var id = UUID()
    var command: String
    var payload: String
}

struct PrecomputedMacro {
    let original: VoiceMacro
    let normalizedCommand: String
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, prompts, macros, runLog, debug

    var id: String { rawValue }

    static var visibleCases: [SettingsTab] {
        AppBuild.isDevBundle ? allCases : allCases.filter { $0 != .debug }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .prompts: return "Prompts"
        case .macros: return "Voice Macros"
        case .runLog: return "Run Log"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .prompts: return "text.bubble"
        case .macros: return "music.mic"
        case .runLog: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

enum AppBuild {
    static var isDevBundle: Bool {
        let name = Bundle.main.infoDictionary?["CFBundleName"] as? String
        return name == "OmniFlow Dev"
    }
}

// MARK: - Private pipeline types

private struct PreservedPasteboardEntry {
    enum Value {
        case string(String)
        case propertyList(Any)
        case data(Data)
    }

    let type: NSPasteboard.PasteboardType
    let value: Value
}

private struct PreservedPasteboardItem {
    let entries: [PreservedPasteboardEntry]

    init(item: NSPasteboardItem) {
        var collected: [PreservedPasteboardEntry] = []
        for type in item.types {
            // Order per spec 00 §4.9: string, then property list, then raw
            // data — same priority as the reference.
            if let string = item.string(forType: type) {
                collected.append(PreservedPasteboardEntry(type: type, value: .string(string)))
            } else if let propertyList = item.propertyList(forType: type) {
                collected.append(PreservedPasteboardEntry(type: type, value: .propertyList(propertyList)))
            } else if let data = item.data(forType: type) {
                collected.append(PreservedPasteboardEntry(type: type, value: .data(data)))
            }
        }
        entries = collected
    }

    func makePasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for entry in entries {
            switch entry.value {
            case .string(let string):
                item.setString(string, forType: entry.type)
            case .data(let data):
                item.setData(data, forType: entry.type)
            case .propertyList(let propertyList):
                item.setPropertyList(propertyList, forType: entry.type)
            }
        }
        return item
    }
}

private struct PreservedPasteboardSnapshot {
    let items: [PreservedPasteboardItem]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { PreservedPasteboardItem(item: $0) }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map { $0.makePasteboardItem() })
    }
}

private struct PendingClipboardRestore {
    let snapshot: PreservedPasteboardSnapshot
    let expectedChangeCount: Int
    let writtenTranscript: String
}

// Transcript command parsing (press-enter tail) lives in TranscriptTextCore
// as `TranscriptCommandParsing` so the pure parser is covered by the test
// suite; this file only consumes its result.

private enum CommandInvocation: String {
    case automatic, manual
}

private enum SessionIntent {
    case dictation
    case command(invocation: CommandInvocation, selectedText: String)

    var isCommandMode: Bool {
        if case .command = self { return true }
        return false
    }

    var isManualCommand: Bool {
        if case .command(let invocation, _) = self { return invocation == .manual }
        return false
    }

    var persistedIntent: PipelineHistoryItemIntent {
        switch self {
        case .dictation: return .dictation
        case .command(let invocation, _):
            return invocation == .automatic ? .commandAutomatic : .commandManual
        }
    }

    var persistedSelectedText: String? {
        if case .command(_, let selectedText) = self { return selectedText }
        return nil
    }

    static func fromPersisted(intent: PipelineHistoryItemIntent, selectedText: String?) -> SessionIntent {
        switch intent {
        case .dictation:
            return .dictation
        case .commandAutomatic:
            guard let selectedText, !selectedText.isEmpty else { return .dictation }
            return .command(invocation: .automatic, selectedText: selectedText)
        case .commandManual:
            guard let selectedText, !selectedText.isEmpty else { return .dictation }
            return .command(invocation: .manual, selectedText: selectedText)
        }
    }
}

private enum TranscriptProcessingOutcome {
    case skippedEmptyRawTranscript
    case voiceMacro(command: String)
    case postProcessingSucceeded
    case postProcessingSkippedCooldown
    case postProcessingFailedFallback
    case preservedExactWording
    case preservedExactWordingTranslated
    case preservedExactWordingTranslationFailedFallback
    case commandModeSucceeded(invocation: CommandInvocation)
    case commandModeFailedFallback(invocation: CommandInvocation)

    func statusMessage(isRetry: Bool = false) -> String {
        switch self {
        case .skippedEmptyRawTranscript:
            return "Skipped macros and post-processing for empty raw transcript"
        case .voiceMacro(let command):
            return "Voice macro used: \(command)"
        case .postProcessingSucceeded:
            return isRetry ? "Post-processing succeeded (retried)" : "Post-processing succeeded"
        case .postProcessingSkippedCooldown:
            return isRetry ? "Skipped — cooldown (retried)" : "Skipped — cooldown"
        case .postProcessingFailedFallback:
            return isRetry ? "Post-processing failed on retry, using raw transcript"
                : "Post-processing failed, using raw transcript"
        case .preservedExactWording:
            return "Preserved exact wording, skipped post-processing"
        case .preservedExactWordingTranslated:
            return "Preserved exact wording, translated to output language"
        case .preservedExactWordingTranslationFailedFallback:
            return "Verbatim translation failed, using untranslated raw transcript"
        case .commandModeSucceeded(let invocation):
            return "Edit mode succeeded (\(invocation.rawValue))"
        case .commandModeFailedFallback(let invocation):
            return "Edit mode failed, using selected text (\(invocation.rawValue))"
        }
    }
}

private enum AudioInterruption {
    case muted(previouslyMuted: Bool)
}

// MARK: - AppState

final class AppState: ObservableObject, @unchecked Sendable {
    private static let appLog = OSLog(subsystem: "com.nick8cyber.omniflow", category: "Recording")

    // MARK: Constants

    static let defaultContextScreenshotMaxDimension = 1024
    static let contextScreenshotDimensionOptions = [1024, 768, 640, 512]
    static let defaultTranscriptionModel = "whisper-large-v3"
    static let transcriptionLanguageOptions: [(code: String, name: String)] = [
        ("", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
        ("ar", "Arabic"), ("hi", "Hindi"), ("tr", "Turkish"), ("pl", "Polish"),
        ("uk", "Ukrainian"), ("sv", "Swedish"), ("no", "Norwegian"), ("da", "Danish"),
        ("fi", "Finnish"), ("cs", "Czech"), ("el", "Greek"), ("he", "Hebrew"),
        ("vi", "Vietnamese"), ("th", "Thai"), ("id", "Indonesian"), ("ro", "Romanian"),
        ("hu", "Hungarian"), ("ca", "Catalan"),
    ]
    static let defaultPostProcessingModel = "openai/gpt-oss-20b"
    static let defaultPostProcessingFallbackModel = "qwen/qwen3.6-27b"
    static let defaultContextModel = "qwen/qwen3.6-27b"
    static let defaultAPIBaseURL = "https://api.groq.com/openai/v1"

    private let pasteAfterShortcutReleaseDelay: TimeInterval = 0.03
    private let pressEnterAfterPasteDelay: TimeInterval = 0.08
    private let clipboardRestoreDelay: TimeInterval = 1.0
    let maxPipelineHistoryCount = 20
    private let postTranscriptionUpdateReminderDuration: TimeInterval = 7

    private static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let autoGeneratedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    private static let legacyTransientPasteboardType = NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType")

    private static let deprecatedModelIdentifier = "meta-llama/llama-4-scout-17b-16e-instruct"

    // MARK: Published settings (persist on change)

    @Published var hasCompletedSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }
    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                AppSettingsStorage.delete(account: "groq_api_key")
            } else {
                AppSettingsStorage.save(apiKey, account: "groq_api_key")
            }
            rebuildContextService()
        }
    }
    @Published var apiBaseURL: String {
        didSet {
            let trimmed = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
                AppSettingsStorage.delete(account: "api_base_url")
            } else {
                AppSettingsStorage.save(trimmed, account: "api_base_url")
            }
            rebuildContextService()
        }
    }
    @Published var transcriptionAPIURL: String {
        didSet {
            // Trim before the emptiness check so a whitespace-only value is
            // deleted instead of persisted (same rule as apiBaseURL).
            let trimmed = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                AppSettingsStorage.delete(account: "transcription_api_url")
            } else {
                AppSettingsStorage.save(trimmed, account: "transcription_api_url")
            }
        }
    }
    @Published var transcriptionAPIKey: String {
        didSet {
            if transcriptionAPIKey.isEmpty {
                AppSettingsStorage.delete(account: "transcription_api_key")
            } else {
                AppSettingsStorage.save(transcriptionAPIKey, account: "transcription_api_key")
            }
        }
    }
    @Published var transcriptionModel: String {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: "transcription_model") }
    }
    @Published var postProcessingModel: String {
        didSet { UserDefaults.standard.set(postProcessingModel, forKey: "post_processing_model") }
    }
    @Published var postProcessingFallbackModel: String {
        didSet { UserDefaults.standard.set(postProcessingFallbackModel, forKey: "post_processing_fallback_model") }
    }
    @Published var contextModel: String {
        didSet {
            UserDefaults.standard.set(contextModel, forKey: "context_model")
            rebuildContextService()
        }
    }
    @Published var holdShortcut: ShortcutBinding {
        didSet { persistShortcut(holdShortcut, key: "hold_shortcut"); restartHotkeyMonitoring() }
    }
    @Published var toggleShortcut: ShortcutBinding {
        didSet { persistShortcut(toggleShortcut, key: "toggle_shortcut"); restartHotkeyMonitoring() }
    }
    @Published var copyAgainShortcut: ShortcutBinding {
        didSet { persistShortcut(copyAgainShortcut, key: "copy_again_shortcut"); restartHotkeyMonitoring() }
    }
    @Published private(set) var savedHoldCustomShortcut: ShortcutBinding? {
        didSet { persistOptionalShortcut(savedHoldCustomShortcut, key: "saved_hold_custom_shortcut") }
    }
    @Published private(set) var savedToggleCustomShortcut: ShortcutBinding? {
        didSet { persistOptionalShortcut(savedToggleCustomShortcut, key: "saved_toggle_custom_shortcut") }
    }
    @Published private(set) var savedCopyAgainCustomShortcut: ShortcutBinding? {
        didSet { persistOptionalShortcut(savedCopyAgainCustomShortcut, key: "saved_copy_again_custom_shortcut") }
    }
    @Published var isCommandModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCommandModeEnabled, forKey: "command_mode_enabled")
            restartHotkeyMonitoring()
        }
    }
    @Published var commandModeStyle: CommandModeStyle {
        didSet {
            UserDefaults.standard.set(commandModeStyle.rawValue, forKey: "command_mode_style")
            restartHotkeyMonitoring()
        }
    }
    @Published private(set) var commandModeManualModifier: CommandModeManualModifier {
        didSet {
            UserDefaults.standard.set(commandModeManualModifier.rawValue, forKey: "command_mode_manual_modifier")
            restartHotkeyMonitoring()
        }
    }
    @Published var customVocabulary: String {
        didSet { UserDefaults.standard.set(customVocabulary, forKey: "custom_vocabulary") }
    }
    @Published var transcriptionLanguage: String {
        didSet {
            let normalized = Self.normalizeTranscriptionLanguage(transcriptionLanguage)
            if normalized != transcriptionLanguage {
                transcriptionLanguage = normalized
                return
            }
            UserDefaults.standard.set(transcriptionLanguage, forKey: "transcription_language")
        }
    }
    @Published var customSystemPrompt: String {
        didSet { UserDefaults.standard.set(customSystemPrompt, forKey: "custom_system_prompt") }
    }
    @Published var customContextPrompt: String {
        didSet {
            UserDefaults.standard.set(customContextPrompt, forKey: "custom_context_prompt")
            rebuildContextService()
        }
    }
    @Published var instructionExecutionGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(instructionExecutionGuardEnabled,
                                      forKey: "instruction_execution_guard_enabled")
        }
    }
    @Published var contextScreenshotMaxDimension: Int {
        didSet {
            let normalized = Self.normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)
            if normalized != contextScreenshotMaxDimension {
                contextScreenshotMaxDimension = normalized
                return
            }
            UserDefaults.standard.set(contextScreenshotMaxDimension, forKey: "context_screenshot_max_dimension")
            rebuildContextService()
        }
    }
    @Published var customSystemPromptLastModified: String {
        didSet { UserDefaults.standard.set(customSystemPromptLastModified, forKey: "custom_system_prompt_last_modified") }
    }
    @Published var customContextPromptLastModified: String {
        didSet { UserDefaults.standard.set(customContextPromptLastModified, forKey: "custom_context_prompt_last_modified") }
    }
    @Published var outputLanguage: String {
        didSet { UserDefaults.standard.set(outputLanguage, forKey: "output_language") }
    }
    @Published var shortcutStartDelay: TimeInterval {
        didSet { UserDefaults.standard.set(max(0, shortcutStartDelay), forKey: "shortcut_start_delay") }
    }
    @Published var realtimeStreamingEnabled: Bool {
        didSet { UserDefaults.standard.set(realtimeStreamingEnabled, forKey: "realtime_streaming_enabled") }
    }
    @Published var realtimeStreamingModel: String {
        didSet { UserDefaults.standard.set(realtimeStreamingModel, forKey: "realtime_streaming_model") }
    }
    @Published var dictationAudioInterruptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(dictationAudioInterruptionEnabled,
                                      forKey: "dictation_audio_interruption_enabled")
        }
    }
    @Published var preserveClipboard: Bool {
        didSet { UserDefaults.standard.set(preserveClipboard, forKey: "preserve_clipboard") }
    }
    @Published var preserveExactWording: Bool {
        didSet { UserDefaults.standard.set(preserveExactWording, forKey: "preserve_exact_wording") }
    }
    @Published var keepDictationInClipboardHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepDictationInClipboardHistory,
                                      forKey: "keep_dictation_in_clipboard_history")
        }
    }
    @Published var isPressEnterVoiceCommandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPressEnterVoiceCommandEnabled,
                                      forKey: "press_enter_voice_command_enabled")
        }
    }
    @Published var alertSoundsEnabled: Bool {
        didSet { UserDefaults.standard.set(alertSoundsEnabled, forKey: "alert_sounds_enabled") }
    }
    @Published var soundVolume: Float {
        didSet { UserDefaults.standard.set(soundVolume, forKey: "sound_volume") }
    }
    @Published var voiceMacros: [VoiceMacro] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceMacros) {
                UserDefaults.standard.set(data, forKey: "voice_macros")
            }
            precomputeMacros()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    // MARK: Published runtime state

    @Published var isRecording = false {
        didSet {
            if oldValue != isRecording {
                Self.writeRecordingStateFlag(isRecording)
            }
        }
    }
    @Published var isTranscribing = false
    @Published var retryingItemIDs: Set<UUID> = []
    @Published var lastTranscript = ""
    @Published var errorMessage: String?
    @Published var statusText = "Ready"
    @Published var hasAccessibility = AXIsProcessTrusted()
    @Published var hotkeyMonitoringErrorMessage: String?
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var debugShowsUpdateReminderAfterDictation = false
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextSummary = ""
    @Published var lastContextScreenshotDataURL: String?
    @Published var lastContextScreenshotStatus = "No screenshot"
    @Published var lastContextAppName = ""
    @Published var lastContextBundleIdentifier = ""
    @Published var lastContextWindowTitle = ""
    @Published var lastContextSelectedText = ""
    @Published var lastContextLLMPrompt = ""
    @Published var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @Published var selectedMicrophoneID: String {
        didSet { UserDefaults.standard.set(selectedMicrophoneID, forKey: "selected_microphone_id") }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    // MARK: Service fields

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private(set) var contextService: AppContextService
    let pipelineHistoryStore = PipelineHistoryStore()
    let shortcutSessionController = DictationShortcutSessionController()
    private var realtimeService: (any RealtimeTranscriptBackend)?
    private var transcriptionTask: Task<Void, Never>?
    private var contextCaptureTask: Task<AppContext, Never>?
    private var capturedContext: AppContext?
    private var pendingShortcutStartTask: Task<Void, Never>?
    private var pendingShortcutStartMode: RecordingTriggerMode?
    private var pendingSelectionSnapshot: AppSelectionSnapshot?
    private var pendingManualCommandInvocation: Bool?
    private var activeRecordingTriggerMode: RecordingTriggerMode?
    private var currentSessionIntent: SessionIntent = .dictation
    private var capturedSelectionSnapshot: AppSelectionSnapshot?
    private var pendingOverlayDismissToken: UUID?
    private var activeAudioInterruption: AudioInterruption?
    private var isAwaitingMicrophonePermission = false
    private var pendingMicrophonePermissionTriggerMode: RecordingTriggerMode?
    private var pendingMicrophonePermissionSelectionSnapshot: AppSelectionSnapshot?
    private var pendingMicrophonePermissionManualCommandRequested: Bool?
    private var transcribingAudioFileName: String?
    private var precomputedMacros: [PrecomputedMacro] = []
    private var automaticTerminationDisabled = false
    private var shouldMonitorHotkeys = false
    private(set) var isCapturingShortcut = false
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: DispatchSourceTimer?
    private var recordingInitializationTimer: DispatchSourceTimer?
    private var initializingOverlayVisible = false
    private var audioDeviceObservers: [NSObjectProtocol] = []
    private var needsMicrophoneRefreshAfterRecording = false
    private var needsHotkeyRestartAfterRecording = false
    private var hasShownScreenshotPermissionAlert = false
    private var readyStatusResetWorkItem: DispatchWorkItem?

    // MARK: Init

    init() {
        UserDefaults.standard.removeObject(forKey: "force_http2_transcription")
        if UserDefaults.standard.string(forKey: "post_processing_fallback_model") == Self.deprecatedModelIdentifier {
            UserDefaults.standard.set(Self.defaultPostProcessingFallbackModel, forKey: "post_processing_fallback_model")
        }
        if UserDefaults.standard.string(forKey: "context_model") == Self.deprecatedModelIdentifier {
            UserDefaults.standard.set(Self.defaultContextModel, forKey: "context_model")
        }

        let legacyOption = ShortcutPreset(rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? "fn") ?? .fnKey
        holdShortcut = Self.loadShortcut("hold_shortcut", fallback: legacyOption.binding)
        toggleShortcut = Self.loadShortcut("toggle_shortcut", fallback: legacyOption.binding.withAddedModifiers(.command))
        copyAgainShortcut = Self.loadShortcut("copy_again_shortcut", fallback: .disabled)
        savedHoldCustomShortcut = Self.loadOptionalShortcut("saved_hold_custom_shortcut")
        savedToggleCustomShortcut = Self.loadOptionalShortcut("saved_toggle_custom_shortcut")
        savedCopyAgainCustomShortcut = Self.loadOptionalShortcut("saved_copy_again_custom_shortcut")

        hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        apiKey = AppSettingsStorage.load(account: "groq_api_key") ?? ""
        apiBaseURL = AppSettingsStorage.load(account: "api_base_url") ?? ""
        transcriptionAPIURL = (AppSettingsStorage.load(account: "transcription_api_url") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptionAPIKey = AppSettingsStorage.load(account: "transcription_api_key") ?? ""
        transcriptionModel = UserDefaults.standard.string(forKey: "transcription_model") ?? Self.defaultTranscriptionModel
        postProcessingModel = UserDefaults.standard.string(forKey: "post_processing_model") ?? Self.defaultPostProcessingModel
        postProcessingFallbackModel = UserDefaults.standard.string(forKey: "post_processing_fallback_model") ?? Self.defaultPostProcessingFallbackModel
        contextModel = UserDefaults.standard.string(forKey: "context_model") ?? Self.defaultContextModel
        isCommandModeEnabled = UserDefaults.standard.object(forKey: "command_mode_enabled") as? Bool
            ?? AppSettingsDefaults.commandModeEnabled
        commandModeStyle = CommandModeStyle(rawValue: UserDefaults.standard.string(forKey: "command_mode_style") ?? "") ?? .automatic
        commandModeManualModifier = CommandModeManualModifier(rawValue: UserDefaults.standard.string(forKey: "command_mode_manual_modifier") ?? "")
            ?? CommandModeManualModifier(rawValue: AppSettingsDefaults.commandModeManualModifierRawValue)
            ?? .option
        customVocabulary = UserDefaults.standard.string(forKey: "custom_vocabulary") ?? ""
        transcriptionLanguage = Self.normalizeTranscriptionLanguage(UserDefaults.standard.string(forKey: "transcription_language") ?? "")
        customSystemPrompt = UserDefaults.standard.string(forKey: "custom_system_prompt") ?? ""
        customContextPrompt = UserDefaults.standard.string(forKey: "custom_context_prompt") ?? ""
        instructionExecutionGuardEnabled = UserDefaults.standard.object(forKey: "instruction_execution_guard_enabled") as? Bool ?? true
        contextScreenshotMaxDimension = Self.normalizedContextScreenshotMaxDimension(
            UserDefaults.standard.object(forKey: "context_screenshot_max_dimension") as? Int ?? Self.defaultContextScreenshotMaxDimension)
        customSystemPromptLastModified = UserDefaults.standard.string(forKey: "custom_system_prompt_last_modified") ?? ""
        customContextPromptLastModified = UserDefaults.standard.string(forKey: "custom_context_prompt_last_modified") ?? ""
        outputLanguage = UserDefaults.standard.string(forKey: "output_language") ?? ""
        shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: "shortcut_start_delay"))
        realtimeStreamingEnabled = UserDefaults.standard.bool(forKey: "realtime_streaming_enabled")
        realtimeStreamingModel = UserDefaults.standard.string(forKey: "realtime_streaming_model") ?? ""
        dictationAudioInterruptionEnabled = UserDefaults.standard.bool(forKey: "dictation_audio_interruption_enabled")
        preserveClipboard = UserDefaults.standard.object(forKey: "preserve_clipboard") as? Bool ?? true
        preserveExactWording = UserDefaults.standard.bool(forKey: "preserve_exact_wording")
        keepDictationInClipboardHistory = UserDefaults.standard.bool(forKey: "keep_dictation_in_clipboard_history")
        isPressEnterVoiceCommandEnabled = UserDefaults.standard.object(forKey: "press_enter_voice_command_enabled") as? Bool ?? true
        let storedSoundVolume = UserDefaults.standard.object(forKey: "sound_volume") as? Float ?? 1.0
        soundVolume = storedSoundVolume
        alertSoundsEnabled = UserDefaults.standard.object(forKey: "alert_sounds_enabled") as? Bool
            ?? (storedSoundVolume > 0)
        voiceMacros = {
            guard let data = UserDefaults.standard.data(forKey: "voice_macros"),
                  let macros = try? JSONDecoder().decode([VoiceMacro].self, from: data) else { return [] }
            return macros
        }()
        selectedMicrophoneID = UserDefaults.standard.string(forKey: "selected_microphone_id") ?? "default"

        contextService = Self.makeAppContextService(
            apiKey: AppSettingsStorage.load(account: "groq_api_key") ?? "",
            baseURL: {
                let stored = AppSettingsStorage.load(account: "api_base_url") ?? ""
                return stored.isEmpty ? Self.defaultAPIBaseURL : stored
            }(),
            customContextPrompt: UserDefaults.standard.string(forKey: "custom_context_prompt") ?? "",
            contextModel: UserDefaults.standard.string(forKey: "context_model") ?? Self.defaultContextModel,
            contextScreenshotMaxDimension: Self.normalizedContextScreenshotMaxDimension(
                UserDefaults.standard.object(forKey: "context_screenshot_max_dimension") as? Int
                    ?? Self.defaultContextScreenshotMaxDimension))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        pipelineHistory = pipelineHistoryStore.loadAllHistory()
        availableMicrophones = AudioDevice.availableInputDevices()
        precomputeMacros()
        Self.writeRecordingStateFlag(false)

        overlayManager.onStopButtonPressed = { [weak self] in
            Task { @MainActor in
                self?.handleOverlayStopButtonPressed()
            }
        }
        overlayManager.onUpdateOverlayPressed = { [weak self] in
            Task { @MainActor in
                self?.handleUpdateOverlayPressed()
            }
        }

        let connectedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
            self?.refreshAvailableMicrophones()
        }
        let disconnectedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
            self?.refreshAvailableMicrophones()
        }
        audioDeviceObservers = [connectedObserver, disconnectedObserver]
    }

    deinit {
        Self.writeRecordingStateFlag(false)
        for observer in audioDeviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Shortcut persistence helpers

    private static func loadShortcut(_ key: String, fallback: ShortcutBinding) -> ShortcutBinding {
        if let data = UserDefaults.standard.data(forKey: key),
           let binding = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
            return binding
        }
        return fallback
    }

    private static func loadOptionalShortcut(_ key: String) -> ShortcutBinding? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ShortcutBinding.self, from: data)
    }

    private func persistShortcut(_ binding: ShortcutBinding, key: String) {
        if let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func persistOptionalShortcut(_ binding: ShortcutBinding?, key: String) {
        if let binding, let data = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func normalizeTranscriptionLanguage(_ value: String) -> String {
        guard transcriptionLanguageOptions.contains(where: { $0.code == value }) else { return "" }
        return value
    }

    private static func normalizedContextScreenshotMaxDimension(_ value: Int) -> Int {
        contextScreenshotDimensionOptions.contains(value) ? value : defaultContextScreenshotMaxDimension
    }

    // MARK: Hotkey monitoring

    func startHotkeyMonitoring() {
        shouldMonitorHotkeys = true
        hotkeyManager.onShortcutEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleShortcutEvent(event)
            }
        }
        hotkeyManager.onEscapeKeyPressed = { [weak self] in
            self?.handleEscapeKeyPress() ?? false
        }
        restartHotkeyMonitoring()
    }

    func stopHotkeyMonitoring() {
        shouldMonitorHotkeys = false
        hotkeyManager.stop()
    }

    func suspendHotkeyMonitoringForShortcutCapture() {
        isCapturingShortcut = true
        hotkeyManager.stop()
    }

    func resumeHotkeyMonitoringAfterShortcutCapture() {
        isCapturingShortcut = false
        restartHotkeyMonitoring()
    }

    private func restartHotkeyMonitoring() {
        guard shouldMonitorHotkeys, !isCapturingShortcut, !isAwaitingMicrophonePermission else { return }
        if isRecording {
            // Reinstalling the event tap mid-session emits backendReset, which
            // the matcher turns into holdDeactivated and stops the recording.
            // Defer the restart until the session ends.
            needsHotkeyRestartAfterRecording = true
            return
        }
        needsHotkeyRestartAfterRecording = false
        do {
            try hotkeyManager.start(configuration: activeShortcutConfiguration)
            hotkeyMonitoringErrorMessage = nil
        } catch {
            hotkeyMonitoringErrorMessage = error.localizedDescription
        }
    }

    private func flushDeferredHotkeyRestartIfNeeded() {
        guard needsHotkeyRestartAfterRecording, !isRecording else { return }
        needsHotkeyRestartAfterRecording = false
        restartHotkeyMonitoring()
    }

    private var activeShortcutConfiguration: ShortcutConfiguration {
        let permitted: ShortcutModifiers = (isCommandModeEnabled && commandModeStyle == .manual)
            ? commandModeManualModifier.shortcutModifier
            : []
        return ShortcutConfiguration(hold: holdShortcut,
                                     toggle: toggleShortcut,
                                     copyAgain: copyAgainShortcut,
                                     permittedAdditionalExactMatchModifiers: permitted)
    }

    // MARK: Shortcut status / validation

    var usesFnShortcut: Bool {
        holdShortcut.usesFnKey || toggleShortcut.usesFnKey
    }

    var hasEnabledHoldShortcut: Bool { !holdShortcut.isDisabled }
    var hasEnabledToggleShortcut: Bool { !toggleShortcut.isDisabled }

    var shortcutStatusText: String {
        if hotkeyMonitoringErrorMessage != nil {
            return "Global shortcuts unavailable"
        }
        switch (hasEnabledHoldShortcut, hasEnabledToggleShortcut) {
        case (true, true):
            return "Hold \(holdShortcut.displayName) or tap \(toggleShortcut.displayName) to dictate"
        case (true, false):
            return "Hold \(holdShortcut.displayName) to dictate"
        case (false, true):
            return "Tap \(toggleShortcut.displayName) to dictate"
        case (false, false):
            return "No dictation shortcut enabled"
        }
    }

    var shortcutStartDelayMilliseconds: Int {
        Int((shortcutStartDelay * 1000).rounded())
    }

    func savedCustomShortcut(for role: ShortcutRole) -> ShortcutBinding? {
        switch role {
        case .hold: return savedHoldCustomShortcut
        case .toggle: return savedToggleCustomShortcut
        case .copyAgain: return savedCopyAgainCustomShortcut
        }
    }

    var commandModeManualModifierValidationMessage: String? {
        guard isCommandModeEnabled, commandModeStyle == .manual else { return nil }
        return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
    }

    private func commandModeManualModifierCollisionMessage(for modifier: CommandModeManualModifier) -> String? {
        func collisionMessage(_ binding: ShortcutBinding, noun: String) -> String? {
            guard binding.kind == .modifierKey,
                  let bindingModifier = ShortcutBinding.modifier(forKeyCode: binding.keyCode),
                  bindingModifier == modifier.shortcutModifier else { return nil }
            if binding.modifiers == modifier.shortcutModifier {
                return "That modifier is already \(noun)."
            }
            return "That modifier is already part of \(noun)."
        }
        if hasEnabledHoldShortcut, let message = collisionMessage(holdShortcut, noun: "the hold shortcut") {
            return message
        }
        if hasEnabledToggleShortcut, let message = collisionMessage(toggleShortcut, noun: "the tap shortcut") {
            return message
        }
        if !copyAgainShortcut.isDisabled, let message = collisionMessage(copyAgainShortcut, noun: "the Paste Again shortcut") {
            return message
        }
        return nil
    }

    @discardableResult
    func setCommandModeEnabled(_ enabled: Bool) -> String? {
        isCommandModeEnabled = enabled
        return commandModeManualModifierValidationMessage
    }

    @discardableResult
    func setCommandModeStyle(_ style: CommandModeStyle) -> String? {
        commandModeStyle = style
        return commandModeManualModifierValidationMessage
    }

    @discardableResult
    func setCommandModeManualModifier(_ modifier: CommandModeManualModifier) -> String? {
        commandModeManualModifier = modifier
        return commandModeManualModifierValidationMessage
    }

    @discardableResult
    func setShortcut(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let message: String?
        switch role {
        case .hold:
            if binding.conflicts(with: toggleShortcut) {
                return "Hold and tap shortcuts must be distinct."
            }
            if binding.conflicts(with: copyAgainShortcut) {
                return "This shortcut is already used by Paste Again."
            }
            holdShortcut = binding
            if binding.isCustom { savedHoldCustomShortcut = binding }
            message = nil
        case .toggle:
            if binding.conflicts(with: holdShortcut) {
                return "Hold and tap shortcuts must be distinct."
            }
            if binding.conflicts(with: copyAgainShortcut) {
                return "This shortcut is already used by Paste Again."
            }
            toggleShortcut = binding
            if binding.isCustom { savedToggleCustomShortcut = binding }
            message = nil
        case .copyAgain:
            if binding.conflicts(with: holdShortcut) {
                return "Paste Again cannot share a shortcut with Hold to Talk."
            }
            if binding.conflicts(with: toggleShortcut) {
                return "Paste Again cannot share a shortcut with Tap to Toggle."
            }
            if binding.kind == .modifierKey,
               let bindingModifier = ShortcutBinding.modifier(forKeyCode: binding.keyCode),
               bindingModifier == commandModeManualModifier.shortcutModifier {
                return "Paste Again cannot share the Edit Mode modifier."
            }
            copyAgainShortcut = binding
            if binding.isCustom { savedCopyAgainCustomShortcut = binding }
            message = nil
        }
        restartHotkeyMonitoring()
        return message
    }

    // MARK: Trigger handling

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        if case .copyAgainTriggered = event {
            copyLastTranscriptToPasteboard()
            return
        }
        guard let action = shortcutSessionController.handle(event: event, isTranscribing: isTranscribing) else { return }
        switch action {
        case .start(let mode):
            scheduleShortcutStart(mode: mode)
        case .stop:
            cancelPendingShortcutStart()
            if !isRecording {
                shortcutSessionController.reset()
                activeRecordingTriggerMode = nil
            } else {
                stopAndTranscribe()
            }
        case .switchedToToggle:
            if isRecording {
                activeRecordingTriggerMode = .toggle
                overlayManager.setRecordingTriggerMode(.toggle, animated: true)
            } else if pendingShortcutStartMode != nil {
                pendingShortcutStartMode = .toggle
            }
        }
    }

    private func scheduleShortcutStart(mode: RecordingTriggerMode) {
        cancelPendingShortcutStart()
        pendingShortcutStartMode = mode
        pendingSelectionSnapshot = contextService.collectSelectionSnapshot()
        pendingManualCommandInvocation = hotkeyManager.currentPressedModifiers
            .contains(commandModeManualModifier.shortcutModifier)
        guard shortcutStartDelay > 0 else {
            startRecording(triggerMode: mode)
            return
        }
        let delay = shortcutStartDelay
        pendingShortcutStartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard let pendingMode = self.pendingShortcutStartMode else { return }
            await MainActor.run {
                self.startRecording(triggerMode: pendingMode)
            }
        }
    }

    private func cancelPendingShortcutStart() {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        pendingShortcutStartMode = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = nil
    }

    func toggleRecording() {
        cancelPendingShortcutStart()
        if isRecording {
            stopAndTranscribe()
            return
        }
        shortcutSessionController.beginManual(mode: .toggle)
        startRecording(triggerMode: .toggle)
    }

    @MainActor
    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    func copyLastTranscriptToPasteboard() {
        guard !lastTranscript.isEmpty else { return }
        let pendingRestore = writeTranscriptToPasteboard(lastTranscript)
        pasteAtCursorWhenShortcutReleased { [weak self] in
            self?.restoreClipboardIfNeeded(pendingRestore)
        }
    }

    private func handleEscapeKeyPress() -> Bool {
        if isTranscribing {
            cancelTranscription()
            return true
        }
        if activeRecordingTriggerMode == .toggle || pendingShortcutStartMode == .toggle {
            cancelToggleShortcutSession()
            return true
        }
        return false
    }

    // MARK: Recording start

    private func startRecording(triggerMode: RecordingTriggerMode) {
        guard !isRecording && !isTranscribing else { return }
        let startRequestedAt = CFAbsoluteTimeGetCurrent()
        let selectionSnapshot = pendingSelectionSnapshot ?? contextService.collectSelectionSnapshot()
        let manualCommandRequested = pendingManualCommandInvocation
            ?? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
        cancelPendingShortcutStart()

        guard prepareRecordingStart(triggerMode: triggerMode,
                                    selectionSnapshot: selectionSnapshot,
                                    manualCommandRequested: manualCommandRequested) else { return }
        guard ensureMicrophoneAccess(triggerMode: triggerMode,
                                     selectionSnapshot: selectionSnapshot,
                                     manualCommandRequested: manualCommandRequested) else { return }
        applyAudioInterruptionIfNeeded()
        beginRecording(triggerMode: triggerMode, startRequestedAt: startRequestedAt)
    }

    private func prepareRecordingStart(triggerMode: RecordingTriggerMode,
                                       selectionSnapshot: AppSelectionSnapshot,
                                       manualCommandRequested: Bool) -> Bool {
        activeRecordingTriggerMode = triggerMode
        capturedSelectionSnapshot = selectionSnapshot
        hasAccessibility = AXIsProcessTrusted()
        if !hasAccessibility {
            errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
            statusText = "No Accessibility"
            resetSessionStateAfterRejection(triggerMode: triggerMode)
            shortcutSessionController.reset()
            showAccessibilityAlert()
            return false
        }
        guard let resolvedIntent = resolveSessionIntent(triggerMode: triggerMode,
                                                        selectionSnapshot: selectionSnapshot,
                                                        manualCommandRequested: manualCommandRequested) else {
            return false
        }
        if resolvedIntent.isCommandMode {
            guard CGPreflightScreenCaptureAccess() else {
                // The alert must not be a once-per-launch latch: reset it so a
                // repeated attempt explains itself again.
                hasShownScreenshotPermissionAlert = false
                errorMessage = "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording."
                statusText = "Screenshot Required"
                resetSessionStateAfterRejection(triggerMode: triggerMode)
                shortcutSessionController.reset()
                playAlertSound(named: "Basso")
                showScreenshotPermissionAlert(message: "OmniFlow needs screen recording access to read the selected text for Edit Mode.")
                return false
            }
            // The guard above already passed the cheap preflight, so this
            // SCShareableContent round-trip no longer runs on every Edit Mode
            // start; it only fires if preflight ever fails on this path.
            if !CGPreflightScreenCaptureAccess() {
                requestScreenCapturePermission()
            }
        } else {
            hasScreenRecordingPermission = hasScreenCapturePermission()
        }
        currentSessionIntent = resolvedIntent
        overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
        return true
    }

    private func resetSessionStateAfterRejection(triggerMode: RecordingTriggerMode) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        capturedSelectionSnapshot = nil
        cancelPendingShortcutStart()
    }

    private func resolveSessionIntent(triggerMode: RecordingTriggerMode,
                                      selectionSnapshot: AppSelectionSnapshot,
                                      manualCommandRequested: Bool) -> SessionIntent? {
        guard isCommandModeEnabled else { return .dictation }
        switch commandModeStyle {
        case .automatic:
            if let rawSelection = selectionSnapshot.selectedText,
               !rawSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .command(invocation: .automatic, selectedText: rawSelection)
            }
            return .dictation
        case .manual:
            let activeBinding = triggerMode == .toggle ? toggleShortcut : holdShortcut
            if activeBinding.kind == .modifierKey,
               let bindingModifier = ShortcutBinding.modifier(forKeyCode: activeBinding.keyCode),
               bindingModifier == commandModeManualModifier.shortcutModifier {
                return .dictation
            }
            if let message = commandModeManualModifierCollisionMessage(for: commandModeManualModifier) {
                rejectInvalidCommandModeModifier(triggerMode: triggerMode, message: message)
                return nil
            }
            guard manualCommandRequested else { return .dictation }
            guard let rawSelection = selectionSnapshot.selectedText,
                  !rawSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                rejectCommandModeSelectionRequirement(triggerMode: triggerMode)
                return nil
            }
            return .command(invocation: .manual, selectedText: rawSelection)
        }
    }

    private func rejectInvalidCommandModeModifier(triggerMode: RecordingTriggerMode, message: String) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        cancelPendingShortcutStart()
        errorMessage = message
        statusText = "Fix Edit Mode modifier"
        debugStatusMessage = "Edit mode modifier conflicts with dictation shortcuts"
        shortcutSessionController.reset()
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Fix Edit Mode modifier"])
    }

    private func rejectCommandModeSelectionRequirement(triggerMode: RecordingTriggerMode) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        cancelPendingShortcutStart()
        errorMessage = "Select text to transform first"
        statusText = "Select text to transform first"
        debugStatusMessage = "Edit mode requires selected text"
        shortcutSessionController.reset()
        playAlertSound(named: "Basso")
        // The user is typing in another app, not looking at the menu bar —
        // show the overlay toast too (no recording session required).
        overlayManager.showError("Select text to transform first")
        scheduleReadyStatusReset(after: 2, matching: ["Select text to transform first"])
    }

    private func ensureMicrophoneAccess(triggerMode: RecordingTriggerMode,
                                        selectionSnapshot: AppSelectionSnapshot,
                                        manualCommandRequested: Bool) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            prepareForMicrophonePermissionPrompt(triggerMode: triggerMode,
                                                 selectionSnapshot: selectionSnapshot,
                                                 manualCommandRequested: manualCommandRequested)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.finishMicrophonePermissionPrompt(granted: granted,
                                                           triggerMode: triggerMode,
                                                           selectionSnapshot: selectionSnapshot,
                                                           manualCommandRequested: manualCommandRequested)
                }
            }
            return false
        default:
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func prepareForMicrophonePermissionPrompt(triggerMode: RecordingTriggerMode,
                                                      selectionSnapshot: AppSelectionSnapshot,
                                                      manualCommandRequested: Bool) {
        isAwaitingMicrophonePermission = true
        pendingMicrophonePermissionTriggerMode = triggerMode
        pendingMicrophonePermissionSelectionSnapshot = selectionSnapshot
        pendingMicrophonePermissionManualCommandRequested = manualCommandRequested
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        overlayManager.dismiss()
    }

    private func finishMicrophonePermissionPrompt(granted: Bool,
                                                  triggerMode: RecordingTriggerMode,
                                                  selectionSnapshot: AppSelectionSnapshot,
                                                  manualCommandRequested: Bool) {
        isAwaitingMicrophonePermission = false
        pendingMicrophonePermissionTriggerMode = nil
        pendingMicrophonePermissionSelectionSnapshot = nil
        pendingMicrophonePermissionManualCommandRequested = nil
        restartHotkeyMonitoring()
        guard granted else {
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            showMicrophonePermissionAlert()
            return
        }
        if triggerMode == .toggle {
            guard prepareRecordingStart(triggerMode: .toggle,
                                        selectionSnapshot: selectionSnapshot,
                                        manualCommandRequested: manualCommandRequested) else { return }
            shortcutSessionController.beginManual(mode: .toggle)
            applyAudioInterruptionIfNeeded()
            beginRecording(triggerMode: .toggle, startRequestedAt: CFAbsoluteTimeGetCurrent())
        } else {
            statusText = "Microphone access granted. Press and hold again to record."
            scheduleReadyStatusReset(after: 2,
                                     matching: ["Microphone access granted. Press and hold again to record."])
        }
    }

    private func applyAudioInterruptionIfNeeded() {
        guard dictationAudioInterruptionEnabled, activeAudioInterruption == nil else { return }
        if SystemAudioStatus.isDefaultOutputMuted() {
            activeAudioInterruption = .muted(previouslyMuted: true)
        } else if SystemAudioStatus.setDefaultOutputMuted(true) {
            activeAudioInterruption = .muted(previouslyMuted: false)
        }
    }

    private func restoreAudioInterruptionIfNeeded() {
        guard let interruption = activeAudioInterruption else { return }
        activeAudioInterruption = nil
        if case .muted(previouslyMuted: false) = interruption {
            _ = SystemAudioStatus.setDefaultOutputMuted(false)
        }
    }

    private func beginRecording(triggerMode: RecordingTriggerMode, startRequestedAt: CFAbsoluteTime) {
        // Elapsed time since startRecording was requested (not the absolute
        // epoch), mirroring the reference's delta logging.
        os_log("Starting recording after %.0f ms", log: Self.appLog, type: .debug,
               (CFAbsoluteTimeGetCurrent() - startRequestedAt) * 1000)
        beginCriticalDictationActivity()
        clearPendingOverlayDismissToken()
        errorMessage = nil
        isRecording = true
        statusText = "Starting..."
        hasShownScreenshotPermissionAlert = false

        cancelRecordingInitializationTimer()
        initializingOverlayVisible = false
        let initializationTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        initializationTimer.schedule(deadline: .now() + 0.2)
        initializationTimer.setEventHandler { [weak self] in
            guard let self, self.isRecording, !self.initializingOverlayVisible else { return }
            self.initializingOverlayVisible = true
            self.overlayManager.showInitializing(mode: triggerMode,
                                                 isCommandMode: self.currentSessionIntent.isCommandMode)
        }
        initializationTimer.resume()
        recordingInitializationTimer = initializationTimer

        audioRecorder.onRecordingReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.cancelRecordingInitializationTimer()
                self.statusText = "Recording..."
                self.clearPendingOverlayDismissToken()
                let commandMode = self.currentSessionIntent.isCommandMode
                if self.initializingOverlayVisible {
                    self.initializingOverlayVisible = false
                    self.overlayManager.transitionToRecording(mode: triggerMode, isCommandMode: commandMode)
                } else {
                    self.overlayManager.showRecording(mode: triggerMode, isCommandMode: commandMode)
                }
                self.playAlertSound(named: "Tink")
            }
        }
        audioRecorder.onRecordingFailure = { [weak self] error in
            DispatchQueue.main.async {
                self?.handleRecordingFailure(error)
            }
        }

        startRealtimeStreamingIfEnabled()

        let deviceUID = selectedMicrophoneID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.audioRecorder.startRecording(deviceUID: deviceUID)
            } catch {
                DispatchQueue.main.async {
                    self?.handleRecordingFailure(error)
                    return
                }
            }
            DispatchQueue.main.async {
                guard let self, self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                self.startContextCapture()
                self.audioLevelCancellable = self.audioRecorder.$audioLevel
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] level in
                        self?.overlayManager.updateAudioLevel(level)
                    }
            }
        }
    }

    private func cancelRecordingInitializationTimer() {
        recordingInitializationTimer?.cancel()
        recordingInitializationTimer = nil
    }

    private func handleRecordingFailure(_ error: Error) {
        cancelRecordingInitializationTimer()
        initializingOverlayVisible = false
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        tearDownRealtimeService()
        audioRecorder.cleanup()
        restoreAudioInterruptionIfNeeded()
        isRecording = false
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        deleteTranscribingAudioFile()
        activeRecordingTriggerMode = nil
        capturedSelectionSnapshot = nil
        currentSessionIntent = .dictation
        shortcutSessionController.reset()
        endCriticalDictationActivity()
        errorMessage = formattedRecordingStartError(error)
        statusText = "Error"
        overlayManager.dismiss()
        refreshAvailableMicrophonesIfNeeded()
        flushDeferredHotkeyRestartIfNeeded()
    }

    // MARK: Context capture

    private func startContextCapture() {
        contextCaptureTask?.cancel()
        capturedContext = nil
        lastContextScreenshotStatus = "Collecting screenshot..."
        let service = contextService
        contextCaptureTask = Task { () -> AppContext in
            let context = await service.collectContext()
            await MainActor.run { [weak self] in
                self?.capturedContext = context
            }
            return context
        }
    }

    private func fallbackContextAtStop() -> AppContext {
        let snapshot = contextService.collectSelectionSnapshot()
        return AppContext(appName: snapshot.appName,
                          bundleIdentifier: snapshot.bundleIdentifier,
                          windowTitle: snapshot.windowTitle,
                          selectedText: nil,
                          currentActivity: "Could not refresh app context at stop time; using text-only post-processing.",
                          contextSystemPrompt: nil,
                          contextPrompt: nil,
                          screenshotDataURL: nil,
                          screenshotMimeType: nil,
                          screenshotError: "No app context captured before stop")
    }

    // MARK: Stop and transcribe

    private func stopAndTranscribe() {
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        initializingOverlayVisible = false
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil

        let sessionIntent = currentSessionIntent
        currentSessionIntent = .dictation
        let sessionCapturedSelection = capturedSelectionSnapshot?.selectedText
        capturedSelectionSnapshot = nil

        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        debugStatusMessage = "Preparing audio"
        let sessionContext = capturedContext
        let inFlightContextTask = contextCaptureTask
        capturedContext = nil
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"
        lastContextAppName = ""
        lastContextBundleIdentifier = ""
        lastContextWindowTitle = ""
        lastContextSelectedText = ""
        lastContextLLMPrompt = ""

        isRecording = false
        restoreAudioInterruptionIfNeeded()
        isTranscribing = true
        statusText = "Preparing audio..."
        errorMessage = nil
        playAlertSound(named: "Pop")
        overlayManager.showTranscribing()
        flushDeferredHotkeyRestartIfNeeded()

        audioRecorder.stopRecording { [weak self] fileURL in
            DispatchQueue.main.async {
                self?.handleStoppedRecording(fileURL: fileURL,
                                             sessionIntent: sessionIntent,
                                             sessionContext: sessionContext,
                                             inFlightContextTask: inFlightContextTask,
                                             capturedSelection: sessionCapturedSelection)
            }
        }
    }

    private func handleStoppedRecording(fileURL: URL?,
                                        sessionIntent: SessionIntent,
                                        sessionContext: AppContext?,
                                        inFlightContextTask: Task<AppContext, Never>?,
                                        capturedSelection: String?) {
        guard let fileURL else {
            isTranscribing = false
            audioRecorder.cleanup()
            endCriticalDictationActivity()
            errorMessage = "No audio recorded"
            statusText = "Error"
            overlayManager.dismiss()
            refreshAvailableMicrophonesIfNeeded()
            return
        }
        guard isTranscribing else {
            tearDownRealtimeService()
            audioRecorder.cleanup()
            refreshAvailableMicrophonesIfNeeded()
            return
        }

        let savedAudioFile = Self.saveAudioFile(from: fileURL)
        transcribingAudioFileName = savedAudioFile?.fileName
        let transcriptionFileURL = savedAudioFile?.fileURL ?? fileURL
        statusText = "Transcribing..."
        debugStatusMessage = "Transcribing audio"

        let postProcessingService = PostProcessingService(
            apiKey: resolvedPostProcessingAPIKey,
            baseURL: resolvedPostProcessingBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled)

        let activeRealtime = realtimeService
        realtimeService = nil
        audioRecorder.onPCM16Samples = nil
        transcriptionTask?.cancel()

        guard isTranscribing else {
            if let savedAudioFile {
                try? FileManager.default.removeItem(at: savedAudioFile.fileURL)
            }
            activeRealtime?.cancel()
            audioRecorder.cleanup()
            refreshAvailableMicrophonesIfNeeded()
            return
        }

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { activeRealtime?.cancel() }
            do {
                let fileService = try self.makeTranscriptionService()
                let rawTranscript = try await Self.resolveRawTranscript(realtimeService: activeRealtime,
                                                                        fileService: fileService,
                                                                        fileURL: transcriptionFileURL)
                let parsedTranscript = TranscriptCommandParser.parse(
                    from: rawTranscript,
                    pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled)
                try Task.checkCancellation()
                let bootstrapTranscript = parsedTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !bootstrapTranscript.isEmpty {
                    await MainActor.run { self.lastTranscript = bootstrapTranscript }
                }

                var appContext = sessionContext
                if appContext == nil {
                    appContext = await inFlightContextTask?.value
                }
                if appContext == nil {
                    appContext = self.fallbackContextAtStop()
                }
                guard let resolvedContext = appContext else { return }
                try Task.checkCancellation()
                await MainActor.run {
                    self.debugStatusMessage = "Running post-processing"
                }
                let result = await self.processTranscript(parsedTranscript.transcript,
                                                          intent: sessionIntent,
                                                          context: resolvedContext,
                                                          postProcessingService: postProcessingService,
                                                          customVocabulary: self.customVocabulary,
                                                          customSystemPrompt: self.customSystemPrompt,
                                                          outputLanguage: self.outputLanguage,
                                                          preserveExactWording: self.preserveExactWording)
                try Task.checkCancellation()
                await self.completeTranscription(result: result,
                                                 parsedTranscript: parsedTranscript,
                                                 sessionIntent: sessionIntent,
                                                 appContext: resolvedContext,
                                                 capturedSelection: capturedSelection,
                                                 savedAudioFile: savedAudioFile)
            } catch {
                await self.finishTranscriptionWithError(error,
                                                        sessionIntent: sessionIntent,
                                                        sessionContext: sessionContext,
                                                        inFlightContextTask: inFlightContextTask,
                                                        postProcessingService: postProcessingService,
                                                        savedAudioFile: savedAudioFile,
                                                        capturedSelection: capturedSelection)
            }
        }
    }

    @MainActor
    private func completeTranscription(result: (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String),
                                       parsedTranscript: TranscriptCommandParsing,
                                       sessionIntent: SessionIntent,
                                       appContext: AppContext,
                                       capturedSelection: String?,
                                       savedAudioFile: SavedAudioFile?) {
        guard isTranscribing else { return }

        let trimmedFinal = result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let processingStatus = Self.statusMessage(for: result.outcome, parsedTranscript: parsedTranscript)

        // The reference keeps the parsed transcript (press-enter tail already
        // stripped) as the "raw" display value in Run Log and history; retry
        // re-parses from the stored string either way.
        let storedRawTranscript = parsedTranscript.transcript
        lastRawTranscript = storedRawTranscript
        lastPostProcessedTranscript = trimmedFinal
        lastPostProcessingPrompt = result.prompt
        lastPostProcessingStatus = processingStatus
        applyContextDebugFields(appContext)
        lastTranscript = trimmedFinal

        recordPipelineHistoryEntry(sessionIntent: sessionIntent,
                                   capturedSelection: capturedSelection,
                                   rawTranscript: storedRawTranscript,
                                   finalTranscript: trimmedFinal,
                                   prompt: result.prompt,
                                   processingStatus: processingStatus,
                                   context: appContext,
                                   savedAudioFile: savedAudioFile)

        transcriptionTask = nil
        transcribingAudioFileName = nil
        isTranscribing = false
        endCriticalDictationActivity()
        debugStatusMessage = "Done"

        let shouldPressEnter = parsedTranscript.shouldPressEnterAfterPaste
        let completionStatusText: String
        if trimmedFinal.isEmpty {
            completionStatusText = shouldPressEnter ? "Pressed Enter" : "Nothing to transcribe"
            statusText = completionStatusText
            showPostTranscriptionUpdateReminderIfNeeded()
            if shouldPressEnter {
                pressEnterWhenShortcutReleased()
            }
        } else {
            completionStatusText = preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!"
            statusText = completionStatusText
            switch result.outcome {
            case .postProcessingFailedFallback, .preservedExactWordingTranslationFailedFallback,
                 .postProcessingSkippedCooldown:
                scheduleOverlayDismissAfterFailureIndicator(after: 2.5)
            default:
                showPostTranscriptionUpdateReminderIfNeeded()
            }
            let pendingRestore = writeTranscriptToPasteboard(trimmedFinal)
            pasteAtCursorWhenShortcutReleased { [weak self] in
                if shouldPressEnter {
                    self?.pressEnterAfterPaste {
                        self?.restoreClipboardIfNeeded(pendingRestore)
                    }
                } else {
                    self?.restoreClipboardIfNeeded(pendingRestore)
                }
            }
        }

        audioRecorder.cleanup()
        refreshAvailableMicrophonesIfNeeded()
        scheduleReadyStatusReset(after: 3, matching: [completionStatusText, "Nothing to transcribe", "Pressed Enter"])
    }

    @MainActor
    private func finishTranscriptionWithError(_ error: Error,
                                              sessionIntent: SessionIntent,
                                              sessionContext: AppContext?,
                                              inFlightContextTask: Task<AppContext, Never>?,
                                              postProcessingService: PostProcessingService,
                                              savedAudioFile: SavedAudioFile?,
                                              capturedSelection: String?) async {
        if error is CancellationError {
            transcriptionTask = nil
            endCriticalDictationActivity()
            return
        }
        guard isTranscribing else { return }
        var appContext = sessionContext
        if appContext == nil {
            appContext = await inFlightContextTask?.value
        }
        if appContext == nil {
            appContext = fallbackContextAtStop()
        }
        guard let resolvedContext = appContext else { return }
        let message = Self.formattedTranscriptionError(error)
        errorMessage = message
        statusText = "Error"
        overlayManager.showError(userFacingErrorMessage(for: error))
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastPostProcessingPrompt = ""
        lastContextSummary = resolvedContext.currentActivity
        lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
        applyContextDebugFields(resolvedContext)
        lastPostProcessingStatus = "Error: \(error.localizedDescription)"
        recordPipelineHistoryEntry(sessionIntent: sessionIntent,
                                   capturedSelection: capturedSelection,
                                   rawTranscript: "",
                                   finalTranscript: "",
                                   prompt: nil,
                                   processingStatus: "Error: \(error.localizedDescription)",
                                   context: resolvedContext,
                                   savedAudioFile: savedAudioFile)
        transcriptionTask = nil
        transcribingAudioFileName = nil
        isTranscribing = false
        endCriticalDictationActivity()
        audioRecorder.cleanup()
        refreshAvailableMicrophonesIfNeeded()
    }

    private func applyContextDebugFields(_ context: AppContext) {
        lastContextAppName = context.appName ?? ""
        lastContextBundleIdentifier = context.bundleIdentifier ?? ""
        lastContextWindowTitle = context.windowTitle ?? ""
        lastContextSelectedText = context.selectedText ?? ""
        lastContextLLMPrompt = context.contextPrompt ?? ""
        lastContextSummary = context.currentActivity
        lastContextScreenshotDataURL = context.screenshotDataURL
        if let screenshotError = context.screenshotError {
            lastContextScreenshotStatus = screenshotError
        } else if let mimeType = context.screenshotMimeType {
            lastContextScreenshotStatus = "available (\(mimeType))"
        } else {
            lastContextScreenshotStatus = "No screenshot"
        }
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        Self.formattedTranscriptionError(error)
    }

    // MARK: Cancellations

    private func cancelToggleShortcutSession() {
        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        capturedSelectionSnapshot = nil
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        cancelRecordingInitializationTimer()
        initializingOverlayVisible = false
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        currentSessionIntent = .dictation
        isRecording = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        tearDownRealtimeService()
        audioRecorder.cancelRecording()
        restoreAudioInterruptionIfNeeded()
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        flushDeferredHotkeyRestartIfNeeded()
        scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
    }

    func cancelTranscription() {
        guard isTranscribing else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        capturedSelectionSnapshot = nil
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        currentSessionIntent = .dictation
        isRecording = false
        isTranscribing = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        audioRecorder.cleanup()
        deleteTranscribingAudioFile()
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        flushDeferredHotkeyRestartIfNeeded()
        scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
    }

    private func deleteTranscribingAudioFile() {
        guard let fileName = transcribingAudioFileName else { return }
        transcribingAudioFileName = nil
        try? FileManager.default.removeItem(at: Self.audioStorageDirectory().appendingPathComponent(fileName))
    }

    // MARK: Transcript processing pipeline

    private func processTranscript(_ rawTranscript: String,
                                   intent: SessionIntent,
                                   context: AppContext,
                                   postProcessingService: PostProcessingService,
                                   customVocabulary: String,
                                   customSystemPrompt: String,
                                   outputLanguage: String = "",
                                   preserveExactWording: Bool)
        async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawTranscript.isEmpty else {
            return ("", .skippedEmptyRawTranscript, "")
        }
        if case .command(let invocation, let selectedText) = intent {
            do {
                let commandResult = try await postProcessingService.commandTransform(
                    selectedText: selectedText,
                    voiceCommand: trimmedRawTranscript,
                    context: context,
                    customVocabulary: customVocabulary,
                    outputLanguage: outputLanguage)
                return (commandResult.transcript, .commandModeSucceeded(invocation: invocation), commandResult.prompt)
            } catch {
                return (selectedText, .commandModeFailedFallback(invocation: invocation), "")
            }
        }
        if let macro = findMatchingMacro(for: trimmedRawTranscript) {
            return (macro.original.payload, .voiceMacro(command: macro.original.command), "")
        }
        if preserveExactWording {
            if outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (trimmedRawTranscript, .preservedExactWording, "")
            }
            do {
                let translation = try await postProcessingService.translateVerbatim(
                    transcript: trimmedRawTranscript,
                    targetLanguage: outputLanguage)
                return (translation.transcript, .preservedExactWordingTranslated, translation.prompt)
            } catch {
                return (trimmedRawTranscript, .preservedExactWordingTranslationFailedFallback, "")
            }
        }
        do {
            let cleaned = try await postProcessingService.postProcess(
                transcript: trimmedRawTranscript,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage)
            if cleaned.skippedCooldown {
                // Circuit breaker: both models cooling down. The raw transcript
                // is pasted, but this must not be reported as a success.
                return (cleaned.transcript, .postProcessingSkippedCooldown, cleaned.prompt)
            }
            return (cleaned.transcript, .postProcessingSucceeded, cleaned.prompt)
        } catch {
            return (trimmedRawTranscript, .postProcessingFailedFallback, "")
        }
    }

    private static func resolveRawTranscript(realtimeService: (any RealtimeTranscriptBackend)?,
                                             fileService: TranscriptionService,
                                             fileURL: URL) async throws -> String {
        if let realtimeService {
            try Task.checkCancellation()
            do {
                return try await withTaskCancellationHandler {
                    try await realtimeService.commitAndAwaitFinal()
                } onCancel: {
                    realtimeService.cancel()
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                return try await fileService.transcribe(fileURL: fileURL)
            }
        }
        return try await fileService.transcribe(fileURL: fileURL)
    }

    private static func statusMessage(for outcome: TranscriptProcessingOutcome,
                                      parsedTranscript: TranscriptCommandParsing,
                                      isRetry: Bool = false) -> String {
        var message = outcome.statusMessage(isRetry: isRetry)
        if parsedTranscript.shouldPressEnterAfterPaste {
            message += "; detected press enter command"
        }
        return message
    }

    private static func resolvedSystemPrompt(_ customSystemPrompt: String) -> String {
        let trimmed = customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PostProcessingService.defaultSystemPrompt : trimmed
    }

    // MARK: Realtime streaming

    private func startRealtimeStreamingIfEnabled() {
        guard realtimeStreamingEnabled else { return }
        let model = realtimeStreamingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if GeminiLiveTranscription.handlesModel(model) {
            let configuration = GeminiLiveTranscriptionService.Configuration(
                baseURL: resolvedTranscriptionBaseURL,
                apiKey: resolvedTranscriptionAPIKey,
                model: model,
                customVocabulary: customVocabulary,
                sampleRate: AudioRecorder.realtimeSampleRate)
            start(realtimeService: GeminiLiveTranscriptionService(config: configuration))
        } else if GeminiTranscription.handlesModel(transcriptionModel) {
            // OpenAI realtime sockets cannot authenticate with a Gemini key: skip streaming.
            return
        } else {
            let trimmedBase = resolvedTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBase.isEmpty else { return }
            let configuration = RealtimeTranscriptionService.Configuration(
                baseURL: trimmedBase,
                apiKey: resolvedTranscriptionAPIKey,
                model: model,
                language: resolvedTranscriptionLanguage)
            start(realtimeService: RealtimeTranscriptionService(config: configuration))
        }
    }

    private func start(realtimeService service: any RealtimeTranscriptBackend) {
        do {
            try service.start()
        } catch {
            return
        }
        realtimeService = service
        audioRecorder.onPCM16Samples = { [weak service] data in
            service?.appendPCM16(data)
        }
    }

    private func tearDownRealtimeService() {
        audioRecorder.onPCM16Samples = nil
        realtimeService?.cancel()
        realtimeService = nil
    }

    // MARK: Service factories

    static func makeAppContextService(apiKey: String,
                                      baseURL: String,
                                      customContextPrompt: String,
                                      contextModel: String,
                                      contextScreenshotMaxDimension: Int) -> AppContextService {
        AppContextService(apiKey: apiKey,
                          baseURL: baseURL,
                          customContextPrompt: customContextPrompt,
                          contextModel: contextModel,
                          screenshotMaxDimension: CGFloat(contextScreenshotMaxDimension))
    }

    func makeAppContextService() -> AppContextService {
        Self.makeAppContextService(apiKey: apiKey,
                                   baseURL: apiBaseURL.isEmpty ? Self.defaultAPIBaseURL : apiBaseURL,
                                   customContextPrompt: customContextPrompt,
                                   contextModel: contextModel,
                                   contextScreenshotMaxDimension: contextScreenshotMaxDimension)
    }

    private func rebuildContextService() {
        contextService = makeAppContextService()
    }

    func makeTranscriptionService() throws -> TranscriptionService {
        try TranscriptionService(apiKey: resolvedTranscriptionAPIKey,
                                 baseURL: resolvedTranscriptionBaseURL,
                                 transcriptionModel: transcriptionModel,
                                 language: resolvedTranscriptionLanguage,
                                 customVocabulary: customVocabulary)
    }

    private var resolvedTranscriptionAPIKey: String {
        let trimmed = transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiKey : trimmed
    }

    private var resolvedTranscriptionBaseURL: String {
        if !transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transcriptionAPIURL
        }
        let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? Self.defaultAPIBaseURL : base
    }

    private var resolvedTranscriptionLanguage: String? {
        transcriptionLanguage.isEmpty ? nil : transcriptionLanguage
    }

    private var resolvedPostProcessingAPIKey: String {
        apiKey
    }

    private var resolvedPostProcessingBaseURL: String {
        apiBaseURL.isEmpty ? Self.defaultAPIBaseURL : apiBaseURL
    }

    // MARK: Transcription error mapping

    /// Static so non-pipeline surfaces (Setup test step, Run Log retry) reuse
    /// the exact same user-facing wording as the main dictation pipeline.
    static func formattedTranscriptionError(_ error: Error) -> String {
        if let code = Self.urlErrorCode(in: error) {
            switch code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed:
                return "No internet — check connection"
            case .timedOut:
                return NetworkMonitor.shared.isOnline
                    ? "Request timed out — try again"
                    : "No internet — check connection"
            default:
                break
            }
        }
        let description = error.localizedDescription.lowercased()
        if description.contains("timed out") || description.contains("timeout") {
            return NetworkMonitor.shared.isOnline
                ? "Request timed out — try again"
                : "No internet — check connection"
        }
        if description.contains("offline") || description.contains("internet connection")
            || description.contains("not connected") || description.contains("network")
            || description.contains("cannot find host") {
            return "No internet — check connection"
        }
        return error.localizedDescription
    }

    private static func urlErrorCode(in error: Error) -> URLError.Code? {
        var current = error
        for _ in 0..<8 {
            if let urlError = current as? URLError {
                return urlError.code
            }
            let nsError = current as NSError
            if nsError.domain == NSURLErrorDomain {
                return URLError.Code(rawValue: nsError.code)
            }
            guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else { return nil }
            current = underlying
        }
        return nil
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if error is AudioRecorderError {
            return "Failed to start recording: \(error.localizedDescription)"
        }
        let description = error.localizedDescription.lowercased()
        if description.contains("operation couldn't be completed")
            || description.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }
        return "Failed to start recording: \(error.localizedDescription)"
    }

    // MARK: Overlay helpers

    private func clearPendingOverlayDismissToken() {
        pendingOverlayDismissToken = nil
    }

    private func scheduleOverlayDismissAfterFailureIndicator(after delay: TimeInterval) {
        let token = UUID()
        pendingOverlayDismissToken = token
        overlayManager.showFailureIndicator()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let pendingToken = self.pendingOverlayDismissToken, pendingToken == token else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    @MainActor
    private func showPostTranscriptionUpdateReminderIfNeeded() {
        let updateManager = UpdateManager.shared
        if !debugShowsUpdateReminderAfterDictation {
            guard updateManager.shouldShowPostTranscriptionReminder() else {
                overlayManager.dismiss()
                return
            }
            updateManager.markPostTranscriptionReminderShown()
        }
        let version = updateManager.latestReleaseVersion.isEmpty ? "9.9.9" : updateManager.latestReleaseVersion
        overlayManager.showUpdateAvailable(version: version)
        let token = UUID()
        pendingOverlayDismissToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + postTranscriptionUpdateReminderDuration) { [weak self] in
            guard let self, let pendingToken = self.pendingOverlayDismissToken, pendingToken == token else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    @MainActor
    func handleUpdateOverlayPressed() {
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
        selectedSettingsTab = .general
        NotificationCenter.default.post(name: .showSettings, object: nil)
        UpdateManager.shared.showUpdateAlert()
    }

    // MARK: Pasteboard

    private func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PreservedPasteboardSnapshot(pasteboard: pasteboard) : nil
        var textToWrite = transcript
        if let lastCharacter = transcript.last, ".!?".contains(lastCharacter) {
            textToWrite = transcript + " "
        }
        if keepDictationInClipboardHistory {
            pasteboard.clearContents()
            pasteboard.setString(textToWrite, forType: .string)
        } else {
            pasteboard.clearContents()
            pasteboard.declareTypes([.string,
                                     Self.transientPasteboardType,
                                     Self.concealedPasteboardType,
                                     Self.autoGeneratedPasteboardType,
                                     Self.legacyTransientPasteboardType],
                                    owner: nil)
            pasteboard.setString(textToWrite, forType: .string)
            for markerType in [Self.transientPasteboardType,
                               Self.concealedPasteboardType,
                               Self.autoGeneratedPasteboardType,
                               Self.legacyTransientPasteboardType] {
                pasteboard.setString("", forType: markerType)
            }
        }
        if preserveClipboard, let snapshot {
            return PendingClipboardRestore(snapshot: snapshot,
                                           expectedChangeCount: pasteboard.changeCount,
                                           writtenTranscript: textToWrite)
        }
        return nil
    }

    private func restoreClipboardIfNeeded(_ pendingRestore: PendingClipboardRestore?) {
        guard let pendingRestore else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            let pasteboard = NSPasteboard.general
            let stillOurs = pasteboard.changeCount == pendingRestore.expectedChangeCount
                || pasteboard.string(forType: .string) == pendingRestore.writtenTranscript
            guard stillOurs else { return }
            pendingRestore.snapshot.restore(to: pasteboard)
        }
    }

    // MARK: Paste at cursor

    private func performAfterShortcutReleased(attempt: Int = 0, action: @escaping () -> Void) {
        if attempt < 24 && hotkeyManager.hasPressedShortcutInputs {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.performAfterShortcutReleased(attempt: attempt + 1, action: action)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteAfterShortcutReleaseDelay, execute: action)
    }

    private func pasteAtCursorWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pasteAtCursor()
            completion?()
        }
    }

    private func pressEnterWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pressEnter()
            completion?()
        }
    }

    private func pressEnterAfterPaste(completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pressEnterAfterPasteDelay) { [weak self] in
            self?.pressEnter()
            completion()
        }
    }

    private func pasteAtCursor() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let vKeyCode = Self.keyCodeForCharacter("v") ?? 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func pressEnter() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.post(tap: .cgSessionEventTap)
    }

    private static func keyCodeForCharacter(_ character: Character) -> UInt16? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let propertyPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(propertyPointer, to: CFData.self)
        guard let bytePointer = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = bytePointer.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
        let target = String(character).lowercased()
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        for keyCode: UInt16 in 0..<128 {
            deadKeyState = 0
            length = 0
            let status = UCKeyTranslate(keyboardLayout,
                                        keyCode,
                                        UInt16(kUCKeyActionDisplay),
                                        0,
                                        UInt32(LMGetKbdType()),
                                        UInt32(1 << kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        characters.count,
                                        &length,
                                        &characters)
            guard status == noErr, length > 0 else { continue }
            if let scalar = Unicode.Scalar(characters[0]), String(Character(scalar)) == target {
                return keyCode
            }
        }
        return nil
    }

    // MARK: Critical activity

    private func beginCriticalDictationActivity() {
        guard !automaticTerminationDisabled else { return }
        automaticTerminationDisabled = true
        ProcessInfo.processInfo.disableAutomaticTermination("OmniFlow dictation in progress")
    }

    private func endCriticalDictationActivity() {
        guard automaticTerminationDisabled else { return }
        automaticTerminationDisabled = false
        ProcessInfo.processInfo.enableAutomaticTermination("OmniFlow dictation in progress")
    }

    // MARK: Status resets

    private func scheduleReadyStatusReset(after delay: TimeInterval, matching statuses: Set<String>) {
        readyStatusResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, statuses.contains(self.statusText) else { return }
            self.statusText = "Ready"
        }
        readyStatusResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: History

    private func recordPipelineHistoryEntry(sessionIntent: SessionIntent,
                                            capturedSelection: String?,
                                            rawTranscript: String,
                                            finalTranscript: String,
                                            prompt: String?,
                                            processingStatus: String,
                                            context: AppContext,
                                            savedAudioFile: SavedAudioFile?) {
        var screenshotStatus = "No screenshot"
        if let screenshotError = context.screenshotError {
            screenshotStatus = screenshotError
        } else if let mimeType = context.screenshotMimeType {
            screenshotStatus = "available (\(mimeType))"
        }
        let item = PipelineHistoryItem(
            intent: sessionIntent.persistedIntent,
            selectedText: sessionIntent.persistedSelectedText,
            capturedSelection: capturedSelection,
            timestamp: Date(),
            rawTranscript: rawTranscript,
            postProcessedTranscript: finalTranscript,
            postProcessingPrompt: prompt,
            systemPrompt: Self.resolvedSystemPrompt(customSystemPrompt),
            contextSummary: context.currentActivity,
            contextSystemPrompt: context.contextSystemPrompt,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: screenshotStatus,
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage,
            customVocabulary: customVocabulary,
            audioFileName: savedAudioFile?.fileName,
            contextAppName: context.appName,
            contextBundleIdentifier: context.bundleIdentifier,
            contextWindowTitle: context.windowTitle)
        if let evicted = try? pipelineHistoryStore.append(item, maxCount: maxPipelineHistoryCount) {
            for fileName in evicted {
                Self.deleteAudioFile(named: fileName)
            }
        }
        pipelineHistory = pipelineHistoryStore.loadAllHistory()
    }

    func clearPipelineHistory() {
        if let evicted = try? pipelineHistoryStore.clearAll() {
            for fileName in evicted {
                Self.deleteAudioFile(named: fileName)
            }
        }
        pipelineHistory = []
    }

    func deleteHistoryEntry(id: UUID) {
        if let removedFileName = try? pipelineHistoryStore.delete(id: id) {
            Self.deleteAudioFile(named: removedFileName)
        }
        pipelineHistory = pipelineHistoryStore.loadAllHistory()
    }

    // MARK: Retry

    func retryTranscription(item: PipelineHistoryItem) {
        guard let audioFileName = item.audioFileName, !retryingItemIDs.contains(item.id) else { return }
        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }
        retryingItemIDs.insert(item.id)

        let intent = SessionIntent.fromPersisted(intent: item.intent, selectedText: item.selectedText)
        let context = AppContext(appName: item.contextAppName,
                                 bundleIdentifier: item.contextBundleIdentifier,
                                 windowTitle: item.contextWindowTitle,
                                 selectedText: item.selectedText,
                                 currentActivity: item.contextSummary,
                                 contextSystemPrompt: item.contextSystemPrompt,
                                 contextPrompt: item.contextPrompt,
                                 screenshotDataURL: item.contextScreenshotDataURL,
                                 screenshotMimeType: nil,
                                 screenshotError: nil)
        let postProcessingService = PostProcessingService(
            apiKey: resolvedPostProcessingAPIKey,
            baseURL: resolvedPostProcessingBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled)
        let fileService: TranscriptionService?
        do {
            fileService = try makeTranscriptionService()
        } catch {
            retryingItemIDs.remove(item.id)
            // Surface the failure in the menu bar instead of a silent spinner
            // flash; the history entry keeps its original error.
            errorMessage = "Retry failed: \(Self.formattedTranscriptionError(error))"
            return
        }
        guard let fileService else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let rawTranscript = try await fileService.transcribe(fileURL: audioURL)
                let parsedTranscript = TranscriptCommandParser.parse(
                    from: rawTranscript,
                    pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled)
                let result = await self.processTranscript(parsedTranscript.transcript,
                                                          intent: intent,
                                                          context: context,
                                                          postProcessingService: postProcessingService,
                                                          customVocabulary: self.customVocabulary,
                                                          customSystemPrompt: self.customSystemPrompt,
                                                          outputLanguage: self.outputLanguage,
                                                          preserveExactWording: self.preserveExactWording)
                await MainActor.run {
                    self.finishRetry(item: item,
                                     parsedTranscript: parsedTranscript,
                                     result: result)
                }
            } catch {
                await MainActor.run {
                    self.retryItemFailed(item: item, error: error)
                }
            }
        }
    }

    private func finishRetry(item: PipelineHistoryItem,
                             parsedTranscript: TranscriptCommandParsing,
                             result: (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String)) {
        retryingItemIDs.remove(item.id)
        let trimmedFinal = result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let processingStatus = Self.statusMessage(for: result.outcome,
                                                  parsedTranscript: parsedTranscript,
                                                  isRetry: true)
        // The reference stores the parsed transcript (press-enter tail
        // stripped), not the raw recognition output.
        let updated = PipelineHistoryItem(
            intent: item.intent,
            selectedText: item.selectedText,
            capturedSelection: item.capturedSelection,
            id: item.id,
            timestamp: item.timestamp,
            rawTranscript: parsedTranscript.transcript,
            postProcessedTranscript: trimmedFinal,
            postProcessingPrompt: result.prompt,
            systemPrompt: item.systemPrompt,
            contextSummary: item.contextSummary,
            contextSystemPrompt: item.contextSystemPrompt,
            contextPrompt: item.contextPrompt,
            contextScreenshotDataURL: item.contextScreenshotDataURL,
            contextScreenshotStatus: item.contextScreenshotStatus,
            postProcessingStatus: processingStatus,
            debugStatus: "Retried",
            customVocabulary: item.customVocabulary,
            audioFileName: item.audioFileName,
            contextAppName: item.contextAppName,
            contextBundleIdentifier: item.contextBundleIdentifier,
            contextWindowTitle: item.contextWindowTitle)
        do {
            try pipelineHistoryStore.update(updated)
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Failed to save retry result: \(error.localizedDescription)"
        }
        lastPostProcessingStatus = processingStatus
        // An empty retry result must not clobber the user's clipboard or the
        // last transcript (A-P2-2): only a non-empty result replaces them.
        guard !trimmedFinal.isEmpty else { return }
        lastTranscript = trimmedFinal
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmedFinal, forType: .string)
        // The clipboard just replaced whatever the user had there — say so,
        // same pattern as a completed dictation.
        statusText = "Copied to clipboard!"
        scheduleReadyStatusReset(after: 3, matching: ["Copied to clipboard!"])
    }

    private func retryItemFailed(item: PipelineHistoryItem, error: Error) {
        retryingItemIDs.remove(item.id)
        let updated = PipelineHistoryItem(
            intent: item.intent,
            selectedText: item.selectedText,
            capturedSelection: item.capturedSelection,
            id: item.id,
            timestamp: item.timestamp,
            rawTranscript: item.rawTranscript,
            postProcessedTranscript: item.postProcessedTranscript,
            postProcessingPrompt: item.postProcessingPrompt,
            systemPrompt: item.systemPrompt,
            contextSummary: item.contextSummary,
            contextSystemPrompt: item.contextSystemPrompt,
            contextPrompt: item.contextPrompt,
            contextScreenshotDataURL: item.contextScreenshotDataURL,
            contextScreenshotStatus: item.contextScreenshotStatus,
            postProcessingStatus: "Error: \(error.localizedDescription)",
            debugStatus: "Retry failed",
            customVocabulary: item.customVocabulary,
            audioFileName: item.audioFileName,
            contextAppName: item.contextAppName,
            contextBundleIdentifier: item.contextBundleIdentifier,
            contextWindowTitle: item.contextWindowTitle)
        try? pipelineHistoryStore.update(updated)
        pipelineHistory = pipelineHistoryStore.loadAllHistory()
    }

    // MARK: Permissions

    func startAccessibilityPolling() {
        guard accessibilityTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasAccessibility = AXIsProcessTrusted()
                self.hasScreenRecordingPermission = self.hasScreenCapturePermission()
                if self.hasAccessibility && self.hasScreenRecordingPermission {
                    self.stopAccessibilityPolling()
                }
            }
        }
        accessibilityTimer = timer
    }

    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                if !granted {
                    self?.openMicrophoneSettings()
                }
                completion(granted)
            }
        }
    }

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.hasScreenRecordingPermission = self?.hasScreenCapturePermission() ?? false
            }
        }
    }

    func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        alert.informativeText = "\(AppName.displayName) needs microphone access to transcribe your speech."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        if alert.runModal() == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        alert.informativeText = "Accessibility access lets \(AppName.displayName) paste text at your cursor position."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func showScreenshotPermissionAlert(message: String) {
        guard !hasShownScreenshotPermissionAlert else { return }
        hasShownScreenshotPermissionAlert = true
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        alert.informativeText = message
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    // MARK: Microphones

    func refreshAvailableMicrophones() {
        if audioRecorder.isRecording {
            needsMicrophoneRefreshAfterRecording = true
            return
        }
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    private func refreshAvailableMicrophonesIfNeeded() {
        guard needsMicrophoneRefreshAfterRecording else { return }
        needsMicrophoneRefreshAfterRecording = false
        refreshAvailableMicrophones()
    }

    // MARK: Sound

    func playAlertSound(named name: String) {
        guard alertSoundsEnabled else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = soundVolume
        sound.play()
    }

    // MARK: Voice macros

    private func precomputeMacros() {
        precomputedMacros = voiceMacros.map { macro in
            PrecomputedMacro(original: macro, normalizedCommand: Self.normalizeMacroCommand(macro.command))
        }
    }

    private static func normalizeMacroCommand(_ command: String) -> String {
        let lowercased = command.lowercased()
        let stripped = lowercased.components(separatedBy: CharacterSet.punctuationCharacters).joined()
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findMatchingMacro(for transcript: String) -> PrecomputedMacro? {
        let normalized = Self.normalizeMacroCommand(transcript)
        guard !normalized.isEmpty else { return nil }
        return precomputedMacros.first { $0.normalizedCommand == normalized }
    }

    // MARK: Debug

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        stopDebugOverlay()
        isDebugOverlayActive = true
        overlayManager.showRecording(mode: .toggle, isCommandMode: false)
        var phase = 0.0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            phase += 0.15
            let noise = Double.random(in: -0.15...0.15)
            let level = Float(min(max(0.3 + 0.2 * sin(phase) + noise, 0), 1))
            self.overlayManager.updateAudioLevel(level)
        }
        timer.resume()
        debugOverlayTimer = timer
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.cancel()
        debugOverlayTimer = nil
        guard isDebugOverlayActive else { return }
        isDebugOverlayActive = false
        overlayManager.dismiss()
    }

    @MainActor
    func showDebugUpdateAvailableOverlay() {
        let version = UpdateManager.shared.latestReleaseVersion.isEmpty
            ? "9.9.9"
            : UpdateManager.shared.latestReleaseVersion
        overlayManager.showUpdateAvailable(version: version)
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    // MARK: Launch at login

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: Audio files and flag file

    struct SavedAudioFile {
        let fileName: String
        let fileURL: URL
    }

    static func audioStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(AppName.displayName, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
    }

    static func recordingStateFlagURL() -> URL {
        let bundleName = Bundle.main.infoDictionary?["CFBundleName"] as? String
        let appName = (bundleName?.isEmpty == false) ? bundleName! : "OmniFlow"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("is-recording")
    }

    private static let recordingStateFlagQueue = DispatchQueue(label: "com.nick8cyber.omniflow.recording-state-flag")

    static func writeRecordingStateFlag(_ recording: Bool) {
        recordingStateFlagQueue.async {
            let url = recordingStateFlagURL()
            let fileManager = FileManager.default
            if recording {
                try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
                try? String(Date().timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    static func saveAudioFile(from tempURL: URL) -> SavedAudioFile? {
        let directory = audioStorageDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "\(UUID().uuidString).wav"
            let destination = directory.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: tempURL, to: destination)
            return SavedAudioFile(fileName: fileName, fileURL: destination)
        } catch {
            os_log("Failed to store recording audio: %@", log: appLog, type: .error,
                   error.localizedDescription)
            return nil
        }
    }

    private static func deleteAudioFile(named fileName: String) {
        try? FileManager.default.removeItem(at: audioStorageDirectory().appendingPathComponent(fileName))
    }
}
