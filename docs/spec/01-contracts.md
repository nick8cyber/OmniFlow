# OmniFlow — Контракты для имплементации (спека 01)

Интерфейсный договор: для каждого публичного типа/протокола/структуры/enum всех модулей —
точное имя Swift, поля с типами, сигнатуры методов и инициализаторов. Параллельные
имплементаторы собираются по этому файлу без рассогласований. Поведение — в
`00-architecture.md`; здесь только контракты и соглашения.

Модификаторы доступа указаны, где они нетривиальны (внутренний уровень `internal` по
умолчанию не помечается). `public` стоит только там, где он есть в оригинале
(`ModelConfiguration.swift`).

---

## 1. Соглашения

### 1.1 Именование и стиль

- Единый target: все файлы в одной модуле, без namespace-префиксов; типы верхнего уровня
  с глобальными именами (коллизии недопустимы).
- Сервисные singleton: `static let shared` (`NetworkMonitor`, `UpdateManager`,
  `VocabularyNotificationManager`, `LLMCooldownManager`).
- Акторы: `LLMCooldownManager` — `actor`; `AppState` — `final class … @unchecked Sendable`;
  сервисы — `final class`; чистая логика — `enum` без кейсов (functions namespace) или
  `struct`.
- Логирование: `os_log` c приватными константами
  `private let <name>Log = OSLog(subsystem: "com.nick8cyber.omniflow", category: "...")`.
  Категории: `"Recording"` (AppState, AudioRecorder), `"Transcription"`
  (TranscriptionService, TranscriptTextCore), `"RealtimeTranscription"`,
  `"GeminiLiveTranscription"`, `"Shortcuts"`. Рядом с `os_log` допустим `print` для
  history-store диагностики.
- Ошибки: `enum … : LocalizedError` c `errorDescription` (тексты — в 00-architecture).
- UserDefaults-ключи — магические строки в коде; их полный реестр в 00-architecture §2.2.

### 1.2 Структура каталогов

```
Sources/
  App.swift                          # @main OmniFlowApp, MenuBarLabel, StampedMenuBarIcon
  AppDelegate.swift
  AppName.swift
  AppState.swift                     # оркестратор (+ приватные хелпер-типы)
  AppState+AddVocabularyButton.swift
  Notification+VoiceToText.swift     # Notification.Name.showSetup/.showSettings
  MenuBarView.swift
  SettingsView.swift
  SetupView.swift
  ModelDropdownView.swift
  PipelineDebugPanelView.swift
  PipelineDebugContentView.swift
  ShortcutComponents.swift
  RecordingOverlay.swift
  SetupTestHotkeyHarness.swift
  AudioRecorder.swift
  LiveAudioLevelNormalizer.swift
  SystemAudioStatus.swift
  TranscriptionService.swift
  TranscriptTextCore.swift
  GeminiTranscription.swift
  GeminiLiveTranscription.swift
  GeminiLiveTranscriptionService.swift
  RealtimeTranscriptionService.swift
  RealtimeTranscriptBackend.swift
  PostProcessingService.swift
  AppContextService.swift
  LLMAPITransport.swift
  LLMCooldownManager.swift
  ModelConfiguration.swift
  PipelineHistoryItem.swift
  PipelineHistoryStore.swift
  ShortcutBinding.swift              # CommandModeStyle/ManualModifier + NSEvent-маппинг
  HotkeyManager.swift
  GlobalShortcutBackend.swift
  LocalShortcutCaptureBackend.swift
  ModifierKeyEventState.swift
  ShortcutCore/
    ShortcutModels.swift
    ShortcutMatcher.swift
    DictationShortcutSessionController.swift
  KeychainStorage.swift
  NetworkMonitor.swift
  UpdateManager.swift
  VocabularyNotificationManager.swift
  TestCaseExporter.swift
Tests/                               # свой мини-раннер, НЕ XCTest
  TestMain.swift                     # @main OmniFlowTests — вызывает .run() каждого набора
  TestSupport.swift
  AppContextServiceTests.swift
  GeminiLiveTranscriptionTests.swift
  GeminiTranscriptionTests.swift
  LLMCooldownManagerTests.swift
  ModelConfigurationTests.swift
  ShortcutCoreTests.swift
  SemanticVersionTests.swift
  TranscriptTextCoreTests.swift
Info.plist
Makefile                             # сборка .app через swiftc, цели: all/check/test/dmg/...
Resources/                           # AppIcon(.icns), dmg-background
```

- Приложение собирается `swiftc` напрямую (Makefile, `macOS 13.0` target, опционально
  universal arm64+x86_64); без Package.swift — тестовый раннер собирается из
  `TEST_PRODUCTION_SOURCES` (чистые модули) + `Tests/`.
- Dev-сборка: CFBundleName = `"OmniFlow Dev"`; `AppBuild.isDevBundle` проверяет именно
  CFBundleName.

---

## 2. AppState и его файлы

### 2.1 Поддерживающие типы (объявлены в `AppState.swift`)

```swift
struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
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
    static var visibleCases: [SettingsTab]   // без .debug вне dev-бандла
    var title: String    // "General" | "Prompts" | "Voice Macros" | "Run Log" | "Debug"
    var icon: String     // "gearshape" | "text.bubble" | "music.mic" |
                         // "clock.arrow.circlepath" | "wrench.and.screwdriver"
}

enum AppBuild {
    static var isDevBundle: Bool   // CFBundleName == "OmniFlow Dev"
}

// private в файле, контракт для имплементатора:
private struct PreservedPasteboardEntry {          // type + одно из значений
    let type: NSPasteboard.PasteboardType
    let value: Value                               // enum Value { string(String) |
                                                   //   propertyList(Any) | data(Data) }
}
private struct PreservedPasteboardItem {
    init(item: NSPasteboardItem)
    func makePasteboardItem() -> NSPasteboardItem
}
private struct PreservedPasteboardSnapshot {
    init(pasteboard: NSPasteboard)
    func restore(to pasteboard: NSPasteboard)
}
private struct PendingClipboardRestore {
    let snapshot: PreservedPasteboardSnapshot
    let expectedChangeCount: Int
    let writtenTranscript: String
}
private struct TranscriptCommandParsingResult {
    let transcript: String
    let shouldPressEnterAfterPaste: Bool
}
private enum CommandInvocation: String { case automatic, manual }
private enum SessionIntent { case dictation; case command(invocation: CommandInvocation,
    selectedText: String) }                        // + isCommandMode, persistedIntent,
                                                   // persistedSelectedText, isManualCommand,
                                                   // static fromPersisted(intent:selectedText:)
```

### 2.2 `final class AppState: ObservableObject, @unchecked Sendable`

Полный список @Published и приватных полей — 00-architecture §2.3. Здесь — публичная
поверхность (методы в порядке объявления):

```swift
final class AppState: ObservableObject, @unchecked Sendable {
    // MARK: Init / lifecycle
    init()
    func startHotkeyMonitoring()
    func stopHotkeyMonitoring()
    func suspendHotkeyMonitoringForShortcutCapture()
    func resumeHotkeyMonitoringAfterShortcutCapture()

    // MARK: Константы
    let maxPipelineHistoryCount: Int                     // 20
    static let defaultContextScreenshotMaxDimension: Int // 1024
    static let contextScreenshotDimensionOptions: [Int]  // [1024, 768, 640, 512]
    static let defaultTranscriptionModel: String         // "whisper-large-v3"
    static let transcriptionLanguageOptions: [(code: String, name: String)] // 31 пара
    static let defaultPostProcessingModel: String        // "openai/gpt-oss-20b"
    static let defaultPostProcessingFallbackModel: String // "qwen/qwen3.6-27b"
    static let defaultContextModel: String               // "qwen/qwen3.6-27b"
    static let defaultAPIBaseURL: String                 // "https://api.groq.com/openai/v1"

    // MARK: Фабрики сервисов
    static func makeAppContextService(apiKey: String, baseURL: String,
        customContextPrompt: String, contextModel: String,
        contextScreenshotMaxDimension: Int) -> AppContextService
    func makeAppContextService() -> AppContextService
    func makeTranscriptionService() throws -> TranscriptionService

    // MARK: История
    func clearPipelineHistory()
    func deleteHistoryEntry(id: UUID)
    func retryTranscription(item: PipelineHistoryItem)

    // MARK: Разрешения
    func startAccessibilityPolling()
    func stopAccessibilityPolling()
    func openAccessibilitySettings()
    func openMicrophoneSettings()
    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void)
    func hasScreenCapturePermission() -> Bool
    func requestScreenCapturePermission()
    func openScreenCaptureSettings()
    func showMicrophonePermissionAlert()
    func showAccessibilityAlert()

    // MARK: Launch at login
    func refreshLaunchAtLoginStatus()

    // MARK: Микрофоны
    func refreshAvailableMicrophones()

    // MARK: Шорткаты / command mode
    var usesFnShortcut: Bool { get }
    var hasEnabledHoldShortcut: Bool { get }
    var hasEnabledToggleShortcut: Bool { get }
    var shortcutStatusText: String { get }
    var shortcutStartDelayMilliseconds: Int { get }
    func savedCustomShortcut(for role: ShortcutRole) -> ShortcutBinding?
    var commandModeManualModifierValidationMessage: String? { get }
    @discardableResult func setCommandModeEnabled(_ enabled: Bool) -> String?
    @discardableResult func setCommandModeStyle(_ style: CommandModeStyle) -> String?
    @discardableResult func setCommandModeManualModifier(_ modifier: CommandModeManualModifier) -> String?
    @discardableResult func setShortcut(_ binding: ShortcutBinding, for role: ShortcutRole) -> String?

    // MARK: Сессия диктовки
    func toggleRecording()
    func copyLastTranscriptToPasteboard()

    // MARK: Звук
    func playAlertSound(named name: String)

    // MARK: Аудио-файлы и flag-файл
    struct SavedAudioFile { let fileName: String; let fileURL: URL }
    static func audioStorageDirectory() -> URL
    static func recordingStateFlagURL() -> URL
    static func writeRecordingStateFlag(_ recording: Bool)
    static func saveAudioFile(from tempURL: URL) -> SavedAudioFile?

    // MARK: Парсинг press-enter / промпты (static, тестируемые)
    static func resolvedSystemPrompt(_ customSystemPrompt: String) -> String

    // MARK: Debug
    func toggleDebugOverlay()
    @MainActor func showDebugUpdateAvailableOverlay()
    func toggleDebugPanel()
}
```

Сигнатура приватного (но обязательного к воспроизведению) конвейера:

```swift
private func processTranscript(_ rawTranscript: String, intent: SessionIntent,
    context: AppContext, postProcessingService: PostProcessingService,
    customVocabulary: String, customSystemPrompt: String,
    outputLanguage: String = "", preserveExactWording: Bool)
    async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String)

private static func resolveRawTranscript(realtimeService: (any RealtimeTranscriptBackend)?,
    fileService: TranscriptionService, fileURL: URL) async throws -> String

private static func parseTranscriptCommands(from transcript: String,
    pressEnterCommandEnabled: Bool) -> TranscriptCommandParsingResult

private static func statusMessage(for outcome: TranscriptProcessingOutcome,
    parsedTranscript: TranscriptCommandParsingResult, isRetry: Bool = false) -> String

private func formattedTranscriptionError(_ error: Error) -> String
private static func urlErrorCode(in error: Error) -> URLError.Code?   // глубина 8
private func formattedRecordingStartError(_ error: Error) -> String
```

`private enum TranscriptProcessingOutcome` с кейсами
`skippedEmptyRawTranscript`, `voiceMacro(command: String)`, `postProcessingSucceeded`,
`postProcessingFailedFallback`, `preservedExactWording`,
`preservedExactWordingTranslated`, `preservedExactWordingTranslationFailedFallback`,
`commandModeSucceeded(invocation: CommandInvocation)`,
`commandModeFailedFallback(invocation: CommandInvocation)` и методом
`func statusMessage(isRetry: Bool = false) -> String`.

Расширение `AppState+AddVocabularyButton.swift`:

```swift
@MainActor extension AppState {
    @discardableResult func pasteWordToVocabulary() -> String?
}
```

---

## 3. Аудио

### 3.1 `AudioRecorder.swift`

```swift
struct AudioDevice: Identifiable {
    let id: String       // = uid
    let uid: String
    let name: String
    static func availableInputDevices() -> [AudioDevice]   // отсортировано по имени
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice
    case noAudioBuffersReceived
    case failedToCreateCaptureInput(String)
    case failedToStartCaptureSession(String)
    case failedToBeginFileRecording(String)
    var errorDescription: String? { get }
}

final class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published var isRecording: Bool
    @Published var audioLevel: Float                  // 0…1, нормализованный, main queue
    var onRecordingReady: (() -> Void)?               // первый не-тихий буфер, main
    var onRecordingFailure: ((Error) -> Void)?        // ровно один раз, main
    var onPCM16Samples: ((Data) -> Void)?             // PCM16 LE mono 24 kHz, sample-очередь
    static let realtimeSampleRate: Int                // 24_000

    override init()
    func startRecording(deviceUID: String? = nil) throws
    func stopRecording(completion: @escaping (URL?) -> Void)   // URL=nil если нет данных/ошибка
    func cancelRecording()
    func cleanup()                                    // удалить temp-файл
}
```

### 3.2 `LiveAudioLevelNormalizer.swift`

```swift
struct LiveAudioLevelNormalizer {
    init()                                            // noiseFloorDB=-55, peakCeilingDB=-37, displayLevel=0
    mutating func reset()
    mutating func normalizedLevel(forRMS rms: Float) -> Float   // 0…1
}
```

### 3.3 `SystemAudioStatus.swift`

```swift
enum SystemAudioStatus {
    static func isDefaultOutputMuted() -> Bool
    @discardableResult static func setDefaultOutputMuted(_ muted: Bool) -> Bool
    static func defaultOutputVolume() -> Float?
}
```

---

## 4. Транскрипция

### 4.1 `TranscriptionService.swift`

```swift
class TranscriptionService {
    init(apiKey: String,
         baseURL: String = "https://api.groq.com/openai/v1",
         transcriptionModel: String = "whisper-large-v3",
         language: String? = nil,
         customVocabulary: String = "") throws        // throws invalidBaseURL
    func transcribe(fileURL: URL) async throws -> String
    static func responseFormat(forModel model: String) -> String
    static func validateAPIKey(_ key: String,
        baseURL: String = "https://api.groq.com/openai/v1") async -> ValidateOutcome
    static func validateOutcome(forHTTPStatus status: Int, host: String?) -> ValidateOutcome
    static func friendlyHTTPMessage(status: Int, host: String?) -> String
}

/// Результат валидации ключа (аудит B, P1-2): различает отвергнутый ключ
/// (HTTP 401/403) и недоступного провайдера (сеть/таймаут/429/5xx).
enum ValidateOutcome: Equatable {
    case valid
    case invalidKey
    case unavailable(String)   // user-facing detail
}

enum TranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)
    case audioPreparationFailed(String)
    var errorDescription: String? { get }
}
```

### 4.2 `TranscriptTextCore.swift`

```swift
enum TranscriptionResponseParsingError: Error, Equatable { case invalidResponse }

enum TranscriptionResponseParser {
    static func parse(_ data: Data) throws -> String   // JSON text | plain text fallback
    // приватно: hallucinationPhrases: Set<String>, hallucinationNoSpeechThreshold = 0.1
}

enum TranscriptOutputSanitizer {
    static func verbatimTranslation(_ value: String) -> String
    static func postProcessedTranscript(_ value: String) -> String  // кавычки + "EMPTY"→""
    static func commandModeTranscript(_ value: String) -> String    // только trim
    static func appearsToHaveExecutedInstruction(rawTranscript: String,
        cleanedTranscript: String, outputLanguage: String) -> Bool
}
```

### 4.3 `GeminiTranscription.swift`

```swift
enum GeminiTranscription {
    static let defaultBaseURL: String                  // "https://generativelanguage.googleapis.com/v1beta"
    static func handlesModel(_ model: String) -> Bool  // gemini-*transcribe*, не "-live"
    static func resolvedBaseURL(from configuredBaseURL: String) -> String
    static func endpoint(baseURL: URL) -> URL          // + "/interactions"
    static func requestBody(model: String, audioData: Data, mimeType: String,
        customVocabulary: String) throws -> Data
    static func vocabularyTerms(from rawVocabulary: String) -> [String]  // дедуп + ≤1000
    static func failureMessage(fromResponse data: Data, fallback: String) -> String
    static func transcript(fromResponse data: Data) throws -> String
}
```

### 4.4 `RealtimeTranscriptBackend.swift`

```swift
protocol RealtimeTranscriptBackend: AnyObject {
    var onPartialUpdate: ((String) -> Void)? { get set }   // main queue
    func start() throws
    func appendPCM16(_ data: Data)                          // 16-bit LE mono 24 kHz
    func commitAndAwaitFinal() async throws -> String
    func cancel()
}
```

### 4.5 `RealtimeTranscriptionService.swift`

```swift
enum RealtimeTranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case notConnected
    case serverError(code: String, message: String)
    case closedBeforeFinal
    var errorDescription: String? { get }
}

final class RealtimeTranscriptionService: RealtimeTranscriptBackend {
    struct Configuration {
        let baseURL: String
        let apiKey: String
        let model: String
        let language: String?
    }
    init(config: Configuration, session: URLSession = .shared)
    // protocol methods: start/appendPCM16/commitAndAwaitFinal/cancel
    static func deriveWebSocketURL(baseURL: String, model: String,
        language: String?) -> URL?
}
```

### 4.6 `GeminiLiveTranscription.swift`

```swift
enum GeminiLiveTranscription {
    struct ServerFrame {
        var transcript: String?
        var isComplete: Bool
        var errorMessage: String?
        var isSetupComplete: Bool
    }
    static let defaultBaseURL: String                  // "wss://generativelanguage.googleapis.com"
    static func handlesModel(_ model: String) -> Bool  // gemini-*…-transcribe-live
    static func socketURL(baseURL: String) -> URL?
    static func setupMessage(model: String, customVocabulary: String) throws -> String
    static func audioMessage(pcm16: Data, sampleRate: Int) throws -> String
    static func audioStreamEndMessage() throws -> String
    static func normalizedModelPath(_ model: String) -> String   // "models/<name>"
    static func parseServerFrame(_ text: String) -> ServerFrame
}
```

### 4.7 `GeminiLiveTranscriptionService.swift`

```swift
final class GeminiLiveTranscriptionService: RealtimeTranscriptBackend {
    struct Configuration {
        let baseURL: String
        let apiKey: String
        let model: String
        let customVocabulary: String
        let sampleRate: Int                            // AudioRecorder.realtimeSampleRate
    }
    init(config: Configuration, session: URLSession = .shared)
    // protocol methods
}
```

---

## 5. Пост-обработка, контекст, LLM-инфраструктура

### 5.1 `PostProcessingService.swift`

```swift
enum PostProcessingError: LocalizedError {
    case requestFailed(Int, String)
    case rateLimited(model: String, retryAfter: TimeInterval)
    case invalidResponse(String)
    case invalidInput(String)
    case emptyOutput
    case requestTimedOut(TimeInterval)
    case suspectedInstructionExecution
    var errorDescription: String? { get }
}

struct PostProcessingResult {
    let transcript: String
    let prompt: String
}

final class PostProcessingService {
    static let defaultSystemPrompt: String        // длинный текст (00-architecture §4.4)
    static let defaultSystemPromptDate: String    // "2026-05-13"
    static let commandModeSystemPrompt: String

    init(apiKey: String,
         baseURL: String = "https://api.groq.com/openai/v1",
         preferredModel: String = "",
         preferredFallbackModel: String = "",
         instructionExecutionGuardEnabled: Bool = true)

    func postProcess(transcript: String, context: AppContext, customVocabulary: String,
        customSystemPrompt: String = "", outputLanguage: String = "")
        async throws -> PostProcessingResult

    func translateVerbatim(transcript: String, targetLanguage: String)
        async throws -> PostProcessingResult

    func commandTransform(selectedText: String, voiceCommand: String, context: AppContext,
        customVocabulary: String, outputLanguage: String = "")
        async throws -> PostProcessingResult

    static func applyOutputLanguage(_ prompt: String, language: String) -> String
    static func verbatimTranslationSystemPrompt(targetLanguage: String) -> String
}
```

### 5.2 `AppContextService.swift`

```swift
struct AppSelectionSnapshot {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
}

struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String
    let contextSystemPrompt: String?
    let contextPrompt: String?
    let screenshotDataURL: String?
    let screenshotMimeType: String?
    let screenshotError: String?
    var contextSummary: String { get }     // == currentActivity
}

final class AppContextService {
    static let defaultContextModel: String           // "qwen/qwen3.6-27b"
    static let defaultContextPrompt: String          // двух предложений, текст в 00-arch
    static let defaultContextPromptDate: String      // "2026-02-24"
    static let defaultScreenshotMaxDimension: CGFloat // 1024

    init(apiKey: String,
         baseURL: String = "https://api.groq.com/openai/v1",
         customContextPrompt: String = "",
         contextModel: String = AppContextService.defaultContextModel,
         screenshotMaxDimension: CGFloat = AppContextService.defaultScreenshotMaxDimension)

    func collectSelectionSnapshot() -> AppSelectionSnapshot
    func collectContext() async -> AppContext
    static func activitySummary(from rawContent: String, model: String) -> String?
}
```

### 5.3 `LLMAPITransport.swift`

```swift
enum LLMAPITransport {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse)
    static func upload(for request: URLRequest, from bodyData: Data)
        async throws -> (Data, URLResponse)
}
```

### 5.4 `LLMCooldownManager.swift`

```swift
actor LLMCooldownManager {
    static let shared = LLMCooldownManager()
    func isInCooldown(_ model: String) -> Bool
    func setCooldown(_ model: String, retryAfterSeconds: TimeInterval, persist: Bool = false)
    func effectivePrimary(_ primary: String, fallback: String?) -> String?
    nonisolated static func udKey(for model: String) -> String
    // "llm_cooldown_expiry_\(model)"
    nonisolated static func rateLimitCooldown(from httpResponse: HTTPURLResponse)
        -> (seconds: TimeInterval, isDaily: Bool)
}
```

### 5.5 `ModelConfiguration.swift` (public!)

```swift
public struct ModelConfig {
    public let maxCompletionTokens: Int?
    public let reasoningEffort: String?
    public let includeReasoning: Bool?
    public let shouldStripThinkTags: Bool
}

public struct ModelConfiguration {
    public static let llmModels: [String]
    // ["openai/gpt-oss-20b", "openai/gpt-oss-120b", "openai/gpt-oss-safeguard-20b",
    //  "qwen/qwen3.6-27b", "groq/compound", "groq/compound-mini"]
    public static let visionModels: [String]          // ["qwen/qwen3.6-27b"]
    public static let transcriptionModels: [String]
    // ["whisper-large-v3", "whisper-large-v3-turbo", "gemini-3.5-transcribe"]
    public static func config(for model: String) -> ModelConfig
    public static func stripThinkTags(_ text: String) -> String
}
```

`config(for:)` — таблица (после нормализации lowercase/trim и алиасов без провайдера
`qwen3-32b→qwen/qwen3-32b`, `qwen3.6-27b`, `gpt-oss-20b/120b/safeguard-20b` → с
`openai/`):

| model | maxCompletionTokens | reasoningEffort | includeReasoning | shouldStripThinkTags |
|---|---|---|---|---|
| openai/gpt-oss-20b | 4096 | "low" | false | false |
| openai/gpt-oss-120b | nil | nil | nil | false |
| openai/gpt-oss-safeguard-20b | nil | nil | nil | false |
| qwen/qwen3-32b | nil | nil | nil | true |
| qwen/qwen3.6-27b | nil | "none" | false | true |
| llama-3.1-8b-instant / llama-3.3-70b-versatile / meta-llama/* / allam-2-7b / canopylabs/* / groq/compound / groq/compound-mini / whisper-large-v3 / whisper-large-v3-turbo | nil | nil | nil | false |
| прочие (fallback) | nil | nil | nil | false |

---

## 6. Хоткеи

### 6.1 `ShortcutCore/ShortcutModels.swift`

```swift
struct ShortcutModifiers: OptionSet, Hashable, Codable {
    let rawValue: Int
    static let command  // 1<<0
    static let control  // 1<<1
    static let option   // 1<<2
    static let shift    // 1<<3
    static let function // 1<<4
    var orderedDisplayNames: [String] { get }
    // ["Cmd ⌘", "Ctrl ⌃", "Option ⌥", "Shift ⇧", "Fn 🌐"] в этом порядке
}

enum ShortcutBindingKind: String, Codable { case disabled, key, modifierKey }

enum RecordingTriggerMode: String, Codable {
    case hold, toggle
    var badgeTitle: String { get }   // "Hold" | "Tap"
}

enum ShortcutRole { case hold, toggle, copyAgain
    var title: String { get }        // "Hold to Talk" | "Tap to Toggle" | "Paste Again"
}

enum ShortcutEvent: Equatable {
    case holdActivated, holdDeactivated, toggleActivated, toggleDeactivated, copyAgainTriggered
}

struct ShortcutConfiguration: Equatable {
    let hold: ShortcutBinding
    let toggle: ShortcutBinding
    let copyAgain: ShortcutBinding
    let permittedAdditionalExactMatchModifiers: ShortcutModifiers
    init(hold: ShortcutBinding, toggle: ShortcutBinding,
         copyAgain: ShortcutBinding = .disabled,
         permittedAdditionalExactMatchModifiers: ShortcutModifiers = [])
    static let disabled: ShortcutConfiguration
}

enum ShortcutPreset: String, CaseIterable, Identifiable, Codable {
    case fnKey = "fn", rightOption = "rightOption", f5 = "f5"
    var title: String { get }        // "Fn 🌐" | "Right Option ⌥" | "F5"
    var binding: ShortcutBinding { get }
    // fnKey:       keyCode 63, keyDisplay "Fn",           kind .modifierKey
    // rightOption: keyCode 61, keyDisplay "Right Option", kind .modifierKey
    // f5:          keyCode 96, keyDisplay "F5",           kind .key
}

struct ShortcutBinding: Codable, Hashable, Identifiable, Equatable {
    let keyCode: UInt16
    let keyDisplay: String
    let modifiers: ShortcutModifiers
    let kind: ShortcutBindingKind
    let preset: ShortcutPreset?
    let exactModifierKeyCodes: Set<UInt16>?
    init(keyCode: UInt16, keyDisplay: String, modifiers: ShortcutModifiers,
         kind: ShortcutBindingKind, preset: ShortcutPreset?,
         exactModifierKeyCodes: Set<UInt16>? = nil)
    var id: String { get }
    // "\(kind.rawValue):\(keyCode):\(modifiers.rawValue):\(preset?.rawValue ?? "custom"):\(exactIDs)"
    var displayName: String { get }             // "Disabled" | modifiers + primary, join " + "
    var selectionTitle: String { get }
    var isCustom: Bool { get }
    var isDisabled: Bool { get }
    var specificityScore: Int { get }           // modifierDisplayNames.count
    var usesFnKey: Bool { get }                 // keyCode 63 или .function
    var requiresExactModifierMatch: Bool { get }
    func withAddedModifiers(_ extraModifiers: ShortcutModifiers) -> ShortcutBinding
    func normalizedForStorageMigration() -> ShortcutBinding
    func conflicts(with other: ShortcutBinding) -> Bool
    var modifierDisplayNames: [String] { get }

    static let disabled: ShortcutBinding        // keyCode 0, "Disabled", .disabled
    static let defaultHold: ShortcutBinding     // ShortcutPreset.fnKey.binding
    static let defaultToggle: ShortcutBinding   // defaultHold.withAddedModifiers(.command)
    static let modifierKeyCodes: Set<UInt16>    // [54,55,56,58,59,60,61,62,63]
    static func logicalModifier(forKeyCode: UInt16) -> ShortcutModifiers?
    // 54,55→.command; 59,62→.control; 58,61→.option; 56,60→.shift; 63→.function
    static func modifiers(for pressedModifierKeyCodes: Set<UInt16>) -> ShortcutModifiers
    static func canonicalModifierKeyCode(for keyCode: UInt16) -> UInt16
    // 54→55, 60→56, 61→58, 62→59, иначе сам
    static func exactModifierKeyCodes(for modifiers: ShortcutModifiers) -> Set<UInt16>
    // левые: cmd 55, ctrl 59, opt 58, shift 56, fn 63
    static func exactModifierKeyCodesPreservingSides(for modifiers: ShortcutModifiers) -> Set<UInt16>
    // обе стороны: cmd {54,55}, ctrl {59,62}, opt {58,61}, shift {56,60}, fn {63}
    static func matchingModifierKeyCodes(for modifiers: ShortcutModifiers) -> Set<UInt16>
    static func logicalModifierDisplayLabel(for keyCode: UInt16) -> String
    static func modifier(forKeyCode keyCode: UInt16) -> ShortcutModifiers?
    static func exactModifierDisplayLabel(for keyCode: UInt16) -> String?
    static func normalizedExactModifierKeyCodes(_ set: Set<UInt16>?) -> Set<UInt16>?
    static func orderedExactModifierKeyCodes(_ set: Set<UInt16>) -> [UInt16]
    static func exactModifierKeyCodesMatch(_ pressed: Set<UInt16>,
        exactModifierKeyCodes: Set<UInt16>,
        permittedAdditionalExactMatchModifiers: ShortcutModifiers = []) -> Bool
    static func modifierDisplayNames(for modifiers: ShortcutModifiers,
        exactModifierKeyCodes: Set<UInt16>?) -> [String]
}
```

### 6.2 `ShortcutBinding.swift`

```swift
enum CommandModeStyle: String, CaseIterable, Codable, Identifiable {
    case automatic, manual
    var title: String { get }        // "Automatic" | "Manual"
}

enum CommandModeManualModifier: String, CaseIterable, Codable, Identifiable {
    case command, control, option, shift
    var title: String { get }        // "Cmd ⌘" | "Ctrl ⌃" | "Option ⌥" | "Shift ⇧"
    var shortcutModifier: ShortcutModifiers { get }
}

extension ShortcutModifiers {
    init(eventFlags: NSEvent.ModifierFlags)          // только 5 логических модификаторов
}

extension ShortcutBinding {
    static func from(event: NSEvent, pressedModifierKeyCodes: Set<UInt16>) -> ShortcutBinding?
    static func fromModifierKeyCode(_ keyCode: UInt16,
        pressedModifierKeyCodes: Set<UInt16>, allowBareModifier: Bool = false) -> ShortcutBinding?
    static func displayLabel(for keyCode: UInt16, event: NSEvent? = nil) -> String
}
```

### 6.3 `ShortcutCore/ShortcutMatcher.swift`

```swift
enum ShortcutInputEvent: Equatable {
    case modifierChanged(keyCode: UInt16, isDown: Bool)
    case modifierSnapshot(Set<UInt16>)
    case keyChanged(keyCode: UInt16, isDown: Bool, isRepeat: Bool)
    case backendReset
}

enum ShortcutConsumeDecision: Equatable { case consume, passthrough }

struct ShortcutInputState: Equatable {
    var pressedKeyCodes: Set<UInt16>
    var pressedModifierKeyCodes: Set<UInt16>
    var holdIsActive: Bool
    var toggleIsActive: Bool
    var copyAgainIsActive: Bool
    init()                                        // все пустые/false
    var currentModifiers: ShortcutModifiers { get }
    func hasPressedShortcutInputs(configuration: ShortcutConfiguration) -> Bool
}

struct ShortcutMatchResult: Equatable {
    let state: ShortcutInputState
    let emittedEvents: [ShortcutEvent]
    let consumeDecision: ShortcutConsumeDecision
}

enum ShortcutMatcher {
    static func reduce(state: ShortcutInputState, event: ShortcutInputEvent,
        configuration: ShortcutConfiguration) -> ShortcutMatchResult
}
```

Порядок emittedEvents: активации по убыванию `specificityScore`, затем деактивации по
возрастанию; `copyAgainTriggered` — только leading edge.

### 6.4 `ShortcutCore/DictationShortcutSessionController.swift`

```swift
enum DictationShortcutAction: Equatable {
    case start(RecordingTriggerMode)
    case stop
    case switchedToToggle
}

final class DictationShortcutSessionController {
    private(set) var activeMode: RecordingTriggerMode?
    private(set) var toggleStopArmed: Bool
    init()
    func handle(event: ShortcutEvent, isTranscribing: Bool) -> DictationShortcutAction?
    func beginManual(mode: RecordingTriggerMode)
    func forceToggleMode()
    func reset()
}
```

### 6.5 `HotkeyManager.swift`

```swift
final class HotkeyManager {
    init()
    var onShortcutEvent: ((ShortcutEvent) -> Void)?
    var onEscapeKeyPressed: (() -> Bool)?             // true = событие поглощено
    var currentPressedModifiers: ShortcutModifiers { get }
    var hasPressedShortcutInputs: Bool { get }
    func start(configuration: ShortcutConfiguration) throws
    func stop()
}
```

### 6.6 `GlobalShortcutBackend.swift`

```swift
enum GlobalShortcutBackendError: LocalizedError {
    case eventTapUnavailable
    case eventTapRunLoopSourceUnavailable
    var errorDescription: String? { get }
}

final class GlobalShortcutBackend {
    init()
    var onInputEvent: ((ShortcutInputEvent) -> ShortcutConsumeDecision)?
    var onEscapeKeyPressed: (() -> Bool)?
    func start() throws
    func stop()
}
```

### 6.7 `LocalShortcutCaptureBackend.swift`

```swift
final class LocalShortcutCaptureBackend {
    init()
    var onInputEvent: ((ShortcutInputEvent) -> Void)?
    var onKeyDownEvent: ((NSEvent) -> Void)?
    func start()
    func stop()
}
```

### 6.8 `ModifierKeyEventState.swift`

```swift
enum ModifierKeyEventState {
    static let fnKeyCode: UInt16                      // 63
    static func isKeyDown(for event: NSEvent) -> Bool?
    static func pressedModifierKeyCodes(for event: NSEvent,
        trustedFunctionKeyIsDown: Bool? = nil) -> Set<UInt16>
    static func currentFunctionKeyIsDown() -> Bool
}
```

### 6.9 `SetupTestHotkeyHarness.swift`

```swift
@MainActor final class SetupTestHotkeyHarness: ObservableObject {
    init()
    var isTranscribing: Bool                          // var, выставляется снаружи
    var onAction: ((DictationShortcutAction) -> Void)?
    func start(configuration: ShortcutConfiguration, startDelay: TimeInterval) throws
    func stop()
    func resetSession()
}
```

---

## 7. История и данные

### 7.1 `PipelineHistoryItem.swift`

```swift
enum PipelineHistoryItemIntent: String, Codable {
    case dictation
    case commandAutomatic = "command:automatic"
    case commandManual = "command:manual"
}

struct PipelineHistoryItem: Identifiable, Codable {
    let intent: PipelineHistoryItemIntent             // дефолт .dictation
    let selectedText: String?                         // nil
    let capturedSelection: String?                    // nil
    let id: UUID                                      // дефолт UUID()
    let timestamp: Date
    let rawTranscript: String
    let postProcessedTranscript: String
    let postProcessingPrompt: String?
    let systemPrompt: String?                         // nil
    let contextSummary: String
    let contextSystemPrompt: String?                  // nil
    let contextPrompt: String?                        // nil
    let contextScreenshotDataURL: String?
    let contextScreenshotStatus: String
    let postProcessingStatus: String
    let debugStatus: String
    let customVocabulary: String
    let audioFileName: String?                        // nil
    let contextAppName: String?                       // nil
    let contextBundleIdentifier: String?              // nil
    let contextWindowTitle: String?                   // nil

    init(intent: PipelineHistoryItemIntent = .dictation, selectedText: String? = nil,
         capturedSelection: String? = nil, id: UUID = UUID(), timestamp: Date,
         rawTranscript: String, postProcessedTranscript: String,
         postProcessingPrompt: String?, systemPrompt: String? = nil,
         contextSummary: String, contextSystemPrompt: String? = nil,
         contextPrompt: String? = nil, contextScreenshotDataURL: String?,
         contextScreenshotStatus: String, postProcessingStatus: String,
         debugStatus: String, customVocabulary: String, audioFileName: String? = nil,
         contextAppName: String? = nil, contextBundleIdentifier: String? = nil,
         contextWindowTitle: String? = nil)
}
```

### 7.2 `PipelineHistoryStore.swift`

```swift
final class PipelineHistoryStore {
    init()                                            // загрузка синхронная, фолбэк in-memory
    func loadAllHistory() -> [PipelineHistoryItem]    // timestamp desc
    func append(_ item: PipelineHistoryItem, maxCount: Int) throws -> [String]
    func update(_ item: PipelineHistoryItem) throws
    func delete(id: UUID) throws -> String?           // → audioFileName удалённой записи
    func clearAll() throws -> [String]
    func trim(to maxCount: Int) throws -> [String]
}

@objc(PipelineHistoryEntry)
final class PipelineHistoryEntry: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var intent: String?
    @NSManaged var selectedText: String?
    @NSManaged var capturedSelection: String?
    @NSManaged var timestamp: Date?
    @NSManaged var rawTranscript: String?
    @NSManaged var postProcessedTranscript: String?
    @NSManaged var postProcessingPrompt: String?
    @NSManaged var systemPrompt: String?
    @NSManaged var contextSummary: String?
    @NSManaged var contextSystemPrompt: String?
    @NSManaged var contextPrompt: String?
    @NSManaged var contextScreenshotDataURL: String?
    @NSManaged var contextScreenshotStatus: String?
    @NSManaged var postProcessingStatus: String?
    @NSManaged var debugStatus: String?
    @NSManaged var customVocabulary: String?
    @NSManaged var audioFileName: String?
    @NSManaged var contextAppName: String?
    @NSManaged var contextBundleIdentifier: String?
    @NSManaged var contextWindowTitle: String?
}
```

Entity-схема (строится в `makeModel()`, entity name `PipelineHistoryEntry`):
`intent` String optional default `"dictation"`; `selectedText`, `capturedSelection`,
`postProcessingPrompt`, `systemPrompt`, `contextSystemPrompt`, `contextPrompt`,
`contextScreenshotDataURL`, `audioFileName`, `contextAppName`,
`contextBundleIdentifier`, `contextWindowTitle` — String optional; `id` UUID required;
`timestamp` Date required; `rawTranscript`, `postProcessedTranscript`, `contextSummary`,
`contextScreenshotStatus`, `postProcessingStatus`, `debugStatus`, `customVocabulary` —
String required.

### 7.3 `KeychainStorage.swift`

```swift
enum AppSettingsStorage {
    static func load(account: String) -> String?      // с миграцией из Keychain
    static func save(_ value: String, account: String)
    static func delete(account: String)
}
```

Файл: `~/Library/Application Support/<AppName>/.settings`, JSON `[String: String]`,
запись атомарная, права 0600. Ключ миграции: `"keychain_migration_done"`.
Keychain-миграция: kSecClassGenericPassword, service = `Bundle.main.bundleIdentifier ??
"com.nick8cyber.omniflow"`, account = ключ.

---

## 8. Сервисное

### 8.1 `NetworkMonitor.swift`

```swift
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private init()
    var isOnline: Bool { get }        // потокобезопасно, дефолт true
    func start()                      // idempotent
}
```

### 8.2 `UpdateManager.swift`

```swift
struct GitHubRelease: Decodable {
    let tagName: String            // "tag_name"
    let name: String?
    let body: String?
    let htmlUrl: String            // "html_url"
    let publishedAt: String        // "published_at"
    let assets: [GitHubReleaseAsset]
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadUrl: String // "browser_download_url"
    let size: Int
}

struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]
    init?(_ value: String)         // допускает v-префикс и +build; prerelease-семантика semver
}

enum UpdateStatus: Equatable { case idle, downloading, installing, readyToRelaunch, error(String) }

@MainActor final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    private init()
    @Published var updateAvailable: Bool
    @Published var latestRelease: GitHubRelease?
    @Published var latestReleaseVersion: String
    @Published var latestReleaseDate: String
    @Published var isChecking: Bool
    @Published var downloadProgress: Double?
    @Published var updateStatus: UpdateStatus
    @Published var lastCheckDate: Date?
    var autoCheckEnabled: Bool { get set }             // UserDefaults "updateAutoCheckEnabled", деф. true
    func startPeriodicChecks()
    func checkForUpdates(userInitiated: Bool) async
    func shouldShowPostTranscriptionReminder() -> Bool
    func markPostTranscriptionReminderShown()
    func showUpdateAlert()
    func showUpToDateAlert()
    func showReleaseNotes()
    func cancelDownload()
    func downloadAndInstall(release: GitHubRelease)
}
```

### 8.3 `VocabularyNotificationManager.swift`

```swift
@MainActor final class VocabularyNotificationManager: ObservableObject, @unchecked Sendable {
    static let shared = VocabularyNotificationManager()
    private init()
    @Published var showCheckmark: Bool
    func flashCheckmark()                              // 2 c
}
```

### 8.4 `TestCaseExporter.swift`

```swift
struct TestCaseExporter {
    enum ExportError: Error, LocalizedError {
        case tempDirectoryCreationFailed(underlying: Error?)
        case zipFailed(Int32)
        case screenshotDecodeFailed
        case missingAudioFile(String)
        var errorDescription: String? { get }
    }
    @MainActor static func exportWithSavePanel(item: PipelineHistoryItem, audioDirURL: URL)
}
```

### 8.5 `Notification+VoiceToText.swift`

```swift
extension Notification.Name {
    static let showSetup: Notification.Name
    static let showSettings: Notification.Name
}
```

### 8.6 `AppName.swift`

```swift
enum AppName {
    static let displayName: String   // CFBundleName ?? "OmniFlow"
}
```

---

## 9. UI-слой (имена и зависимости; доскональная верстка не контракт)

| Тип | Родитель/протокол | Зависимости | Назначение |
|---|---|---|---|
| `OmniFlowApp` | `App` | `AppDelegate` (адаптер), `@AppStorage("show_menu_bar_icon")` | `MenuBarExtra` |
| `MenuBarLabel` | `View` (@MainActor) | `@EnvironmentObject AppState`, `@ObservedObject VocabularyNotificationManager.shared` | label меню-бара |
| `StampedMenuBarIcon` | enum | — | `static let templateImage: NSImage` |
| `AppDelegate` | `NSObject, NSApplicationDelegate` | `AppState` | окна, lifecycle |
| `MenuBarView` | `View` | `@EnvironmentObject AppState`, `@ObservedObject UpdateManager.shared` | меню |
| `SettingsView` | `View` | `@EnvironmentObject AppState` | корень настроек; вкладки `SettingsTab` |
| `SettingsCard<Content: View>` | `View` | — | карточка |
| `ProviderSettingsFields` | `View` | `@EnvironmentObject AppState` | поля провайдера/ключей |
| `DebugSettingsView` | `View` | `@EnvironmentObject AppState` | debug-вкладка |
| `GeneralSettingsView` | `View` | `@EnvironmentObject AppState`, `@StateObject GitHubMetadataCache.shared`, `@ObservedObject UpdateManager.shared` | General |
| `MicrophoneOptionRow` | `View` | — | строка выбора микрофона |
| `PromptsSettingsView` | `View` | `@EnvironmentObject AppState` | промпты, output language, guard |
| `RunLogView` / `RunLogEntryView` / `PipelineStepView<Content: View>` | `View` | `@EnvironmentObject AppState` (первые два) | история прогонов |
| `AudioPlayerDelegate` | `NSObject, AVAudioPlayerDelegate` | — | проигрывание аудио записи |
| `AudioPlayerView` | `View` | — | плеер аудио |
| `FlowLayout` | `Layout` | — | перенос тегов |
| `VoiceMacrosSettingsView` / `VoiceMacroEditorView` | `View` | `@EnvironmentObject AppState` | макросы |
| `SetupView` | `View` | `@EnvironmentObject AppState`, `@StateObject GitHubMetadataCache.shared`, `@StateObject SetupTestHotkeyHarness`; `init(onComplete: @escaping () -> Void)` | визард |
| `SetupProviderSettingsSheet` | `View` (private) | — | лист настроек провайдера |
| `GitHubRepoInfo` / `GitHubStarRecord` / `GitHubStarUser` / `GitHubContributor` | `Decodable` | — | GitHub-метаданные |
| `GitHubMetadataCache` | `ObservableObject` (class) | — | кэш звёзд/контрибьюторов |
| `HowToRow` / `InlineTranscribingDots` / `OverlayStylePreview` / `OverlayStyleOptionRow` | `View` | — | шаги визарда |
| `ModelDropdownView` | `View` | — | выбор LLM-модели |
| `PipelineDebugPanelView` / `PipelineDebugContentView` | `View` | `@EnvironmentObject AppState` (первый) | debug-панель прогона |
| `DictationShortcutEditor` / `ShortcutRoleSection` | `View` | `@EnvironmentObject AppState` | редактор шорткатов |
| `ShortcutPresetRow` / `ShortcutCaptureRow` | `View` (private) | — | строки пресетов/захвата |
| `RecordingOverlayManager` | class (не ObservableObject) | `RecordingOverlayState` | публичный API ниже |
| `RecordingOverlayState` | `ObservableObject` | — | `@Published phase: OverlayPhase`, `audioLevel: Float`, `recordingTriggerMode: RecordingTriggerMode`, `isCommandMode: Bool`, `updateVersion: String`, `errorMessage: String?`, `toastID: UUID?` |
| `OverlayPhase` | enum | — | `initializing, recording, transcribing, feedback, updateAvailable` |
| `WingedRecordingView` | `View` | `@ObservedObject RecordingOverlayState` | wing-лейаут |
| `RecordingOverlayView` | `View` | `@ObservedObject RecordingOverlayState`; `init(state:onStopButtonPressed:onUpdateOverlayPressed:)` | pill-лейаут |
| `WaveformView` / `CompactWaveformView` | `View` | `let audioLevel: Float`, `var showsActivityPulse: Bool = false` | waveform 9/5 баров |
| `WaveformBar` / `CompactWaveformBar` | `View` | `let amplitude: CGFloat` | бар |
| `ProcessingWaveformView` / `CompactProcessingWaveformView` | `View` | — | анимация обработки |
| `ProcessingIndicatorView` / `CompactProcessingIndicatorView` | `View` | — | waveform → спиннер через 1 c |
| `InitializingDotsView` | `View` | — | 3 точки, таймер 0.5 c |
| `CommandModeIndicator` / `FailureIndicatorView` | `View` | — | pencil / красный X |
| `ErrorOverlayView` | `View` | `let message: String` | тост ошибки |
| `UpdateAvailableOverlayView` | `View` | `let onPress: () -> Void` | кнопка обновления |

`RecordingOverlayManager` (публичный контракт):

```swift
final class RecordingOverlayManager {
    init()
    var onStopButtonPressed: (() -> Void)?
    var onUpdateOverlayPressed: (() -> Void)?
    func showInitializing(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false)
    func showRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false)
    func transitionToRecording(mode: RecordingTriggerMode = .hold, isCommandMode: Bool = false)
    func setRecordingTriggerMode(_ mode: RecordingTriggerMode, animated: Bool)
    func updateAudioLevel(_ level: Float)
    func showTranscribing()
    func showFailureIndicator()
    func showError(_ message: String)          // обрезка 90 + "…", автоскрытие 6 c
    func showUpdateAvailable(version: String)
    func dismiss()
}
```

---

## 10. Инварианты для параллельной сборки

1. Любой модуль, которому нужен AppContext/AppSelectionSnapshot/скриншот-конфиг, берёт их
   из `AppContextService.swift` — дублирование типов запрещено.
2. `SessionIntent`, `TranscriptProcessingOutcome`, `PendingClipboardRestore` и прочие
   pipeline-типы — private в `AppState.swift`; наружу торчат только
   `PipelineHistoryItemIntent` и строки статусов.
3. Протокол `RealtimeTranscriptBackend` — единственная точка стыка AppState↔realtime;
   новые провайдеры реализуют только его.
4. `ShortcutMatcher`, `DictationShortcutSessionController`, `TranscriptionResponseParser`,
   `TranscriptOutputSanitizer`, `ModelConfiguration`, `SemanticVersion`,
   `GeminiTranscription`, `GeminiLiveTranscription`, `LLMCooldownManager`,
   `LiveAudioLevelNormalizer` — детерминированная чистая логика, покрытая тестами из
   `Tests/` (мини-раннер, не XCTest).
5. Порядок аргументов init'ов и имён полей менять нельзя — на них завязаны Codable
   (ShortcutBinding, PipelineHistoryItem, VoiceMacro) и persisted JSON.
6. Все таймауты/задержки/константы — из таблицы 00-architecture §2.1; никаких новых
   «магических чисел».

---

## 11. Чек-лист «что должно получиться в коде по этой спеке»

1. Все типы разделов 2–9 существуют с точными именами, полями и сигнатурами; имена
   Codable-полей (`ShortcutBinding`, `PipelineHistoryItem`, `VoiceMacro`, `GitHubRelease`,
   `SemanticVersion`) совместимы с сохранёнными JSON прежних версий.
2. Каталоги `Sources/` + `Sources/ShortcutCore/` + `Tests/` повторяют §1.2; тестовый
   раннер — `@main OmniFlowTests`, вызывающий `.run()` наборов, без XCTest-зависимости.
3. `AppState` экспонирует ровно публичную поверхность §2.2; приватный конвейер
   (`processTranscript`, `resolveRawTranscript`, `parseTranscriptCommands`,
   `statusMessage`, `formattedTranscriptionError`, `urlErrorCode`) воспроизведён.
4. `public`-модификаторы стоят только в `ModelConfiguration.swift`.
5. `RecordingOverlayManager` имеет ровно API §9; `OverlayPhase` — 5 кейсов из §9.
6. CoreData-схема `PipelineHistoryEntry` (21 атрибут, типы/optionality §7.2) создаётся
   программно, без .xcdatamodeld.
7. Singleton'ы (`NetworkMonitor`, `UpdateManager`, `VocabularyNotificationManager`,
   `LLMCooldownManager`) — `static let shared`, приватные init.
8. `LLMCooldownManager` — actor c `nonisolated static` хелперами (`udKey`,
   `rateLimitCooldown`), формат UserDefaults-ключа `llm_cooldown_expiry_<model>`.
9. `enum PostProcessingError` содержит все 7 кейсов §5.1 с ассоциированными типами.
10. Realtime-пара сервисов и протокол `RealtimeTranscriptBackend` собраны по §4.4–4.7;
    Configuration-структуры — value types с полями из спеки.
