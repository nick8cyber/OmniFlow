# Спецификация 10 — Транскрипция: провайдеры, протоколы, роутинг

Референс: FreeFlow / OmniFlow, `Sources/TranscriptionService.swift`, `Sources/RealtimeTranscriptionService.swift`, `Sources/RealtimeTranscriptBackend.swift`, `Sources/GeminiTranscription.swift`, `Sources/GeminiLiveTranscription.swift`, `Sources/GeminiLiveTranscriptionService.swift`, `Sources/AppState.swift` (роутинг), `Sources/AudioRecorder.swift` (форматы аудио).

Все сетевые вызовы транскрипции идут через `LLMAPITransport` (см. `11-postprocessing.md`, раздел «LLMAPITransport»): ephemeral `URLSession` на каждый запрос, кэш выключен, таймауты синхронизированы с `URLRequest.timeoutInterval`.

---

## 1. Общая картина

Три транспорта транскрипции:

| Транспорт | Модели | Протокол |
|---|---|---|
| Батч OpenAI-совместимый (Groq/OpenAI) | `whisper-large-v3`, `whisper-large-v3-turbo`, `whisper-1`, любые не-Gemini | `POST {base}/audio/transcriptions`, multipart |
| Батч Gemini (Interactions API) | `gemini-*-transcribe*`, кроме `*-live` | `POST {base}/interactions`, JSON с inline base64-аудио |
| OpenAI Realtime WebSocket | модель из настройки `realtime_streaming_model` | WebSocket `wss://.../v1/realtime?intent=transcription` |
| Gemini Live WebSocket | `gemini-*-transcribe-live` | WebSocket BidiGenerateContent |

Аудио от `AudioRecorder`:
- **Файл для батч-загрузки**: нормализованный WAV, PCM16 mono, 16 000 Гц (`recordingTargetFormat`).
- **Realtime-поток**: PCM16 mono, **24 000 Гц** — `AudioRecorder.realtimeSampleRate = 24_000` (константа). Колбэк `onPCM16Samples: ((Data) -> Void)?` отдаёт чанки 16-bit little-endian PCM; внутри чанков объявленный sample rate — 24 кГц.

---

## 2. Протокол `RealtimeTranscriptBackend`

Файл `Sources/RealtimeTranscriptBackend.swift`. Точная сигнатура:

```swift
protocol RealtimeTranscriptBackend: AnyObject {
    /// Partial transcript updates, delivered on the main queue.
    var onPartialUpdate: ((String) -> Void)? { get set }

    func start() throws
    func appendPCM16(_ data: Data)
    func commitAndAwaitFinal() async throws -> String
    func cancel()
}
```

Семантика контракта:
- `start()` — открыть сокет, выполнить рукопожатие/настройку сессии. Бросает синхронную ошибку (например, невалидный базовый URL).
- `appendPCM16(_:)` — отправить чанк 16-bit LE PCM. Вызывающий (AppState) подписывает `audioRecorder.onPCM16Samples` на это. Реализация обязана молча игнорировать вызов после `cancel()` и пустые данные.
- `commitAndAwaitFinal()` — сигнал конца диктовки; suspend до финального транскрипта. Бросает `CancellationError` при отмене, `serverError` при ошибке сервера, `closedBeforeFinal` если сокет закрылся без финала.
- `cancel()` — закрыть сокет и оборвать ожидание. Должен быть идемпотентным («safe to call multiple times»).
- `onPartialUpdate` — промежуточный текст, доставляется на main queue.

Две реализации: `RealtimeTranscriptionService` (OpenAI-совместимый realtime) и `GeminiLiveTranscriptionService` (Gemini Live API).

Общие типы ошибок (объявлены в `RealtimeTranscriptionService.swift`, используются обеими реализациями):

```swift
enum RealtimeTranscriptionError: LocalizedError {
    case invalidBaseURL(String)                       // "Cannot derive a WebSocket URL from \(url)"
    case notConnected                                 // "Realtime transcription socket is not connected"
    case serverError(code: String, message: String)   // "Realtime server error [\(code)]: \(message)"
    case closedBeforeFinal                            // "Realtime socket closed before emitting the final transcript"
}
```

---

## 3. `TranscriptionService` — батч OpenAI/Groq

### 3.1. Инициализация и нормализация

```swift
init(
    apiKey: String,
    baseURL: String = "https://api.groq.com/openai/v1",
    transcriptionModel: String = "whisper-large-v3",
    language: String? = nil,
    customVocabulary: String = ""
) throws
```

Правила инициализации:
1. Модель: trim whitespace/newlines; пустая → `"whisper-large-v3"`.
2. Если `GeminiTranscription.handlesModel(model)` → базовый URL заменяется: `GeminiTranscription.resolvedBaseURL(from: baseURL)` (см. раздел 4.2). Иначе используется как есть. Это сознательная подмена: существующие инсталляции хранят Groq URL, Gemini-хост подставляется без ручного перебивания настройки.
3. `normalizedBaseURL(from:)` для итогового URL:
   - trim; пусто → `TranscriptionError.invalidBaseURL("Provider URL is empty.")`;
   - неразбирается как `URLComponents` → `"Provider URL is malformed."`;
   - scheme (lowercased) должен быть `http` или `https`, иначе `"Provider URL must use http or https."`;
   - host пуст → `"Provider URL must include a host."`;
   - path `"/"` заменяется на `""`; иначе у path срезаются хвостовые слэши регуляркой `"/+$"`.
4. `language`: trim; пустая строка → `nil`.
5. `customVocabulary` сохраняется как есть (используется только Gemini-путём).

### 3.2. Таймаут

```swift
private var transcriptionTimeoutSeconds: TimeInterval {
    let override = UserDefaults.standard.double(forKey: "transcription_timeout_seconds")
    return override > 0 ? override : 20
}
```
Дефолт — 20 секунд; override ключом `transcription_timeout_seconds` (только если > 0).

### 3.3. Гонка с таймаутом (`transcribe(fileURL:)`)

`transcribe(fileURL:)` оборачивает загрузку в `withTaskCancellationHandler` + `withCheckedThrowingContinuation` + класс `TranscriptionTimeoutRaceState` (NSLock + флаг `didFinish`):
- Запускаются две `Task`: загрузка (`transcribeAudio(fileURL:)`) и таймер `Task.sleep(timeoutSeconds)`.
- Кто первый вызвал `finish(_:)` — тот резюмит continuation; вторая задача отменяется.
- Отмена внешней задачи → `finish(.failure(CancellationError()))`.
- Если загрузка упала с `URLError.code == .timedOut`, ошибка переписывается в `TranscriptionError.transcriptionTimedOut(timeoutSeconds)`.

### 3.4. Роутинг внутри батча

```swift
private func transcribeAudio(fileURL: URL) async throws -> String {
    if GeminiTranscription.handlesModel(transcriptionModel) {
        return try await transcribeWithGemini(fileURL: fileURL)
    }
    return try await transcribeAudioWithURLSession(fileURL: fileURL)
}
```

### 3.5. Multipart-запрос (OpenAI/Groq)

- URL: `baseURL + "audio" + "transcriptions"` (`appendingPathComponent` дважды).
- Метод `POST`, `timeoutInterval = transcriptionTimeoutSeconds`.
- Заголовки:
  - `Authorization: Bearer {apiKey}`
  - `Content-Type: multipart/form-data; boundary={boundary}`, где `boundary = UUID().uuidString`.
- Тело строится `makeMultipartBody`. **Точный порядок частей** (каждая часть отделяется `--{boundary}\r\n`, значение заканчивается `\r\n`):

```
--{boundary}\r\n
Content-Disposition: form-data; name="model"\r\n
\r\n
{model}\r\n
--{boundary}\r\n
Content-Disposition: form-data; name="response_format"\r\n
\r\n
{responseFormat}\r\n
(опционально, только если language != nil && !language.isEmpty:)
--{boundary}\r\n
Content-Disposition: form-data; name="language"\r\n
\r\n
{language}\r\n
--{boundary}\r\n
Content-Disposition: form-data; name="file"; filename="{fileName}"\r\n
Content-Type: {audioContentType}\r\n
\r\n
{audioData — сырые байты}\r\n
--{boundary}--\r\n
```

- `fileName` = `fileURL.lastPathComponent`; `audioData` = `Data(contentsOf: fileURL)`.
- `customVocabulary` в multipart НЕ отправляется (это только Gemini/пост-обработка).

**Content-Type по расширению** (`audioContentType(for:)`):

| Расширение (lowercased) | Content-Type |
|---|---|
| `.wav` | `audio/wav` |
| `.mp3` | `audio/mpeg` |
| `.m4a` | `audio/mp4` |
| всё остальное | `audio/mp4` (дефолт) |

**Правило `response_format`** (`static func responseFormat(forModel:)`):

```swift
private static let modelsSupportingVerboseJSON: Set<String> = [
    "whisper-1",
    "whisper-large-v3",
    "whisper-large-v3-turbo"
]
```
Модель trim + lowercased; если входит в множество → `"verbose_json"`, иначе `"json"`. Обоснование: семейство `gpt-4o-transcribe` поддерживает только plain JSON; verbose_json нужен ради `segments[].no_speech_prob` для фильтра галлюцинаций.

### 3.6. Обработка ответа

- Ответ не `HTTPURLResponse` → `TranscriptionError.submissionFailed("No response from server")`.
- Статус != 200 → логируется тело ответа, бросается `TranscriptionError.submissionFailed(friendlyHTTPMessage(status:host:))` (см. 3.8).
- Статус 200 → `TranscriptionResponseParser.parse(data)` (см. `12-models-parsing.md`). Ошибка `TranscriptionResponseParsingError.invalidResponse` пробрасывается как `TranscriptionError.pollFailed("Invalid response")`.

### 3.7. Валидация ключа

```swift
static func validateAPIKey(_ key: String, baseURL: String = "https://api.groq.com/openai/v1") async -> Bool
```
- trim ключа; пустой → `false`.
- `GET {normalizedBaseURL}/models`, `request.timeoutInterval = 10` (ровно 10 секунд), заголовок `Authorization: Bearer {key}`.
- Результат: HTTP 200 → `true`; любой другой статус или ошибка сети → `false`.

### 3.8. `friendlyHTTPMessage(status:host:)` — дословно

```swift
static func friendlyHTTPMessage(status: Int, host: String?) -> String {
    let provider = host ?? "the provider"
    switch status {
    case 401:
        return "Invalid API key for \(provider). Open Settings to fix it."
    case 403:
        return "Key lacks permission for this endpoint at \(provider) (HTTP 403). Check the key's scopes."
    case 404:
        return "Endpoint not found at \(provider) (HTTP 404). Base URL is likely wrong for this provider."
    case 413:
        return "Audio file too large for \(provider) (HTTP 413). Try a shorter recording."
    case 400:
        return "Provider rejected the request (HTTP 400). Check your model name and Base URL in Settings."
    case 429:
        return "Rate limit reached at \(provider) (HTTP 429). Wait a moment and try again."
    case 500..<600:
        return "Provider error at \(provider) (HTTP \(status)). Try again in a moment."
    default:
        return "Request failed at \(provider) (HTTP \(status))."
    }
}
```

### 3.9. `TranscriptionError` — полный список кейсов

```swift
enum TranscriptionError: LocalizedError {
    case invalidBaseURL(String)              // "Invalid provider URL: \(msg)"
    case uploadFailed(String)                // "Upload failed: \(msg)"
    case submissionFailed(String)            // "Submission failed: \(msg)"
    case transcriptionFailed(String)         // "Transcription failed: \(msg)"
    case transcriptionTimedOut(TimeInterval) // "Transcription timed out after \(Int(seconds))s"
    case pollFailed(String)                  // "Polling failed: \(msg)"
    case audioPreparationFailed(String)      // "Audio preparation failed: \(msg)"
}
```

---

## 4. Батч Gemini — Interactions API (`GeminiTranscription`)

enum-namespace без состояния. Основание: Gemini Transcribe не говорит на OpenAI-протоколе `/audio/transcriptions`; Interactions API аутентифицируется `x-goog-api-key`, аудио — inline base64. Smart mode встраивает очистку (fillers, пунктуация) в саму транскрипцию: один запрос вместо двух (Whisper + cleanup).

### 4.1. Константы

```swift
static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"
private static let smartMode = "smart"                  // нижний регистр!
private static let customVocabularyLimit = 1000
```

### 4.2. Роутинг `handlesModel(_:)`

```swift
static func handlesModel(_ model: String) -> Bool {
    let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.hasPrefix("gemini-"), normalized.contains("transcribe") else { return false }
    return !normalized.hasSuffix("-live")
}
```
То есть: `gemini-3.5-transcribe` → true; `gemini-3.5-transcribe-live` → false (live идёт в сокет, раздел 6); `whisper-large-v3` → false.

### 4.3. Подмена не-Google хоста `resolvedBaseURL(from:)`

```swift
static func resolvedBaseURL(from configuredBaseURL: String) -> String {
    let trimmed = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let host = URLComponents(string: trimmed)?.host?.lowercased() else {
        return defaultBaseURL
    }
    let isGoogleHost = host == "generativelanguage.googleapis.com"
        || host.hasSuffix(".googleapis.com")
    return isGoogleHost ? trimmed : defaultBaseURL
}
```
Явно настроенный Google-хост сохраняется (вместе с path), любой другой хост (типично — Groq из дефолтных настроек) заменяется на `defaultBaseURL`. Неразбираемая строка → `defaultBaseURL`.

### 4.4. Endpoint

```swift
static func endpoint(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("interactions")
}
// https://generativelanguage.googleapis.com/v1beta/interactions
```

### 4.5. Тело запроса

Провайдерские структуры и их `CodingKeys` (snake_case в проводе):

| struct | Ключ в JSON |
|---|---|
| `InteractionRequest { model, input, generationConfig }` | `model`, `input`, `generation_config` |
| `AudioInput { type, data, mimeType }` | `type`, `data`, `mime_type` |
| `GenerationConfig { transcriptionConfig }` | `transcription_config` |
| `TranscriptionConfig { mode, customVocabulary }` | `mode`, `custom_vocabulary` |
| `Mode { type }` | `type` |

`requestBody(model:audioData:mimeType:customVocabulary:)` строит дословно такой JSON (`JSONEncoder`):

```json
{
  "model": "gemini-3.5-transcribe",
  "input": [
    {
      "type": "audio",
      "data": "<base64 аудио>",
      "mime_type": "audio/wav"
    }
  ],
  "generation_config": {
    "transcription_config": {
      "mode": {
        "type": "smart"
      },
      "custom_vocabulary": ["Kubernetes", "OmniFlow"]
    }
  }
}
```

Жёсткие правила:
- `custom_vocabulary` — массив строк `vocabularyTerms(from:)`; **если список пуст — поле не отправляется вообще** (`nil` → ключ отсутствует в JSON).
- **`language_codes` НЕ передаются никогда.** Язык — всегда автодетект: пиннинг языка наблюдался как фактор, возвращающий smart mode к verbatim-выводу (отменяет очистку). Комментарий в коде фиксирует это как сознательное решение.

### 4.6. `customVocabulary` — разбор и лимит

```swift
static func vocabularyTerms(from rawVocabulary: String) -> [String] {
    let terms = rawVocabulary
        .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    var seen = Set<String>()
    let deduplicated = terms.filter { seen.insert($0.lowercased()).inserted }
    return Array(deduplicated.prefix(customVocabularyLimit))
}
```
- Разделители: перевод строки, запятая, точка с запятой.
- Trim каждого терма, пустые выбрасываются.
- Дедупликация **по нижнему регистру** (первое написание сохраняется).
- Лимит **1000** терминов: берутся первые (`prefix(1000)`), остальные отбрасываются — вместо того чтобы валить весь запрос.
- Эта же функция переиспользуется Gemini Live (`setupMessage`) — оба этапа биасятся на идентичный список.

### 4.7. HTTP-вызов (`TranscriptionService.transcribeWithGemini`)

- `POST GeminiTranscription.endpoint(baseURL:)`, `timeoutInterval = transcriptionTimeoutSeconds`.
- Заголовки: `x-goog-api-key: {apiKey}` (НЕ Bearer), `Content-Type: application/json`.
- Тело — `requestBody(...)` c base64 файла и `mimeType = audioContentType(for: fileURL.lastPathComponent)` (та же таблица, что в 3.5).
- Вызов `LLMAPITransport.upload(for:from:)`.
- Ответ не HTTPURLResponse → `submissionFailed("No response from server")`.
- Статус != 200 → лог тела → `submissionFailed(GeminiTranscription.failureMessage(fromResponse: data, fallback: friendlyHTTPMessage(status:host:)))`.
- Статус 200 → `GeminiTranscription.transcript(fromResponse: data)`.
- Прочие ошибки пробрасываются как есть (после лога domain/code/description).

### 4.8. Парсинг ответа `transcript(fromResponse:)`

Структуры декодирования: `InteractionResponse { status: String?, steps: [Step]? }`; `Step { type: String?, content: [Content]? }`; `Content { text: String? }`.

Алгоритм (порядок критичен):
1. **Проверка error-конверта до парсинга текста** — ошибки приходят с HTTP 200 в некоторых случаях:
   - Форма 1 — bare object (параметр/квота/биллинг): `{"error": {"message": "..."}}`;
   - Форма 2 — массив (auth-ошибки): `[{"error": {"message": "..."}}]` — берётся первый непустой `message`.
   - Есть сообщение → `throw TranscriptionError.transcriptionFailed(message)`.
2. Декодировать `InteractionResponse`; неудача → `transcriptionFailed("Unreadable Gemini transcription response.")`.
3. `status` присутствует и != `"completed"` → `transcriptionFailed("Gemini transcription \(status).")`.
4. Транскрипт: `(steps ?? []).filter { $0.type == nil || $0.type == "model_output" }.flatMap { $0.content ?? [] }.compactMap { $0.text }.joined()` → trim whitespace.
5. Пустой результат → `transcriptionFailed("Gemini returned an empty transcript.")`. Иначе вернуть.

Пример успешного ответа:

```json
{
  "status": "completed",
  "steps": [
    {
      "type": "model_output",
      "content": [{ "text": "Отредактированный чистый текст." }]
    }
  ]
}
```

`failureMessage(fromResponse:fallback:)` = сообщение из error-конверта, если непустое, иначе fallback (`friendlyHTTPMessage`).

---

## 5. OpenAI Realtime WebSocket (`RealtimeTranscriptionService`)

`final class RealtimeTranscriptionService: RealtimeTranscriptBackend`, `URLSessionWebSocketTask` поверх `URLSession.shared`.

### 5.1. Конфигурация

```swift
struct Configuration {
    let baseURL: String
    let apiKey: String
    let model: String
    let language: String?
}
```

### 5.2. Деривация URL `deriveWebSocketURL(baseURL:model:language:)`

```swift
static func deriveWebSocketURL(baseURL: String, model: String, language: String?) -> URL?
```
(`model`/`language` в деривации не участвуют — параметры оставлены для симметрии сигнатуры.)

1. trim; `URLComponents`; неразбираемо → `nil`.
2. Scheme: `http` → `ws`, `https` → `wss`, `ws`/`wss` — без изменений, остальное → `nil`.
3. Path: убрать один хвостовой `/`; если path заканчивается на `/v1` → добавить `/realtime`; иначе добавить `/v1/realtime`.
4. Query: если нет параметра `intent` → добавить `intent=transcription`.

Примеры:
- `https://api.openai.com/v1` → `wss://api.openai.com/v1/realtime?intent=transcription`
- `https://api.openai.com` → `wss://api.openai.com/v1/realtime?intent=transcription`
- `http://host/x` → `ws://host/x/v1/realtime?intent=transcription`

`start()` бросает `RealtimeTranscriptionError.invalidBaseURL(config.baseURL)`, если деривация вернула `nil`.

### 5.3. Подключение и `session.update`

`start()`:
1. `URLRequest(url: wsURL)`; если `apiKey` непустой — заголовок `Authorization: Bearer {apiKey}`.
2. `session.webSocketTask(with:)`, `task.resume()`, старт receive-loop.
3. Сразу отправить `session.update` (см. ниже).

Точное JSON-сообщение `session.update` (порядок ключей в `JSONSerialization` не гарантирован, структура — да):

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": {
          "type": "audio/pcm",
          "rate": 24000
        },
        "transcription": {
          "model": "{model}",
          "language": "{language}"
        },
        "turn_detection": null
      }
    }
  }
}
```

- `transcription` — словарь, собираемый динамически: `model` добавляется только если trim модели непуст; `language` — только если `language != nil && !language.isEmpty`.
- `turn_detection` — всегда `NSNull()` (ручной режим: сервер не делает VAD-коммит сам).

### 5.4. Поток аудио

`appendPCM16(_ data: Data)` — игнорирует пустые данные; иначе:

```json
{ "type": "input_audio_buffer.append", "audio": "<base64 PCM16 LE>" }
```

Частота согласуется вызывающим: в `session.update` объявлено 24 kHz mono — совпадает с `AudioRecorder.realtimeSampleRate`.

### 5.5. Коммит и ожидание финала

`commitAndAwaitFinal()`:
1. Нет task → `RealtimeTranscriptionError.notConnected`.
2. Под локом: если `commitSent` уже true — повторный коммит НЕ отправляется; иначе `commitSent = true`, `commitEventCount = serverEventCount`, `postCommitCompleted = false`, и отправляется:

```json
{ "type": "input_audio_buffer.commit" }
```

3. Suspension point (`withCheckedThrowingContinuation`). Немедленные исходы (без ожидания):
   - `terminalError` установлен → resume failure с ним;
   - `closed` → resume failure `closedBeforeFinal`;
   - `readyCommittedTranscriptLocked()` вернула текст → `closed = true`, resume success, сокет закрывается `.normalClosure`.

**Финал-детекция через счётчики** — `readyCommittedTranscriptLocked()` (все проверки под локом):

```swift
guard commitSent, partialText.isEmpty, postCommitCompleted else { return nil }
return finalText
```

где `postCommitCompleted` взводится только событием `...completed`, пришедшим ПОСЛЕ коммита (`serverEventCount > commitEventCount`).

### 5.6. Обработка серверных событий

Для КАЖДОГО входящего события `serverEventCount += 1`. Разбор: JSON-объект с обязательным полем `"type"`; неразбираемое — молча игнорируется.

| `type` | Действие |
|---|---|
| `conversation.item.input_audio_transcription.delta` | запомнить `item_id` (если есть); непустой `delta` (String) дописать в `partialText`; snapshot `finalText + partialText` → `onPartialUpdate` (main queue); затем `resumeIfReadyAfterCommit()` |
| `conversation.item.input_audio_transcription.completed` | если `commitEventCount != nil && serverEventCount > commitEventCount` → `postCommitCompleted = true`; запомнить `item_id`; если есть строковое `transcript` → `commitSegment(transcript)`, иначе только `resumeIfReadyAfterCommit()` |
| `input_audio_buffer.committed` | запомнить `item_id`; `resumeIfReadyAfterCommit()` |
| `error` | `code`/`message` из вложенного `error` (дефолты `"unknown"` / `"unknown realtime error"`, код обязателен строкой); лог; `terminalError = serverError(code:message:)`; `closed = true`; ожидающий continuation → failure |
| прочие | только `resumeIfReadyAfterCommit()` |

`commitSegment(_ transcript:)`:
- trim; непустой сегмент дописывается в `finalText` через пробел (`if !finalText.isEmpty { finalText += " " }`);
- `partialText = ""`;
- snapshot → `onPartialUpdate`; затем `resumeIfReadyAfterCommit()`.

`resumeIfReadyAfterCommit()`: если есть ожидающий continuation и `readyCommittedTranscriptLocked()` готова — `finalContinuation = nil`, `closed = true`, сокет `.normalClosure`, resume success с `finalText`.

### 5.7. Закрытие сокета

- Receive-loop завершился (ошибка `receive()` или отмена) → `finishWithClose()`: `closed = true`; ожидающий continuation: если `postCommitCompleted` → success с `finalText`, иначе → failure `closedBeforeFinal`. Т.е. сервер, закрывший соединение после коммита и completed, всё равно отдаёт финал.
- `cancel()` (идемпотентен): task из поля обнуляется; под локом `closed = true` и ожидающий continuation → `CancellationError`; `receiveTask?.cancel()`; `task.cancel(with: .normalClosure, reason: nil)`.

### 5.8. Отправка

`send(_ payload: [String: Any], over:)` — `JSONSerialization` → `.string`; ошибка отправки только логируется, не пробрасывается.

---

## 6. Gemini Live (`GeminiLiveTranscription` + `GeminiLiveTranscriptionService`)

Мотивация: у live-модели free-tier квота на порядки больше батчевой (батч — десятки запросов в день; live — токены в минуту, которые один спикер не исчерпает).

### 6.1. Константы и роутинг (`GeminiLiveTranscription`)

```swift
static let defaultBaseURL = "wss://generativelanguage.googleapis.com"
private static let servicePath =
    "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
private static let smartMode = "SMART"   // ВЕРХНИЙ регистр — в отличие от Interactions API!
```

```swift
static func handlesModel(_ model: String) -> Bool {
    let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.hasPrefix("gemini-") && normalized.hasSuffix("-transcribe-live")
}
```

### 6.2. URL сокета `socketURL(baseURL:)`

1. Пустая строка → `defaultBaseURL`.
2. Scheme: `https`/`wss` → `wss`; `http`/`ws` → `ws` (https-база из REST-доков апгрейдится); остальное → `nil`.
3. Host пуст → `nil`.
4. **Не-Google хост** (host не заканчивается на `googleapis.com`) → `URL(string: defaultBaseURL + servicePath)` — фоллбек, чтобы не открывать сокет, который никогда не заговорит этим протоколом.
5. Иначе: `components.path = servicePath`, `components.query = nil`.

Итог: `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`

### 6.3. Setup-сообщение

```swift
static func setupMessage(model: String, customVocabulary: String) throws -> String
```

Дословный JSON:

```json
{
  "setup": {
    "model": "models/gemini-3.5-transcribe-live",
    "generationConfig": {
      "responseModalities": ["TEXT"]
    },
    "inputAudioTranscription": {
      "mode": "SMART",
      "custom_vocabulary": ["Kubernetes", "OmniFlow"]
    }
  }
}
```

- `model` — через `normalizedModelPath(_:)`: trim; префикс `models/` добавляется, если отсутствует (`models/gemini-...`).
- `inputAudioTranscription.mode` = `"SMART"` (верхний регистр).
- `custom_vocabulary` — `GeminiTranscription.vocabularyTerms(from:)` (те же split/dedup/лимит 1000); **пустой список — ключа нет**.
- Язык НЕ передаётся — автодетект, как в батче (пиннинг выводит из smart mode).
- Ключевая нотация camelCase в setup (`generationConfig`, `responseModalities`, `inputAudioTranscription`, `realtimeInput`, `audioStreamEnd`), но `custom_vocabulary` — snake_case.

### 6.4. Аудио и конец потока

```json
{ "realtimeInput": { "audio": { "mimeType": "audio/pcm;rate=24000", "data": "<base64 PCM16>" } } }
```
`rate` — из `Configuration.sampleRate`, которая берётся из `AudioRecorder.realtimeSampleRate` (24000). Модель принимает и другие rate, если кадры честно объявляют реальный.

Конец аудио:

```json
{ "realtimeInput": { "audioStreamEnd": true } }
```

### 6.5. Сервис: конфигурация и жизненный цикл

```swift
struct Configuration {
    let baseURL: String
    let apiKey: String
    let model: String
    let customVocabulary: String
    let sampleRate: Int
}
```

`start()`:
1. `GeminiLiveTranscription.socketURL(baseURL:)`; `nil` → `RealtimeTranscriptionError.invalidBaseURL`.
2. Заголовок `x-goog-api-key: {apiKey}` — ключ едет в заголовке, чтобы не попадать в URL и логи (НЕ Bearer).
3. `socket.resume()`, затем **setup отправляется немедленно** (до старта receive-loop).
4. Старт receive-loop.

Состояние (под `stateQueue`): `transcript` (аккумулированный текст), `finalContinuation`, `streamEnded`, `closed`, `setupCompleted`, `terminalError`.

`appendPCM16`: если `closed` — молча; иначе `audioMessage` и отправка (ошибки отправки только логируются).

`commitAndAwaitFinal()`:
- Нет сокета / `closed` → `RealtimeTranscriptionError.notConnected`.
- `terminalError` уже установлен → бросить его.
- Под локом: если `streamEnded` уже true → немедленно вернуть накопленный `transcript`; иначе `streamEnded = true`, сохранить continuation, отправить `audioStreamEndMessage()`.

`cancel()`:
- `closed = true`, task обнуляется; `receiveTask?.cancel()`; сокет закрывается **`.goingAway`**; ожидающий continuation → `CancellationError`.

### 6.6. Парсинг серверных фреймов `parseServerFrame(_:)`

`ServerFrame { transcript: String?, isComplete: Bool, errorMessage: String?, isSetupComplete: Bool }`.

Порядок разбора входящего текстового фрейма:
1. Не JSON-объект → пустой frame (ничего из флагов).
2. `root["error"]` — объект → `errorMessage = error["message"] ?? "Gemini live transcription failed."`, `isComplete = true`.
3. `root["setupComplete"]` присутствует (любое значение) → `isSetupComplete = true`.
4. `root["serverContent"]` — объект:
   - `inputTranscription.text` (String) → `transcript`; **иначе** `modelTurn.parts` — массив объектов → join их непустых `text`; пустой join → `transcript = nil`.
   - `isComplete = (server["turnComplete"] as? Bool ?? false) || (server["generationComplete"] as? Bool ?? false)`.

### 6.7. Обработка фреймов сервисом

- `isSetupComplete` → `setupCompleted = true`, конец обработки.
- `errorMessage` → лог; `RealtimeTranscriptionError.serverError(code: "live", message:)`; если ожидание идёт — resume failure, иначе сохранить в `terminalError`.
- `transcript` непустой → дописать в `transcript`, snapshot → `onPartialUpdate` (main queue).
- `isComplete` → snapshot `transcript`, trim:
  - пустой → resume failure `RealtimeTranscriptionError.closedBeforeFinal`;
  - непустой → resume success с текстом.

### 6.8. Ошибка соединения до `setupComplete`

Live API отвергает плохой ключ на HTTP-upgrade: сокет просто не коннектится, error-фрейм не приходит. `describe(_:setupCompleted:)`:

```swift
guard !setupCompleted else { return error }
return RealtimeTranscriptionError.serverError(
    code: "live",
    message: "Could not connect to Gemini live transcription. Check the transcription API key."
)
```
Любая ошибка `receive()` до рукопожатия (URLError или POSIX) оборачивается в это сообщение; после `setupComplete` ошибка пробрасывается как есть. Если ожидание не начато — ошибка сохраняется в `terminalError` (и будет выброшена при `commitAndAwaitFinal`).

---

## 7. Роутинг realtime vs батч и fallback (AppState)

### 7.1. Настройки

- `realtimeStreamingEnabled` — UserDefaults `"realtime_streaming_enabled"` (Bool).
- `realtimeStreamingModel` — UserDefaults `"realtime_streaming_model"` (String, модель стрима; может отличаться от батчевой `transcriptionModel`).
- `resolvedTranscriptionBaseURL` = trim(`transcriptionAPIURL`), если непуст, иначе `apiBaseURL` (LLM-базовый URL).
- `resolvedTranscriptionAPIKey` = trim(`transcriptionAPIKey`), если непуст, иначе `apiKey` (LLM-ключ).
- `resolvedTranscriptionLanguage` = `transcriptionLanguage`, нормализованный в нижний регистр и проверенный по списку допустимых кодов (`normalizeTranscriptionLanguage`); пустой/недопустимый → `nil`.

### 7.2. `startRealtimeStreamingIfEnabled()` — вызывается при старте записи

```swift
private func startRealtimeStreamingIfEnabled() {
    guard realtimeStreamingEnabled else { return }
    let model = realtimeStreamingModel.trimmingCharacters(in: .whitespacesAndNewlines)

    // 1. Gemini live-модель — стримить именно её.
    if GeminiLiveTranscription.handlesModel(model) {
        startGeminiLiveStreaming(model: model)
        return
    }

    // 2. Батчевый Gemini-модель транскрипции: OpenAI-совместимый сокет
    //    не аутентифицируется Gemini-ключом — не открывать заведомо мёртвое соединение.
    guard !GeminiTranscription.handlesModel(transcriptionModel) else {
        os_log(.info, log: recordingLog, "realtime streaming skipped — Gemini transcription is file-based")
        return
    }

    // 3. Пустой base URL — скип.
    let trimmedBase = resolvedTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBase.isEmpty else { ... skip ... }

    // 4. OpenAI-совместимый realtime.
    let config = RealtimeTranscriptionService.Configuration(
        baseURL: trimmedBase,
        apiKey: resolvedTranscriptionAPIKey,
        model: model,
        language: resolvedTranscriptionLanguage
    )
    start(service: RealtimeTranscriptionService(config: config))
}
```

`startGeminiLiveStreaming(model:)` строит `GeminiLiveTranscriptionService.Configuration(baseURL: resolvedTranscriptionBaseURL, apiKey: resolvedTranscriptionAPIKey, model: model, customVocabulary: customVocabulary, sampleRate: AudioRecorder.realtimeSampleRate)`.

Итоговая матрица выбора:

| `realtimeStreamingModel` | Батчевая `transcriptionModel` | Что стартует |
|---|---|---|
| `gemini-*-transcribe-live` | любой | **Gemini Live** (стрим) |
| другое / пустое | `gemini-*-transcribe*` (не live) | **ничего** — realtime скип, только батч Gemini |
| другое / пустое | не-Gemini | **OpenAI Realtime** |
| realtime выключен | любой | только батч |

`start(service:)`: `try service.start()`; при ошибке — лог, realtime-сервис не сохраняется (диктовка продолжается в батч). При успехе: `realtimeService = service`, подписка `audioRecorder.onPCM16Samples = { [weak service] data in service?.appendPCM16(data) }`.

### 7.3. Остановка записи: `resolveRawTranscript`

```swift
private static func resolveRawTranscript(
    realtimeService: (any RealtimeTranscriptBackend)?,
    fileService: TranscriptionService,
    fileURL: URL
) async throws -> String
```

Правила (строгий порядок, чтобы не платить за оба транспорта):
1. Если realtime-сервис есть: `try Task.checkCancellation()`; `withTaskCancellationHandler { try await realtimeService.commitAndAwaitFinal() } onCancel: { realtimeService.cancel() }`.
   - `CancellationError` → пробросить наверх (вся сессия отменяется).
   - **Любая другая ошибка** (serverError, closedBeforeFinal, notConnected) → фоллбек: `try await fileService.transcribe(fileURL: fileURL)` (батч по файлу WAV).
2. Если realtime-сервиса нет → сразу `fileService.transcribe(fileURL:)`.

Плюс санитарные проверки AppState вокруг: перед коммитом `activeRealtime = realtimeService; realtimeService = nil; audioRecorder.onPCM16Samples = nil`; после завершения задачи — `defer { activeRealtime?.cancel() }`.

После получения `rawTranscript` конвейер продолжается: `parseTranscriptCommands` → пост-обработка (см. `11-postprocessing.md`).

---

## Чек-лист «что должно получиться в коде»

- [ ] `RealtimeTranscriptBackend` — AnyObject-протокол: `onPartialUpdate`, `start() throws`, `appendPCM16(Data)`, `commitAndAwaitFinal() async throws -> String`, `cancel()`.
- [ ] Батч OpenAI/Groq: `POST {base}/audio/transcriptions`; multipart в порядке model → response_format → (language) → file; boundary = `UUID().uuidString`; Bearer-аутентификация.
- [ ] `response_format`: `verbose_json` только для `whisper-1`, `whisper-large-v3`, `whisper-large-v3-turbo` (lowercased), иначе `json`.
- [ ] Content-Type файла: `.wav`→`audio/wav`, `.mp3`→`audio/mpeg`, `.m4a`→`audio/mp4`, дефолт `audio/mp4`.
- [ ] Таймаут транскрипции: `UserDefaults` `"transcription_timeout_seconds"` > 0, иначе 20 с; гонка задача-загрузка vs таймер; `URLError.timedOut` → `transcriptionTimedOut`.
- [ ] Валидация ключа: `GET {base}/models`, таймаут 10 с, Bearer; 200 = валиден.
- [ ] `friendlyHTTPMessage`: тексты 401/403/404/413/400/429/5xx/default — дословно из раздела 3.8.
- [ ] Нормализация base URL: http/https, хост обязателен, `"/"`→`""`, срез хвостовых слэшей.
- [ ] Gemini батч: `handlesModel` = `gemini-*` + содержит `transcribe` + не `-live`; не-Google хост → `https://generativelanguage.googleapis.com/v1beta`; endpoint `{base}/interactions`; auth `x-goog-api-key`.
- [ ] Тело Interactions: snake_case `generation_config.transcription_config`, `mode.type = "smart"`, `input[].mime_type`, inline base64; `custom_vocabulary` только при непустом списке; `language_codes` никогда.
- [ ] `vocabularyTerms`: split по `\n , ;`, trim, dedup по lowercased, `prefix(1000)`.
- [ ] Парсинг Interactions: сначала error-конверты ДВУХ форм (`{"error":{...}}` и `[{...}]`), затем `status == "completed"`, затем join `steps[type == nil || "model_output"].content[].text`, пусто → ошибка.
- [ ] OpenAI Realtime: URL `ws(s)://host[/v1]/realtime?intent=transcription` (не дублировать `/v1`); `session.update` с `audio/pcm rate=24000`, `turn_detection: null`; `input_audio_buffer.append` (base64) и `.commit`; дельты/комплиты склеиваются в `finalText`, финал = commit отправлен + `partialText` пуст + `completed` после коммита; `error` → terminal; закрытие `.normalClosure`; сервер закрылся после completed → финал всё равно возвращается.
- [ ] Gemini Live: `wss://generativelanguage.googleapis.com/ws/...BidiGenerateContent`; не-Google хост → дефолтный URL; `x-goog-api-key`; setup с `models/`-префиксом, `responseModalities: ["TEXT"]`, `inputAudioTranscription.mode = "SMART"`, опциональным `custom_vocabulary`; `realtimeInput.audio` с `audio/pcm;rate={sampleRate}` (24000 из `AudioRecorder.realtimeSampleRate`); конец — `audioStreamEnd: true`; закрытие `.goingAway`.
- [ ] Парсинг Live-фреймов: `error` → ошибка; `setupComplete` → флаг; `serverContent.inputTranscription.text` либо `modelTurn.parts[].text`; `turnComplete || generationComplete` → финал (пустой → `closedBeforeFinal`).
- [ ] Ошибка соединения до `setupComplete` → сообщение «Could not connect to Gemini live transcription. Check the transcription API key.»
- [ ] Роутинг: `gemini-*-transcribe-live` → Live; батчевый Gemini в `transcriptionModel` → realtime отключён; иначе OpenAI Realtime; ошибка старта → без realtime; ошибка коммита (кроме отмены) → батч по файлу; realtime берёт `realtime_streaming_model`, отдельные transcription key/URL с фоллбеком на LLM key/URL.
