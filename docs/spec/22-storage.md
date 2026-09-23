# Спецификация 22 — Хранилища: настройки, история пайплайна (Core Data), экспорт кейса, flag-файл записи

Референс: `Sources/KeychainStorage.swift` (тип `AppSettingsStorage`), `Sources/PipelineHistoryStore.swift`, `Sources/PipelineHistoryItem.swift`, `Sources/TestCaseExporter.swift`, `Sources/AppState.swift` (пути аудио, flag-файл, resolved-ключи), `Sources/AppName.swift`.

Базовая папка данных: `<Application Support>/<AppName>/`, где `AppName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") ?? "OmniFlow"` (см. `00-architecture.md` / `01-contracts.md`). Dev-сборка получает собственную папку за счёт иного `CFBundleName`.

---

## 1. `AppSettingsStorage` (файл `.settings`)

`enum AppSettingsStorage` — namespace статических методов. Хранилище секретов и URL: плоский JSON-словарь `[String: String]`, ключ словаря = «account».

### 1.1 Расположение и права

- Каталог: `<AppSupport>/<AppName>/`, создаётся лениво (`createDirectory(withIntermediateDirectories: true)`, ошибки глушатся).
- Файл: `<AppSupport>/<AppName>/.settings`.
- Запись: `JSONEncoder().encode(dict)` → `data.write(to: url, options: [.atomic])` → `FileManager.setAttributes([.posixPermissions: 0o600])`. Ошибки глушатся (`try?`).
- Чтение: файла нет / битый JSON → `[:]` (самовосстановление).

### 1.2 Публичный API

```swift
static func load(account: String) -> String?   // миграция → чтение словаря → dict[account]
static func save(_ value: String, account: String)  // dict[account] = value; write
static func delete(account: String)            // dict.removeValue; write
```

Каждый read-modify-write цикл сериализуется общим `NSLock` (API статический и
доступен всему модулю; два конкурентных вызова не должны терять обновление).

### 1.3 Ключи (accounts), пишемые из AppState

| Ключ | Что хранит | Правило записи |
|---|---|---|
| `groq_api_key` | главный API-ключ | пустое значение → `delete` |
| `api_base_url` | главный base URL | пустое ИЛИ равное `defaultAPIBaseURL` (`https://api.groq.com/openai/v1`) → `delete` (дефолт НЕ сохраняется) |
| `transcription_api_url` | переопределение URL транскрипции | пустое (после trim) → `delete`, иначе сохраняется trim-нутым; при чтении из хранилища тоже trim-ится |
| `transcription_api_key` | переопределение ключа транскрипции | пустое → `delete` |

Остальные настройки приложения — в UserDefaults (см. `01-contracts.md`); в `.settings` живут только перечисленные.

### 1.4 Одноразовая миграция с Keychain

- Флаг внутри того же словаря: `keychain_migration_done` (значение `"true"`).
- `load(account:)` перед чтением вызывает `migrateFromKeychainIfNeeded(account:)`:
  1. если в словаре уже есть `keychain_migration_done` — выход;
  2. чтение из Keychain: `kSecClassGenericPassword`, `kSecAttrService = bundleID` (`Bundle.main.bundleIdentifier ?? "com.nick8cyber.omniflow"`), `kSecAttrAccount = account`, `kSecReturnData: true`, `kSecMatchLimit: kSecMatchLimitOne`; `SecItemCopyMatching`; успех — Data → UTF8 строка;
  3. если строка непустая (после тримминга): записать её в `dict[account]`, поставить флаг, затем `SecItemDelete` той же тройки (class/service/account);
  4. иначе — только поставить флаг (миграция считается выполненной и при пустом Keychain).

### 1.5 Resolved-значения транскрипции (AppState)

```swift
private var resolvedTranscriptionBaseURL: String {
    let trimmed = transcriptionAPIURL.trimmed
    return trimmed.isEmpty ? apiBaseURL : trimmed        // fallback на главный URL
}
private var resolvedTranscriptionAPIKey: String {
    let trimmed = transcriptionAPIKey.trimmed
    return trimmed.isEmpty ? apiKey : trimmed            // fallback на главный ключ
}
```

Потребители: `makeTranscriptionService()` и конфигурации realtime-сервисов (`RealtimeTranscriptionService.Configuration`, `GeminiLiveTranscriptionService.Configuration`), а также guard «URL пуст → realtime не стартуем».

---

## 2. `PipelineHistoryStore` — Core Data

### 2.1 Модель (программная, без .xcdatamodeld)

- `NSPersistentContainer(name: "PipelineHistory", managedObjectModel:)`; модель строится в коде.
- Одна entity: **`PipelineHistoryEntry`**, `managedObjectClassName = NSStringFromClass(PipelineHistoryEntry.self)`; класс-обёртка `@objc(PipelineHistoryEntry) final class PipelineHistoryEntry: NSManagedObject` c `@NSManaged`-полями (в рантайме все — опциональные Swift-типы; строжесть задаётся схемой).

Полный список атрибутов (имя, тип `NSAttributeType`, optionality, default):

| # | Атрибут | Тип | Optional | Default |
|---|---|---|---|---|
| 1 | `intent` | string | да | `"dictation"` |
| 2 | `selectedText` | string | да | — |
| 3 | `capturedSelection` | string | да | — |
| 4 | `id` | UUID | **нет** | — |
| 5 | `timestamp` | date | **нет** | — |
| 6 | `rawTranscript` | string | **нет** | — |
| 7 | `postProcessedTranscript` | string | **нет** | — |
| 8 | `postProcessingPrompt` | string | да | — |
| 9 | `systemPrompt` | string | да | — |
| 10 | `contextSummary` | string | **нет** | — |
| 11 | `contextSystemPrompt` | string | да | — |
| 12 | `contextPrompt` | string | да | — |
| 13 | `contextScreenshotDataURL` | string | да | — |
| 14 | `contextScreenshotStatus` | string | **нет** | — |
| 15 | `postProcessingStatus` | string | **нет** | — |
| 16 | `debugStatus` | string | **нет** | — |
| 17 | `customVocabulary` | string | **нет** | — |
| 18 | `audioFileName` | string | да | — |
| 19 | `contextAppName` | string | да | — |
| 20 | `contextBundleIdentifier` | string | да | — |
| 21 | `contextWindowTitle` | string | да | — |

Связей нет; модель содержит только эту entity.

### 2.2 Загрузка стора и восстановление

- SQLite-путь: `<AppSupport>/<AppName>/PipelineHistory.sqlite` (каталог создаётся при init). Если путь получить не удалось — `NSPersistentStoreDescription()` (дефолтный).
- Описание стора: `shouldMigrateStoreAutomatically = true`, `shouldInferMappingModelAutomatically = true`.
- `loadPersistentStores` превращается в синхронный вызов: semaphore + `NSLock`, счётчик оставшихся колбэков = `max(1, descriptions.count)`; возвращается первая ошибка.
- Схема восстановления:
  1. успех → `isStoreLoaded = true`;
  2. провал → печать `"[PipelineHistoryStore] Failed to load persistent store at <path>. Attempting recovery."`; удалить файлы `<base>`, `<base>-wal`, `<base>-shm` (`destroySQLiteStoreFiles`); удалить осиротевшие записи аудио — все `audio/*.wav` в каталоге данных (`removeOrphanedAudioFiles`: строки-владельцы уничтожены вместе со стором, рекордер в этот каталог больше ничего не пишет); снять все `coordinator.persistentStores` (`try? coordinator.remove(store)`); пересоздать description и повторить загрузку;
  3. снова провал → печать `"[PipelineHistoryStore] Failed to recover persistent store. Falling back to in-memory history."`; снова снять stores; description с `type = NSInMemoryStoreType`; третья загрузка определяет `isStoreLoaded` (при неуспехе — false).
- Все операции при `isStoreLoaded == false` — no-op (возврат пустых результатов).

### 2.3 Операции (все — на `container.viewContext` через `performAndWait`)

- `loadAllHistory() -> [PipelineHistoryItem]`: fetch entity `"PipelineHistoryEntry"`, сортировка `NSSortDescriptor(key: "timestamp", ascending: false)`; конвертация `makeHistoryItem` с восстановлением дефолтов: `intent` — rawValue с fallback `.dictation`; `timestamp ?? Date()`; `rawTranscript/postProcessedTranscript/contextSummary ?? ""`; `contextScreenshotStatus ?? "available (image)"`; `postProcessingStatus/debugStatus/customVocabulary ?? ""`.
- `append(_ item:, maxCount:) throws -> [String]`: `insert(item)` затем `trim(to: maxCount)`; возвращает имена вытесненных аудиофайлов.
- `update(_ item:) throws`: fetch по `NSPredicate(format: "id == %@", item.id as CVarArg)`; перезапись полей: intent, selectedText, capturedSelection, rawTranscript, postProcessedTranscript, postProcessingPrompt, systemPrompt, contextSystemPrompt, postProcessingStatus, debugStatus, contextAppName, contextBundleIdentifier, contextWindowTitle (timestamp/скриншот/аудио НЕ трогаются).
- `delete(id: UUID) throws -> String?`: fetch по id → удалить; вернуть `audioFileName` удалённого.
- `clearAll() throws -> [String]`: удалить все (та же сортировка), вернуть все `audioFileName`.
- `trim(to maxCount:) throws -> [String]`: `maxCount <= 0` → эквивалент `clearAll()`; иначе если `entities.count > maxCount` — удалить хвост после первых `maxCount` (сортировка timestamp desc), вернуть их `audioFileName`.
- `saveContext()`: `guard viewContext.hasChanges`; `try viewContext.save()`; при ошибке `rollback()` + throw.

### 2.4 Лимит истории

- `AppState.maxPipelineHistoryCount = 20` (`let`, не настраивается).
- При append в AppState: `pipelineHistoryStore.append(newEntry, maxCount:)`; для каждого вытесненного имени — `Self.deleteAudioFile(name)` (удаление `<AppSupport>/<AppName>/audio/<name>`); затем `pipelineHistory = pipelineHistoryStore.loadAllHistory()`.

### 2.5 Аудиофайлы записей

- Каталог: `<AppSupport>/<AppName>/audio/` (`AppState.audioStorageDirectory()`, создаётся лениво).
- `saveAudioFile(from tempURL:) -> SavedAudioFile?`: имя `UUID().uuidString + ".wav"`, `FileManager.copyItem`; при ошибке — os_log `"failed to persist audio file …"` и nil (тогда транскрипция читает исходный temp-файл, а история остаётся без аудио).
- `deleteAudioFile(_ name:)`: `removeItem`, ошибки глушатся.
- Источник WAV — temp-файл `AudioRecorder` (`stopRecording` completion; см. `20-audio.md`).

### 2.6 `PipelineHistoryItem` (DTO, Codable)

Поля (и их дефолты в init): `intent: PipelineHistoryItemIntent = .dictation`, `selectedText: String?`, `capturedSelection: String?`, `id: UUID = UUID()`, `timestamp: Date`, `rawTranscript: String`, `postProcessedTranscript: String`, `postProcessingPrompt: String?`, `systemPrompt: String? = nil`, `contextSummary: String`, `contextSystemPrompt: String? = nil`, `contextPrompt: String? = nil`, `contextScreenshotDataURL: String?`, `contextScreenshotStatus: String`, `postProcessingStatus: String`, `debugStatus: String`, `customVocabulary: String`, `audioFileName: String? = nil`, `contextAppName: String? = nil`, `contextBundleIdentifier: String? = nil`, `contextWindowTitle: String? = nil`.

`enum PipelineHistoryItemIntent: String, Codable { case dictation; case commandAutomatic = "command:automatic"; case commandManual = "command:manual" }`.

---

## 3. `TestCaseExporter` — экспорт отладочного кейса

`struct TestCaseExporter`, статические методы. Назначение: самодостаточный ZIP для багрепорта.

### 3.1 UI-поток (`exportWithSavePanel(item:audioDirURL:)`)

- `@MainActor`. `NSSavePanel`: `allowedContentTypes = [UTType.zip]`; `nameFieldStringValue = "omniflow-case-<timestamp>.zip"`; `title = "Export Test Case"`; `message = "Choose where to save the test case ZIP."`; `panel.begin { response in … }`.
- `<timestamp>` = `isoTimestamp(from: item.timestamp)`: `ISO8601DateFormatter` c опциями `[.withFullDate, .withTime, .withColonSeparatorInTime]`, затем замена `:` на `-` (например `2026-02-24T15-04-05`).
- При `.OK`: работа на `DispatchQueue.global(qos: .userInitiated)`; при ошибке — `NSAlert` `"Export Failed"` с `error.localizedDescription`, `runModal` на main.

### 3.2 Состав ZIP

```
omniflow-case-<timestamp>.zip
├── case.json                     # метаданные, транскрипты, контекст, промпты, настройки
├── screenshot.jpg (или .png)     # декод из contextScreenshotDataURL, если есть
└── <audioFileName>               # копия исходного WAV, если есть
```

### 3.3 `writeZip` — алгоритм

1. Temp-каталог `<tmp>/omniflow-case-<UUID>/`; `defer` — удалить его.
2. Скриншот: `decodeDataURL` (индекс последней запятой, `Data(base64Encoded:, options: .ignoreUnknownCharacters)`); провал → `.screenshotDecodeFailed`. Расширение: `dataURL.hasPrefix("data:image/png") ? "png" : "jpg"`; файл `screenshot.<ext>`, в case.json — путь `"./screenshot.<ext>"`.
3. Аудио: файл `<audioDirURL>/<audioFileName>`; отсутствует → `.missingAudioFile(audioFileName)` (фатально для экспорта). Копия в temp под тем же именем, путь `"./<audioFileName>"`.
4. case.json (JSONSerialization, `[.prettyPrinted, .sortedKeys]`):

```json
{
  "id": "case-<timestamp>",
  "exported_at": "<ISO8601 от текущего Date>",
  "intent": "<item.intent.rawValue>",
  "run_uuid": "<item.id.uuidString>",
  "run_timestamp": "<ISO8601 от item.timestamp>",
  "metadata": {
    "app_name": "<contextAppName ?? \"\">",
    "bundle_identifier": "<contextBundleIdentifier ?? \"\">",
    "window_title": "<contextWindowTitle ?? \"\">",
    "selected_text": "<capturedSelection ?? selectedText ?? \"\">"
  },
  "pipeline": {
    "raw_transcript": "...",
    "post_processed_transcript": "...",
    "context_summary": "...",
    "context_prompt": "<… ?? \"\">",
    "post_processing_prompt": "<… ?? \"\">",
    "post_processing_status": "...",
    "screenshot_status": "<contextScreenshotStatus>",
    "screenshot_path": "./screenshot.jpg",   // только если есть
    "audio_path": "./<UUID>.wav"             // только если есть
  },
  "settings": {
    "custom_vocabulary": "...",
    "system_prompt": "<… ?? \"\">",
    "context_system_prompt": "<… ?? \"\">"
  }
}
```

5. Архивация: подкаталог `__archive-work` внутри temp; `destinationTemp = __archive-work/<UUID>.zip`; список файлов temp (без `__archive-work`); `Process`:
   - `executableURL = /usr/bin/zip`, `arguments = ["-r", destinationTemp.path] + archiveContents`, `currentDirectoryURL = tempDir`;
   - `run()` + `waitUntilExit()`; `terminationStatus != 0` → `.zipFailed(Int32)`;
   - публикация: если назначение существует — `replaceItemAt(destination, withItemAt: destinationTemp)`, иначе `moveItem`.

### 3.4 Ошибки (`ExportError`, LocalizedError)

| Кейс | Текст |
|---|---|
| `.tempDirectoryCreationFailed(underlying?)` | `Could not create temporary export directory: <msg>` / без underlying: `Could not create temporary export directory` |
| `.zipFailed(code)` | `zip exited with code <code>` |
| `.screenshotDecodeFailed` | `Could not decode screenshot data URL` |
| `.missingAudioFile(name)` | `Missing audio file for export: <name>` |

---

## 4. Flag-файл `is-recording`

### 4.1 Путь и содержимое

- Путь: `<AppSupport>/<AppName>/is-recording` (`AppState.recordingStateFlagURL()`; имя берётся из `CFBundleName`, fallback `"OmniFlow"`).
- Содержимое: строка `String(Date().timeIntervalSince1970)` — Unix timestamp (секунды, float, например `1740000000.123456`) момента СТАРТА записи. Внешние инструменты поллят файл: существует → идёт запись; устаревший timestamp → признак нечистого завершения.
- Файл существует ⟺ `isRecording == true`.

### 4.2 Запись/снятие

- `AppState.writeRecordingStateFlag(_ recording: Bool)` — static; вызывается из `didSet` `isRecording` (при `true` и при `false`) и принудительно с `false` в teardown-путях.
- `recording = true` → создать каталог при необходимости, атомарно записать timestamp (`timestamp.write(to: url, atomically: true, encoding: .utf8)`).
- `recording = false` → `removeItem`.
- Всё исполняется на выделенной serial-очереди `recordingStateFlagQueue` (`label: "com.nick8cyber.omniflow.recording-state-flag"`), чтобы дисковый I/O не тормозил старт/стоп; все ошибки глушатся (`try?`) — файл консультативный.

---

## 5. Чек-лист «что должно получиться в коде»

- [ ] `.settings` — JSON-словарь `[String:String]` в `<AppSupport>/<AppName>/`, atomic write, chmod 0600; битый файл трактуется как пустой.
- [ ] Ключи: `groq_api_key`, `api_base_url` (не хранится при пустом/дефолтном `https://api.groq.com/openai/v1`), `transcription_api_url`, `transcription_api_key` (пустые не хранятся).
- [ ] Keychain-миграция: kSecClassGenericPassword, service = bundleID, одноразово, флаг `keychain_migration_done` в самом словаре, удаление старой записи.
- [ ] `resolvedTranscriptionBaseURL/APIKey`: пустое переопределение → главное значение; используется и батч-сервисом, и realtime.
- [ ] Core Data: программная модель, контейнер `PipelineHistory`, entity `PipelineHistoryEntry` с 21 атрибутом (таблица выше), SQLite `<AppSupport>/<AppName>/PipelineHistory.sqlite`, автопересоздание с удалением `-wal`/`-shm`, in-memory fallback, `isStoreLoaded`-гейт.
- [ ] Лимит 20 записей, trim по `timestamp` desc, вытесненные WAV удаляются с диска; аудио в `<AppSupport>/<AppName>/audio/<UUID>.wav`.
- [ ] Экспорт: NSSavePanel (`omniflow-case-<ISO с заменой:>-.zip`), ZIP из case.json + screenshot.jpg/png + WAV; case.json — схема из 3.3; сборка `/usr/bin/zip -r` через Process, код возврата → `.zipFailed`; replace/move на место назначения.
- [ ] `is-recording`: путь `<AppSupport>/<AppName>/is-recording`, содержимое — Unix timestamp старта, запись/снятие на serial-очереди, ошибки глушатся.
