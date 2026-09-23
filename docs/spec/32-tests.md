# 32 — Тесты

Спека тестового слоя. Референс: `Tests/` — **10 файлов**: `TestMain.swift`,
`TestSupport.swift` и **8 сюитов**: `AppContextServiceTests`,
`GeminiLiveTranscriptionTests`, `GeminiTranscriptionTests`,
`LLMCooldownManagerTests`, `ModelConfigurationTests`, `SemanticVersionTests`,
`ShortcutCoreTests`, `TranscriptTextCoreTests`.

Никакого XCTest: свой мини-раннер на `fatalError`. Первое непройденное
ожидание роняет процесс с `file:line` — это и есть «красный» прогон.

---

## 1. Инфраструктура

### 1.1 TestMain.swift — точка входа раннера

```swift
@main
struct OmniFlowTests {
    static func main() {
        AppContextServiceTests.run()
        GeminiLiveTranscriptionTests.run()
        GeminiTranscriptionTests.run()
        ModelConfigurationTests.run()
        ShortcutCoreTests.run()
        SemanticVersionTests.run()
        LLMCooldownManagerTests.run()
        TranscriptTextCoreTests.run()
        print("OmniFlowTests passed")
    }
}
```

Каждый сьют — `enum` со `static func run()`, который вызывает все свои
`private static func test...()` по порядку. Успех всего прогона — строка
`OmniFlowTests passed` в stdout.

### 1.2 TestSupport.swift — ассерты

```swift
enum TestSupport {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line)
    // guard condition else { fatalError("\(file):\(line): \(message)") }

    static func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T,
                                          _ expected: @autoclosure () -> T, ...)
    // expect(actual == expected, "Expected \(expected), got \(actual)")

    static func expectApproximatelyEqual(_ actual: Double, _ expected: Double,
                                         accuracy: Double = 0.000_001, ...)
    // expect(abs(actual - expected) <= accuracy, "Expected \(expected) ± \(accuracy), got \(actual)")
}
```

- `expect` — условие + сообщение; `expectEqual` — сравнение Equatable;
  `expectApproximatelyEqual` — дельта с дефолтом `0.000_001`.
- Все три роняют процесс через `fatalError` с координатами (автокlosures —
  чтобы ленивое вычисление не выполнялось при уже упавшем ранее ассерте).

### 1.3 Правила

- **Никаких живых API и сети**: всё тестируется на синтетических фикстурах —
  строках, `Data`, `HTTPURLResponse`, собранных вручную, JSON-строках.
- Асинхронные и сетевые слои тестируются через чистые, детерминированные
  функции (построители запросов/парсеры/классификаторы), которые подлежат
  извлечению из сервисов (см. спеки 10–23: именно эти чистые функции должны
  существовать в проде, чтобы тесты были возможны).
- Файлы фикстур с пометкой «synthetic» в текстах — намеренная маркировка
  синтетических данных.
- Сьюты компилируются только с подмножеством продакшн-файлов
  (см. `TEST_PRODUCTION_SOURCES` в спеке 33) — тесты не тянут AppKit/SwiftUI-слой.

---

## 2. SemanticVersionTests (spека 31, §2)

`run()` вызывает: `testParsingAndBuildMetadata`, `testCoreVersionOrdering`,
`testOfficialPrereleaseOrdering`, `testInvalidVersionsAreRejected`.

- **testParsingAndBuildMetadata**:
  - `" v1.2.3 "` парсится так же, как `"V1.2.3"` (trim + регистр префикса);
  - `"1.2.3+build.1"` == `"1.2.3+build.2"` (build metadata не влияет на равенство);
  - `1.2.3-alpha < 1.2.3` (prerelease раньше стабильного);
  - `1.2.3-1 < 1.2.3-alpha` (числовой идентификатор раньше буквенного);
  - `1.2.3-alpha < 1.2.3-alpha.1` (более короткий список раньше).
- **testCoreVersionOrdering**: `1.2.3 < 1.2.4`, `1.2.9 < 1.3.0`, `1.9.9 < 2.0.0`.
- **testOfficialPrereleaseOrdering**: строгий порядок цепочки
  `1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2 <
  1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0` (последовательные сравнения соседних).
- **testInvalidVersionsAreRejected**: `SemanticVersion(nil)` для
  `""`, `"1.2"`, `"1.2.3.4"`, `"one.2.3"`, `"1.2.3-"`, `"1.2.3-alpha..1"`.
- Хелпер `version(_:)` — `fatalError`, если валидная строка не распарсилась.

---

## 3. ShortcutCoreTests (спека шорткатов)

`run()` вызывает 13 тестов. Используют чистое ядро: `ShortcutMatcher.reduce(state:event:configuration:)`
→ `(state, emittedEvents, consumeDecision)`, `ShortcutBinding`,
`DictationShortcutSessionController.handle(event:isTranscribing:)`.
События: `.modifierChanged(keyCode:isDown:)`, `.keyChanged(keyCode:isDown:isRepeat:)`,
`.backendReset`. Константы клавиш: 63 = Fn, 61 = Right Option, 58 = Left Option,
55 = Left Command, 54 = Right Command, 56 = Left Shift, 96 = F5.
`.defaultHold` / `.defaultToggle` — дефолтные биндинги конфигурации.

1. **testBareFnHoldLifecycle** — hold = голый Fn (keyCode 63):
   нажатие → `[.holdActivated]` + `.consume`; отпускание → `[.holdDeactivated]` + `.consume`.
2. **testDefaultShortcutSpecificityOrdering** — hold/toggle по умолчанию;
   зажатый Left Command (55) не триггерит; поверх него Fn (63) вниз →
   `[.toggleActivated, .holdActivated]` (toggle специфичнее — перехватывает),
   Fn вверх → `[.holdDeactivated, .toggleDeactivated]`.
3. **testRightOptionPresetIsSideSpecific** — hold = Right Option: Left Option
   (58) не даёт событий; Right Option (61) → `[.holdActivated]`.
4. **testExactModifierMatching** — `ShortcutBinding.exactModifierKeyCodesMatch`:
   generic Command-биндинг (exact [54, 55]) принимает [54] и [55]; [55, 56]
   (лишний Shift) инвалидирует exact [55]; но с
   `permittedAdditionalExactMatchModifiers: [.shift]` — валидно.
5. **testReducerHonorsExactModifierMatching** — F5+Command c exact [55]
   (Left Command): Right Command + F5 → нет событий; Left Command + F5 →
   `[.holdActivated]`; добавленный Shift инвалидирует; конфигурация с
   permitted `.shift` снова пропускает.
6. **testRepeatedKeyDownDoesNotReactivate** — авто-repeat (`isRepeat: true`)
   не даёт нового события, состояние не меняется, решение `.consume`.
7. **testPasteAgainFiresOnLeadingEdgeOnly** — copyAgain-биндинг: первый down →
   `[.copyAgainTriggered]`; repeat → нет; up → нет; второй down → снова триггер.
8. **testBackendResetClearsActiveBindings** — `.backendReset` при активных
   hold+toggle эмитит `[.holdDeactivated, .toggleDeactivated]`, решение
   `.passthrough`, очищает `pressedKeyCodes`, `pressedModifierKeyCodes`,
   `holdIsActive/toggleIsActive`.
9. **testBindingMigrationAndIdentity** — `normalizedForStorageMigration`:
   exact `[999, 61]` → `[61]` и modifiers выводятся `[.option]` (999 не
   валидный модификатор-код, 61 → Option); `id` биндинга не зависит от порядка
   модификаторов и exact-кодов (`[.command,.option]/[55,58]` == `[.option,.command]/[58,55]`).
10. **testConflictDetection** — `conflicts(with:)`: идентичные конфликтуют,
    симметрично; разные primary key — нет; disabled не конфликтует ни с чем.
11. **testHoldSessionControllerLifecycle** — `.holdActivated` при
    `isTranscribing: true` → nil; при false → `.start(.hold)`;
    `.holdDeactivated` → `.stop`; после — `activeMode == nil`.
12. **testToggleSessionControllerLifecycle** — первый `.toggleActivated` →
    `.start(.toggle)`; второй активации → nil (уже активен);
    `.toggleDeactivated` → nil, но `toggleStopArmed == true` (arm на stop);
    следующая активация → `.stop`; `activeMode == nil`.
13. **testHoldToToggleSessionControllerLifecycle** — hold → `.start(.hold)`;
    `.toggleActivated` поверх → `.switchedToToggle`; `.holdDeactivated` → nil
    (режим не гаснет); `activeMode == .toggle`; `.copyAgainTriggered` → nil.
    Плюс ручное API: `beginManual(mode: .hold)` → activeMode .hold;
    `forceToggleMode()` → .toggle; `reset()` → nil и `toggleStopArmed == false`.

---

## 4. TranscriptTextCoreTests (спека транскрипт-ядра)

`run()` вызывает 8 тестов. Чистые функции:
`TranscriptionResponseParser.parse(Data) throws -> String` (ошибка
`TranscriptionResponseParsingError.invalidResponse`) и
`TranscriptOutputSanitizer` (`postProcessedTranscript`, `verbatimTranslation`,
`commandModeTranscript`, `appearsToHaveExecutedInstruction`).

1. **testJSONTranscriptParsing** — `{"text": "Synthetic transcript."}` →
   текст; `{"text": ""}` → `""`.
2. **testNonTranscriptJSONFallsBackToUTF8** — не-транскриптный JSON
   (`{"synthetic": "fallback"}`) возвращается как UTF8-строка тела
   (re-serialized: `"{   \"synthetic\": \"fallback\" }"` — с отступами исходника).
3. **testInvalidTranscriptResponses** — `invalidResponse` для: пустой Data;
   whitespace-only (`" \n\t "`); битый JSON (`"{malformed synthetic JSON"`);
   невалидный UTF-8 (`[0xFF, 0xFE]`). Неверный тип ошибки — провал.
4. **testHighConfidenceHallucinationsAreSuppressed** — подавление
   галлюцинаций Whisper по `no_speech_prob`: `{"text": "Thank you.",
   "segments":[{"no_speech_prob": 0.1}]}` → `""` (порог ≥ 0.1);
   `"  THANK YOU FOR WATCHING!!!  "` с prob 0.9 → `""` (нормализованная
   фраза-галлюцинация).
5. **testPossibleRealSpeechIsPreserved** — prob 0.099 → текст сохраняется
   (`0.099 < порога`); сегменты без `no_speech_prob` или без сегментов —
   сохраняется; речь, не входящая в словарь галлюцинаций
   (`"Synthetic project update."`, prob 0.95) — сохраняется.
6. **testPostProcessedTranscriptSanitization** —
   `postProcessedTranscript`: trim внешних пробелов и парных обрамляющих
   кавычек (`"  \"Synthetic output.\" \n"` → `Synthetic output.`);
   `EMPTY`/`"EMPTY"` (регистр/кавычки) → `""`; `empty` (не спец-слово) →
   `empty`; whitespace → `""`.
7. **testModeSpecificSanitization** — `verbatimTranslation` сохраняет
   литеральное `EMPTY` и снимает только обрамляющие кавычки/пробелы;
   `commandModeTranscript` сохраняет внутренние кавычки
   (`"Keep command quotes"` с кавычками).
8. **testInstructionExecutionGuard** —
   `appearsToHaveExecutedInstruction(rawTranscript:cleanedTranscript:outputLanguage:)`:
   - «Write an email…» → «Sure, here's a draft: …» — **true** (ассистент-стиль);
   - «Write a haiku…» → стих с малым пересечением — **true** (low-overlap);
   - идентичный текст — **false** (честная очистка);
   - «Sure, the synthetic launch is Friday.» без инструкции — **false**;
   - запрос «Translate…» с outputLanguage `Italian` и иноязычным выводом —
     **false** (явный перевод обходит guard).

---

## 5. ModelConfigurationTests (спека моделей)

`run()` вызывает 4 теста. Функции: `ModelConfiguration.config(for:)` →
`ModelConfig { maxCompletionTokens, reasoningEffort, includeReasoning,
shouldStripThinkTags }`, списки `llmModels/visionModels/transcriptionModels`,
`stripThinkTags(_:)`.

1. **testProviderlessAliasesMatchCanonicalModels** — алиасы без провайдера
   нормализуются (trim + lowercase) к канону, конфиги идентичны по всем 4
   полям: `" GPT-OSS-20B "` ≡ `openai/gpt-oss-20b`; `gpt-oss-120b` ≡
   `openai/gpt-oss-120b`; `gpt-oss-safeguard-20b` ≡
   `openai/gpt-oss-safeguard-20b`; `qwen3-32b` ≡ `qwen/qwen3-32b`;
   `" QWEN3.6-27B "` ≡ `qwen/qwen3.6-27b`.
2. **testKnownModelSettingsRemainStable** — стабильные конфиги:
   - `openai/gpt-oss-20b`: maxCompletionTokens 4096, reasoningEffort `"low"`,
     includeReasoning false, shouldStripThinkTags false;
   - `qwen/qwen3.6-27b`: reasoningEffort `"none"`, includeReasoning false,
     shouldStripThinkTags **true**;
   - неизвестная модель (`example/unknown-model`): все nil, кроме
     shouldStripThinkTags = false.
3. **testModelListsAreConsistent** — списки без дубликатов
   (`Set == count` для llm/vision/transcription);
   `visionModels` — подмножество `llmModels`.
4. **testThinkTagStripping** — `stripThinkTags`:
   `"<think>hidden</think> Visible output"` → `"Visible output"`;
   два блока think → остаётся хвост; незакрытый `<think>unfinished` → `""`;
   текст с «ложным» маркером без открывающего тега не меняется.

---

## 6. AppContextServiceTests (спека контекст-сервиса)

`run()` вызывает 5 тестов. Функции:
`AppContextService.activitySummary(from:model:)` — суммаризация вывода
context-модели; `ModelConfiguration` (пересечение со спекой 5).

1. **testQwenRawOutputIsSummarized** — для `qwen/qwen3.6-27b` берутся первые
   **два предложения** из ответа («…launch. …steps.»), третье отбрасывается.
2. **testQwenReasoningOutputIsStripped** — блок `<think>…</think>` вырезается
   целиком (включая переносы), остаётся чистый summary; вхождение
   «Hidden chain of thought» в результате запрещено.
3. **testNonStrippingModelPreservesExistingBehavior** — для не-Qwen модели
   (`meta-llama/llama-4-scout-17b-16e-instruct`) вывод возвращается **как есть**
   (think-блок не режется, предложения не усекаются).
4. **testDeprecatedGroqModelsAreNotPredefined** — из `llmModels` удалены
   `qwen/qwen3-32b`, `meta-llama/llama-4-scout-17b-16e-instruct`,
   `llama-3.1-8b-instant`, `llama-3.3-70b-versatile`; новый фолбэк
   `qwen/qwen3.6-27b` присутствует.
5. **testQwenCleanupDisablesReasoning** — `config(for: "qwen/qwen3.6-27b")`:
   `reasoningEffort == "none"`, `includeReasoning == false`.

---

## 7. GeminiTranscriptionTests (спека Gemini batch)

`run()` вызывает 6 тестов. Чистые функции `GeminiTranscription`:
`handlesModel(_:)`, `resolvedBaseURL(from:)`, `endpoint(baseURL:)`,
`requestBody(model:audioData:mimeType:customVocabulary:)`, `vocabularyTerms(from:)`,
`transcript(fromResponse:) throws`, `failureMessage(fromResponse:fallback:)`,
константа `defaultBaseURL`.

1. **testOnlyInteractionsCapableModelsAreRouted** — `gemini-3.5-transcribe`
   роутится (в т.ч. `" GEMINI-3.5-TRANSCRIBE "` — trim+case); НЕ роутятся:
   `gemini-3.5-transcribe-live`, `whisper-large-v3`, `gemini-3.5-flash`.
2. **testGroqProviderURLIsReplacedWithGoogleHost** — Groq-URL и пустая строка
   подменяются на `defaultBaseURL`; явный Google-URL сохраняется;
   `endpoint` = `<base>/interactions`.
3. **testRequestAsksForSmartModeWithInlineAudio** — тело запроса:
   `model`; `input` — ровно один элемент `{type: "audio", mime_type: "audio/wav",
   data: <base64>}`; `generation_config.transcription_config.mode.type == "smart"`;
   `custom_vocabulary == ["OmniFlow", "Groq"]`; `language_codes` отсутствует
   (пиннинг языка ломает smart mode); отсутствуют `timestamp_granularities` и
   `diarization_mode` (smart их не принимает).
4. **testVocabularyIsSplitDeduplicatedAndCapped** —
   `"Kubernetes\nBigQuery; Groq , Groq"` → `["Kubernetes", "BigQuery", "Groq"]`
   (разделители `,\n;` и пробелы, дедуп); мусорная строка → `[]`;
   1200 терминов → ровно **1000** (кап); пустой словарь в теле запроса
   **опускается**, а не шлётся пустым списком.
5. **testTranscriptIsReadFromModelOutput** — парсер ответа Interactions API:
   `steps[type=model_output].content[].text`, trim → `"Hello there."`;
   пустой/пробельный текст → **throw**; `status != "completed"` → throw;
   не-JSON → throw (хелпер `expectThrows`).
6. **testFailuresSurfaceGoogleMessage** — `failureMessage`:
   `{"error":{...,"message":"You exceeded your current quota."}}` → сообщение
   Google; не-JSON → fallback (`"HTTP 500"`); ошибки, завёрнутые в **массив**
   (`[{error:…}]` — формат auth-ошибок), тоже распознаются; error-тело при
   HTTP 200 не парсится как транскрипт (throw).

---

## 8. GeminiLiveTranscriptionTests (спека Gemini live)

`run()` вызывает 5 тестов. Чистые функции `GeminiLiveTranscription`:
`handlesModel(_:)`, `socketURL(baseURL:)`, `setupMessage(model:customVocabulary:)`,
`audioMessage(pcm16:sampleRate:)`, `audioStreamEndMessage()`,
`parseServerFrame(_:)` → `ServerFrame {transcript, isComplete, isSetupComplete, errorMessage}`.

1. **testOnlyLiveModelsAreRouted** — live-модель роутится (в т.ч. с пробелами
   и верхним регистром); batch-модель и чужие провайдеры — нет; для трёх
   моделей (`gemini-3.5-transcribe`, `gemini-3.5-transcribe-live`,
   `whisper-large-v3`) два роутера **не пересекаются** (не более одного claims).
2. **testSocketURLIsDerivedFromAnyGeminiBase** — ожидаемый сокет:
   `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`;
   https-база `/v1beta` → wss + service path; **пустая база** и даже
   Groq-база дают тот же URL (fallback); query-параметры базы (например
   `?key=secret`) отбрасываются — секрет не протекает.
3. **testSetupAsksForSmartModeAndVocabulary** — setup-фрейм:
   `setup.model == "models/gemini-3.5-transcribe-live"` (namespacing models/);
   `generationConfig.responseModalities == ["TEXT"]`;
   `inputAudioTranscription.mode == "SMART"` (верхний регистр, в отличие от
   batch-API); `custom_vocabulary` — дедуплицированный `["OmniFlow", "Groq"]`;
   `language_codes` нет (авто-детект); пустой словарь опускается;
   модель с префиксом `models/` не дублируется.
4. **testAudioFramesDeclareTheRealSampleRate** — `realtimeInput.audio`:
   `mimeType == "audio/pcm;rate=24000"` (рекордер шлёт 24 кГц — фрейм обязан
   сказать 24k, а не документированные 16k); `data` = base64 PCM;
   `audioStreamEndMessage` → `realtimeInput.audioStreamEnd == true`.
5. **testServerFramesAreClassified** — парсер серверных фреймов:
   `serverContent.inputTranscription.text` → transcript (не complete);
   `serverContent.turnComplete:true` и `generationComplete:true` → complete;
   `setupComplete` → `isSetupComplete`, но не complete;
   `error.message` → errorMessage и complete (ошибка заканчивает ход);
   мусор (`"not json"`) → ничего не выставлен, не падает.

---

## 9. LLMCooldownManagerTests (спека cooldown)

`run()` вызывает 4 теста. Чистая статическая функция
`LLMCooldownManager.rateLimitCooldown(from: HTTPURLResponse) -> (seconds: TimeInterval, isDaily: Bool)`;
фикстура — `HTTPURLResponse(url: groq-chat-completions, statusCode: 429, headerFields:)`.

1. **testDailyQuotaTakesPriority** — при `x-ratelimit-remaining-requests: 0`
   приоритет у окна requests: headers
   `{"x-ratelimit-remaining-requests": "0", "x-ratelimit-reset-requests": "2m59.56s",
   "retry-after": "2"}` → seconds **179.56**, isDaily **true**
   (это признак дневного лимита Groq);
   при `remaining-requests: 1` — берётся `retry-after` (`7.66`, isDaily false).
2. **testRetryAndTokenDurations** — парсинг durations: `"120ms"` → 0.12;
   `"1h2m3.5s"` → 3723.5; `x-ratelimit-reset-tokens: "8.25s"` → 8.25.
3. **testMalformedDurationsUseSafeFallback** — невалидные значения
   `"-3"`, `"nan"`, `"inf"`, `"1d"`, `"1h30"`, `""` → безопасный дефолт
   **60 c**, isDaily false.
4. **testPersistenceKeyIsStable** — `LLMCooldownManager.udKey(for: "openai/gpt-oss-20b")`
   == `"llm_cooldown_expiry_openai/gpt-oss-20b"` (ключ, по которому
   SettingsView читает expiry напрямую).

---

## 10. Матрица «сьют → продакшн-файл»

| Сьют | Тестирует (продакшн) | Спека |
|---|---|---|
| `SemanticVersionTests` | `Sources/UpdateManager.swift` (SemanticVersion) | 31 |
| `ShortcutCoreTests` | `Sources/ShortcutCore/` (ShortcutMatcher, ShortcutModels, DictationShortcutSessionController, ShortcutBinding) | 2x (шорткаты) |
| `TranscriptTextCoreTests` | `Sources/TranscriptTextCore.swift` | 2x |
| `ModelConfigurationTests` | `Sources/ModelConfiguration.swift` | 2x |
| `AppContextServiceTests` | `Sources/AppContextService.swift` (+ModelConfiguration) | 2x |
| `GeminiTranscriptionTests` | `Sources/GeminiTranscription.swift` | 2x |
| `GeminiLiveTranscriptionTests` | `Sources/GeminiLiveTranscription.swift` | 2x |
| `LLMCooldownManagerTests` | `Sources/LLMCooldownManager.swift` | 2x |

---

## Чек-лист реализации тестов

- [ ] TestMain `@main` вызывает 8 сьютов в фиксированном порядке, печатает `OmniFlowTests passed`
- [ ] TestSupport: expect / expectEqual / expectApproximatelyEqual (accuracy 1e-6) на fatalError c #filePath/#line
- [ ] Каждый сьют — enum со static run() и приватными test-функциями
- [ ] SemanticVersion: 4 теста §2, включая каноническую цепочку prerelease
- [ ] ShortcutCore: 13 тестов §3 — lifecycle bare-Fn, specificity, side-specific Right Option, exact-modifier (прямые + через reducer), repeat-guard, copyAgain leading edge, backendReset, миграция/id, конфликты, 3 lifecycle контроллера
- [ ] TranscriptTextCore: 8 тестов §4 — парсер JSON/fallback/invalid, подавление галлюцинаций по no_speech_prob, санитайзеры трёх режимов, instruction guard (5 кейсов)
- [ ] ModelConfiguration: алиасы, стабильные конфиги (4096/low/none), целостность списков, stripThinkTags
- [ ] AppContextService: summary = первые 2 предложения для Qwen, strip <think>, no-op для не-Qwen, отсутствие deprecated моделей, reasoning off
- [ ] GeminiTranscription: роутинг, подмена Groq-URL, smart-mode тело, словарь (дедуп/кап 1000/omit пустого), парсер transcript, failureMessage с массив-обёрткой
- [ ] GeminiLive: роутинг без пересечений, socketURL fallback + drop query, setup-фрейм (models/, SMART, vocabulary), 24 kHz mime, классификация серверных фреймов + junk
- [ ] LLMCooldownManager: дневной лимит приоритетен (179.56/true), durations, fallback 60 c, стабильный udKey
- [ ] Тесты без сети и без AppKit-зависимостей; компоновка только с TEST_PRODUCTION_SOURCES (спека 33)
