# Спецификация 21 — Контекст приложения: AX, скриншот, vision-суммаризация

Референс: `Sources/AppContextService.swift`. Точки вызова и потребители: `Sources/AppState.swift` (`startContextCapture`, `fallbackContextAtStop`, `stopAndTranscribe`, `recordPipelineHistoryEntry`). Роли в промптах пост-обработки: см. `11-postprocessing.md` (здесь фиксируется только передача `AppContext`).

---

## 1. Структуры данных

### 1.1 `AppSelectionSnapshot`

Поле за полем (все — `String?`):

```swift
struct AppSelectionSnapshot {
    let appName: String?          // frontmostApp.localizedName
    let bundleIdentifier: String? // frontmostApp.bundleIdentifier
    let windowTitle: String?      // AX-заголовок focused window, иначе localizedName
    let selectedText: String?     // kAXSelectedTextAttribute, сырой (без замены \n)
}
```

### 1.2 `AppContext`

```swift
struct AppContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let selectedText: String?
    let currentActivity: String        // 2-предложенная сводка или fallback-фраза
    let contextSystemPrompt: String?   // системный промпт контекста (кастомный или дефолт)
    let contextPrompt: String?         // полный промпт LLM (Model/…/System/…/User/…), nil если LLM не отвечал
    let screenshotDataURL: String?     // "data:image/jpeg;base64,…"
    let screenshotMimeType: String?    // "image/jpeg"
    let screenshotError: String?       // человекочитаемая причина отсутствия скриншота

    var contextSummary: String { currentActivity }  // единственный производный accessor
}
```

---

## 2. Foreground-приложение

- Источник: `NSWorkspace.shared.frontmostApplication`.
- Берутся `localizedName`, `bundleIdentifier`, `processIdentifier`.
- Если frontmost нет (`nil`): `collectContext()` немедленно возвращает `AppContext` со всеми nil-полями, `currentActivity = "You are dictating in an unrecognized context."`, `screenshotError = "No frontmost application"`, `contextSystemPrompt` = resolved-промпт.
- AX-элемент приложения: `AXUIElementCreateApplication(frontmostApp.processIdentifier)`.

---

## 3. AX-чтение

Импорт `ApplicationServices`. Все чтения — `AXUIElementCopyAttributeValue`, результат `.success` обязателен.

### 3.1 Заголовок окна (`focusedWindowTitle`)

1. `kAXFocusedWindowAttribute` → элемент (проверка `CFGetTypeID(rawValue) == AXUIElementGetTypeID()`, `unsafeBitCast` к `AXUIElement`).
2. `kAXTitleAttribute` → строка → `trimmedText` (тримминг + замена `\n` на пробел; пустое → nil).

### 3.2 Выделенный текст (`selectedText` / `rawSelectedText`)

Порядок попыток:
1. `kAXFocusedUIElementAttribute` приложения → элемент; у него `kAXSelectedTextAttribute`.
2. Fallback: `kAXSelectedTextAttribute` прямо на app-элементе.

Разница вариантов:
- `selectedText` — через `accessibilityString` (тримминг + замена `\n` → пробел, пустое → nil); идёт в LLM и в `AppContext.selectedText`.
- `rawSelectedText` — через `accessibilityRawString` (только проверка `.success` и непустоты, БЕЗ нормализации); используется в `collectSelectionSnapshot`.

### 3.3 Геометрия окна (`focusedWindowBounds`)

- `kAXFocusedWindowAttribute` → у окна `kAXPositionAttribute` и `kAXSizeAttribute`.
- Значения — `AXValue`: `AXValueGetValue(axValue, .cgPoint, &point)` и `.cgSize`. Проверка `CFGetTypeID == AXValueGetTypeID()`.
- Итог: `CGRect(origin: point, size: size)`; nil при любой неудаче.

---

## 4. Скриншот активного окна

### 4.1 Прегейт и список окон

1. `CGPreflightScreenCaptureAccess()` — если false: `(nil, nil, "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording.")`.
2. `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]`; nil → `"Unable to read window list"`.

Используемые ключи словаря окна: `kCGWindowOwnerPID`, `kCGWindowLayer`, `kCGWindowIsOnscreen`, `kCGWindowNumber`, `kCGWindowBounds`, `kCGWindowName`.

Кандидаты (`CandidateWindow { id: CGWindowID; layer: Int; area: Int; bounds: CGRect?; name: String? }`):
- `ownerPID == processIdentifier` (Int из словаря);
- `kCGWindowIsOnscreen == true`;
- `layer` — из словаря, по умолчанию 0;
- `area = width * height` из bounds (при отсутствии bounds — 1×1);
- `name` — тримнутый `kCGWindowName` (nil/пустой → nil).

`boundsRect` читает `"X"`, `"Y"`, `"Width"`, `"Height"` как `CGFloat`.

### 4.2 Выбор окна по AX-bounds (если `focusedWindowBounds` не nil и не `isNull`)

1. Для каждого кандидата с bounds: пересечение `intersection(focusedWindowBounds)`; если не пусто — пара `(кандидат, overlap = width*height)`.
2. Сортировка: **по возрастанию `layer`** (меньший слой приоритетнее); при равных слоях — **по убыванию overlap**.
3. Первый кандидат → `captureWindowImage`; успех → `(dataURL, "image/jpeg", nil)`.

### 4.3 Fallback по имени окна (если пересечение не дало картинки)

- Условие: есть `focusedWindowTitle` (непустой после lowercased+trim).
- Фильтр кандидатов с непустым `name`: `normalizedName == normalizedTarget || normalizedName.contains(normalizedTarget)` (обе строки lowercased, тримнутые).
- Сортировка: по возрастанию `layer`, при равных — по убыванию `area`.
- Первый → `captureWindowImage`; успех → `(dataURL, "image/jpeg", nil)`.

### 4.4 Fallback: весь экран + обрезка белого

1. `CGWindowListCreateImage(CGRect.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])`; nil → `"Could not capture screenshot from the active window"`.
2. `croppedWhitespaceImage`:
   - растеризация в RGBA8 (4 байта/пиксель, `bytesPerRow = width*4`), colorSpace `CGColorSpace(name: CGColorSpace.sRGB)`, `CGImageAlphaInfo.premultipliedLast`; при неудаче контекста вернуть исходный image;
   - пороги: белый `UInt8 = 245` (все R,G,B ≥ 245 — фон), альфа `UInt8 = 5` (a ≤ 5 — игнор);
   - границы контента `minX/minY/maxX/maxY`; если контента нет — вернуть исходный image;
   - `image.cropping(to: CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1))`; nil → исходный image.
3. Кодирование через `convertImageToDataURL`; неудача → `"Could not capture screenshot within size limits"`.

### 4.5 Захват окна (`captureWindowImage`)

`CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution])` → `convertImageToDataURL(image, mimeType: "image/jpeg", fileType: .jpeg, compression: 0.5, maxDimension: <screenshotMaxDimension>)`.

### 4.6 Кодирование с итеративным сжатием (`convertImageToDataURL`)

- `compressionSteps`: `[compression, compression*0.5, compression*0.25]` → для основного вызова **0.5 → 0.25 → 0.125**.
- `dimensionSteps`: `[maxDimension, maxDimension*0.75, maxDimension*0.5]` → **1024 → 768 → 512** (если настройка равна 1024).
- Внешний цикл — по размерам, внутренний — по качеству: для каждого размера ресайз (`resizedImage`: только если обе стороны/любая > лимита; `scale = min(maxDim/width, maxDim/height, 1.0)`; CGContext с `interpolationQuality = .high`, `bitmapInfo` исходного), затем `NSBitmapImageRep(cgImage:)` и `representation(using: fileType, properties: [.compressionFactor: comp])`.
- Условие приёма: `base64EncodedString().count <= 500_000` (`maxScreenshotDataURILength`).
- Результат: `"data:\(mimeType);base64,\(base64)"`. Ни одна комбинация не прошла → nil.

Параметры конструктора сервиса: `screenshotMaxDimension: CGFloat = AppContextService.defaultScreenshotMaxDimension` (= 1024); значения ≤ 0 заменяются дефолтом. AppState хранит настройку `context_screenshot_max_dimension` с валидным множеством `[1024, 768, 640, 512]` (вне множества — 1024) и прокидывает её как `CGFloat`.

---

## 5. Vision-суммаризация (`inferActivityWithLLM`)

### 5.1 Константы и таймаут

- `defaultContextModel = "qwen/qwen3.6-27b"` (входит в `ModelConfiguration.visionModels`; кастомная модель триммятся, пустая → дефолт).
- `defaultScreenshotMaxDimension: CGFloat = 1024`.
- `contextRequestTimeoutSeconds`: override из `UserDefaults.standard.double(forKey: "context_request_timeout_seconds")`, если > 0, иначе **20**.
- `baseURL` — параметр init, AppState передаёт главный `apiBaseURL` (дефолт `https://api.groq.com/openai/v1`).
- Запрос идёт через `LLMAPITransport.data(for:)` (см. `11-postprocessing.md`).

### 5.2 Системный промпт (ДОСЛОВНО `defaultContextPrompt`)

```
You are a context synthesis assistant for a speech-to-text pipeline.
Given app/window metadata and an optional screenshot, output exactly two sentences that describe what the user is doing right now and the likely writing intent in the current window.
Prioritize concrete details only from the context: for email, identify recipients, subject or thread cues, and whether the user is replying or composing; for terminal/code/text work, identify the active command, file, document title, or topic.
If details are missing, state uncertainty instead of inventing facts.
Return only two sentences, no labels, no markdown, no extra commentary.
```

Маркер версии: `defaultContextPromptDate = "2026-02-24"`. Если кастомный промпт (после тримминга) непуст — используется он.

### 5.3 Payload

`POST {baseURL}/chat/completions`; заголовки: `Authorization: Bearer <apiKey>`, `Content-Type: application/json`; `timeoutInterval` = 20 с.

Метаданные (текстовый блок, дословный формат):

```
App: <appName ?? "Unknown">
Bundle ID: <bundleIdentifier ?? "Unknown">
Window: <windowTitle ?? "Unknown">
Selected text: <selectedText ?? "None">
```

- С скриншотом — user-сообщение — массив трёх частей:
  1. `{"type": "text", "text": "Analyze the screenshot plus metadata to infer current activity."}`
  2. `{"type": "text", "text": <метаданные>}`
  3. `{"type": "image_url", "image_url": {"url": <data-URL>}}`
- Без скриншота — user-сообщение — строка: `"Analyze the context and infer the user's current activity in exactly two sentences.\n\n<метаданные>"`.
- Payload: `{"model": <model>, "temperature": 0.2, "messages": [{"role": "system", "content": <системный промпт>}, {"role": "user", "content": <см. выше>}]}` — `JSONSerialization` без спец-опций.

### 5.4 Ретрай-логика

`attempts`: если есть скриншот — `[(contextModel, скриншот), (contextModel, nil)]`; иначе — `[(contextModel, nil)]`. Т.е. **первая попытка с картинкой, вторая — text-only**, тот же baseURL/ключ. Любая неуспешная (не-200, невалидный JSON, исключение) → следующая попытка.

`contextPrompt` при успехе (строка для дебаг-панели):

```
Model: <model>

[System]
<системный промпт>
[User]
<текстовое описание user-сообщения: "Analyze the screenshot plus metadata to infer current activity.\n<метаданные>" либо text-only-строка>
```

### 5.5 Разбор ответа

- `statusCode == 200`; иначе следующая попытка.
- Путь в JSON: `choices[0].message.content` (строка). Пустой/отсутствующий → nil.
- `activitySummary(from:model:)`:
  1. Если `ModelConfiguration.config(for: model).shouldStripThinkTags` — `ModelConfiguration.stripThinkTags(content)` (для `qwen/qwen3.6-27b` = true, теги `<think>…</think>` вырезаются; см. `12-models-parsing.md`).
  2. Тримминг; пустое → nil.
  3. `normalizedActivitySummary`: разбиение по `.` `。` `!` `?`; тримминг сегментов, пустые отбрасываются. Если предложений ≤ 2 — вернуть исходную (тримнутую) строку как есть; иначе — первые два, склеенные `". "` и с `"."` на конце.

### 5.6 Fallback (`fallbackCurrentActivity`)

Вызывается, если `apiKey` пуст (тримнутый) или обе попытки LLM не удались; `contextPrompt = nil`.

- `activeApp = appName ?? "the active application"`;
- со скриншотом: `"Could not reliably infer a two-sentence summary for \(activeApp) from the screenshot and metadata."`
- без: `"Could not reliably infer a two-sentence summary for \(activeApp) from the visible metadata."`

`collectSelectionSnapshot()` LLM не вызывает вовсе — это дешёвый AX-снимок.

---

## 6. Точки вызова из AppState

### 6.1 `startContextCapture()` — сразу после успешного старта записи

- Вызывается в главном async-блоке старта записи после `audioRecorder.startRecording()` (при условии `isRecording && activeRecordingTriggerMode != nil`).
- Действия: `contextCaptureTask?.cancel()`; `capturedContext = nil`; индикаторы: `lastContextSummary = "Collecting app context..."`, `lastContextScreenshotStatus = "Collecting screenshot..."`.
- `contextCaptureTask = Task { … }`: `await contextService.collectContext()`; затем на MainActor — `capturedContext = context`, заполнение `lastContextSummary` (= `currentActivity`), `lastContextScreenshotDataURL`, статус скриншота (`screenshotError ?? "available (<mime>)"`), `lastContextAppName/BundleIdentifier/WindowTitle/SelectedText`, `lastContextLLMPrompt` (= `contextPrompt ?? ""`), `lastPostProcessingStatus = "App context captured"`, затем `handleScreenshotCaptureIssue(context.screenshotError)`.
- `handleScreenshotCaptureIssue`: при ошибке-правах на запись экрана (`isScreenCapturePermissionError`) — в command-режиме фатально: отмена realtime, `audioRecorder.cancelRecording()`, `contextCaptureTask`/`capturedContext` = nil, `isRecording = false`, `shortcutSessionController.reset()`, `statusText = "Screenshot Required"`, оверлей, звук «Basso», алерт; в диктовке — только флаг `hasScreenRecordingPermission = false` без остановки. Прочие (транзиентные) ошибки — игнорируются, запись продолжается без контекста.
- Сервис пересобирается при изменении `apiKey`/`apiBaseURL` (`rebuildContextService()`): `AppContextService(apiKey:, baseURL: apiBaseURL, customContextPrompt:, contextModel:, screenshotMaxDimension: CGFloat(contextScreenshotMaxDimension))`.

### 6.2 Стоп записи: приоритет контекста (в `stopAndTranscribe`)

В момент `stopRecording` фиксируются: `sessionContext = capturedContext`, `inFlightContextTask = contextCaptureTask`, оба поля сбрасываются. Выбор финального контекста (и в успешной ветке, и в ветке ошибки транскрипции):

1. `sessionContext` (контекст, готовый на момент остановки) — приоритет;
2. иначе дождаться `inFlightContextTask?.value` (запрос, ещё летевший при остановке);
3. иначе `fallbackContextAtStop()`.

### 6.3 `fallbackContextAtStop()`

Лёгкий контекст без LLM и скриншота: `NSWorkspace.shared.frontmostApplication`, AX-заголовок focused window (локальная копия логики в AppState). Поля: `selectedText = nil`, `screenshotDataURL = nil`, `screenshotMimeType = nil`, `screenshotError = "No app context captured before stop"`, `contextPrompt = nil`,
`currentActivity = "Could not refresh app context at stop time; using text-only post-processing."`,
`contextSystemPrompt = resolvedContextSystemPrompt()` (кастомный `customContextPrompt` либо `AppContextService.defaultContextPrompt`).

### 6.4 Куда идёт результат

- `AppContext` передаётся в `processTranscript(..., context: appContext, ...)` → `PostProcessingService` использует `context.contextSummary` как строку `CONTEXT: "<summary>"` в промптах (дословно — см. `11-postprocessing.md`); `contextSystemPrompt` идёт в историю отдельно.
- Дебаг-поля UI (`lastContext*`) заполняются из того же `AppContext` в момент завершения транскрипции.
- `recordPipelineHistoryEntry(..., context: appContext, ...)`: маппинг полей — `capturedSelection = context.selectedText`, `contextSummary = context.contextSummary`, `contextSystemPrompt = context.contextSystemPrompt`, `contextPrompt = context.contextPrompt`, `contextScreenshotDataURL = context.screenshotDataURL`, `contextScreenshotStatus = context.screenshotError ?? "available (<mime>)"`, `contextAppName/BundleIdentifier/WindowTitle = context.*`. Запись пишется и при успехе, и при ошибке транскрипции (см. `22-storage.md`).

---

## 7. Чек-лист «что должно получиться в коде»

- [ ] `AppSelectionSnapshot` и `AppContext` — ровно перечисленные поля; `contextSummary` — алиас `currentActivity`.
- [ ] Foreground через `NSWorkspace.shared.frontmostApplication`; AX через `AXUIElementCreateApplication(pid)`.
- [ ] AX-цепочки: `kAXFocusedWindowAttribute → kAXTitleAttribute`; `kAXFocusedUIElementAttribute → kAXSelectedTextAttribute` с fallback на app-элемент; позиция/размер через `AXValueGetValue(.cgPoint/.cgSize)`.
- [ ] Скриншот: прегейт `CGPreflightScreenCaptureAccess`; `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` с ключами ownerPID/layer/isOnscreen/number/bounds/name; выбор по max-overlap с AX-bounds (меньший layer приоритетнее), затем по имени (равенство/contains), затем весь экран + обрезка белого (пороги 245/5); JPEG через `NSBitmapImageRep`; итерации качество 0.5→0.25→0.125 × размер 1024→768→512; лимит data-URL 500 000 символов.
- [ ] LLM: `POST {base}/chat/completions`, модель `qwen/qwen3.6-27b`, `temperature: 0.2`, system+user; multipart user-сообщение с `image_url` data-URL; ретрай text-only; таймаут 20 с (override `context_request_timeout_seconds`); системный промпт дословно; нормализация до 2 предложений; strip think-тегов по `ModelConfiguration`; два fallback-текста дословно.
- [ ] AppState: `startContextCapture()` сразу после старта записи; при остановке — приоритет готового контекста → ожидание in-flight задачи → `fallbackContextAtStop()`; права на запись экрана в command-режиме фатальны; результат идёт в `PostProcessingService` (строка `CONTEXT:`) и в `PipelineHistory`.
