# Аудит A — бизнес-логика и код OmniFlow (ветка rewrite)

**Дата:** 2026-09-24. **Аудитор:** A (независимый, слепой).
**Объект:** `/Users/surja/Projects/OmniFlow` — `Sources/` (~14.7k строк Swift), `Tests/`, `Makefile`.
**Эталон:** `docs/spec/00–33`. **Референс для семантического паритета:** `/Users/surja/Projects/freeflow` (только чтение).

## Методология

1. Полное чтение спек 00/01/10/11/12/20/22/23/31/32 (+ точечные выверки 21/30).
2. Построчное чтение всех файлов бизнес-слоёв: `AppState.swift` (2596 строк, целиком), `TranscriptionService`, `GeminiTranscription`, `RealtimeTranscriptionService`, `GeminiLiveTranscription(+Service)`, `PostProcessingService`, `TranscriptTextCore`, `LLMCooldownManager`, `LLMAPITransport`, `ModelConfiguration`, `AudioRecorder`, `LiveAudioLevelNormalizer`, `ShortcutCore/*`, `ShortcutBinding`, `HotkeyManager`, `GlobalShortcutBackend`, `LocalShortcutCaptureBackend`, `ModifierKeyEventState`, `KeychainStorage`, `PipelineHistoryStore/Item`, `UpdateManager`, `SemanticVersion`, `AppContextService` (конвейер контекста), `SystemAudioStatus`, `NetworkMonitor`, `AppDelegate`, `AppState+AddVocabularyButton`.
3. Проверка таймаут-гонок и continuation-путей вручную (двойной resume / утечки), жизненного цикла WebSocket-лупов, конвертеров аудио, Core Data-схемы, bash-инъекций апдейтера.
4. Точечная сверка дивергенций с freeflow (по grep/чтению соответствующих участков).
5. Прогон тестового раннера: `make test` → компиляция с `-warnings-as-errors`, stdout `OmniFlowTests passed` (все 8 сюитов).

Код во время аудита не изменялся (единственная запись — `mkdir audit`; `make test` пишет только `build/OmniFlowTests`).

---

## Находки

### P0 — нет

Ни одной находки уровня «ломает диктовку/данные» не зафиксировано.

### P1

**A-1. Command mode включён по умолчанию — свежая установка молча превращает диктовку в «Edit Mode» над выделенным текстом.**
- `Sources/AppState.swift:558`
- Доказательство (код): `isCommandModeEnabled = UserDefaults.standard.object(forKey: "command_mode_enabled") as? Bool ?? true`
- Ожидаемое: спека 00 §2.2 — ключ `command_mode_enabled`, дефолт **`false`**; freeflow `Sources/AppState.swift:678-680` — `object(forKey:) == nil ? false : bool(forKey:)`.
- Последствия: при дефолтном стиле `.automatic` любой dictation-старт при наличии выделенного текста резолвится в `.command(.automatic)` (`resolveSessionIntent`, AppState.swift:1017-1022) — LLM **заменяет выделенный текст пользователя** вместо вставки надиктованного. Для чистого профиля это меняет семантику главного сценария (hold-диктовка) и является деструктивным (перезапись selection).
- Фикс: `?? false` в AppState.swift:558 (или осознанно обновить спеку, если смена дефолта была продуктовым решением — но тогда она должна быть зафиксирована в 00-architecture).

**A-2. Отмена загрузки обновления не работает: после Cancel скачивание продолжается и приложение само себя заменяет и перезапускает.**
- `Sources/UpdateManager.swift:644-652` (цикл скачивания в `Task.detached`), `:550-555` (`cancelDownload`), `:594-609` (ветки `CancellationError`/`URLError.cancelled`)
- Доказательство (код): `activeDownloadTask = Task { await self?.performUpdate(...) }`, внутри `performUpdate` — `try await downloadToFile(...)`, а скачивание идёт в **unstructured** `Task.detached { ... }.value`. `cancelDownload()` вызывает `activeDownloadTask?.cancel()`, но отмена внешней Task **не распространяется** на detached-задачу; ни `performUpdate`, ни `downloadToFile` не проверяют `Task.isCancelled`. Ветви `catch is CancellationError` / `URLError.cancelled` — недостижимы из `cancelDownload`.
- Ожидаемое: спека 31 §7.2 — «CancellationError / URLError.cancelled → тихо удалить temp-каталог, статус не трогать»; §7.1 — «отменить активную задачу (`activeDownloadTask?.cancel()`)». Спека однозначна: отмена должна останавливать процесс.
- Последствия: пользователь нажал Cancel → UI показывает `idle`, но загрузка и монтаж DMG продолжаются → `.readyToRelaunch` → `replaceAndRelaunch` → `NSApp.terminate(nil)`. Приложение внезапно закрывается и обновляется «само».
- Фикс: передавать отмену внутрь — например, хранить `downloadTask: Task<Void, Never>` (сам detached) и отменять именно его; либо заменить `Task.detached` на `group.addTask` внутри той же Task, либо в цикле добавить `try Task.checkCancellation()` и в `performUpdate` после каждого `await` проверять `Task.isCancelled` с выходом в тихую ветку. Аналогичный дефект есть в freeflow (там же `Task.detached` + `try Task.checkCancellation()` внутри, который тоже не срабатывает) — по спеке требует правки в обеих.

### P2

**A-3. Дефолт ручного модификатора Edit Mode — Cmd вместо Option.**
- `Sources/AppState.swift:560`
- Доказательство (код): `commandModeManualModifier = CommandModeManualModifier(rawValue: ...) ?? .command`
- Ожидаемое: спека 00 §2.2 — дефолт `.option`; freeflow `Sources/AppState.swift:684-686` — `?? .option`.
- Последствия: (а) в Settings по умолчанию отображается «Cmd ⌘» вместо «Option ⌥»; (б) при переключении стиля в Manual сигнатура «зажать модификатор поверх hold-шортката» меняется: `pendingManualCommandInvocation`/`permittedAdditionalExactMatchModifiers` начинают использовать `.command` (AppState.swift:717-719, 885-886, 953-954). С дефолтным toggle `Fn+Cmd` это создаёт путаницу: Cmd, прижатый для Edit Mode, — тот же модификатор, что в дефолтном toggle-биндинге.
- Фикс: `?? .option`.

**A-4. Retry записи затирает клипборд пустой строкой, если повторный прогон дал пустой текст.**
- `Sources/AppState.swift:2283-2287` (`finishRetry`)
- Доказательство (код):
  ```swift
  lastTranscript = trimmedFinal
  lastPostProcessingStatus = processingStatus
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  pasteboard.setString(trimmedFinal, forType: .string)
  ```
  Безусловно, при любом `trimmedFinal`, включая `""`.
- Ожидаемое: freeflow (retry-комплит, Sources/AppState.swift ≈1265-1270): `if !trimmedRetryTranscript.isEmpty { lastTranscript = …; NSPasteboard.general.clearContents(); … }` — пустой результат не трогает ни `lastTranscript`, ни буфер. Спека 00 §2.11 фиксирует только факт plain-write, но референс однозначен.
- Последствия: retry «пустой» записи уничтожает текущее содержимое буфера обмена пользователя (пустая строка), и Paste Again теряет прежний `lastTranscript`.
- Фикс: обернуть три строки в `guard !trimmedFinal.isEmpty else { … }` (обновление истории оставить безусловным).

---

### P3 (edge-cases / техдолг с риском)

**A-5. `resolvedTranscriptionBaseURL` возвращает нетриммированный override и подставляет дефолтный Groq при пустых значениях.**
- `Sources/AppState.swift:1841-1847`
- Код: `if !transcriptionAPIURL.trimmed.isEmpty { return transcriptionAPIURL }` (нетриммированный!); далее `base.isEmpty ? Self.defaultAPIBaseURL : base`.
- Ожидаемое: спека 22 §1.5 и freeflow: `return trimmed.isEmpty ? apiBaseURL : trimmed` — trim, без подмены на дефолт (пустой URL → `TranscriptionError.invalidBaseURL("Provider URL is empty.")`).
- Эффект: при полностью пустых настройках OmniFlow молча уйдёт на `https://api.groq.com/openai/v1` вместо внятной ошибки «Provider URL is empty». Мягче по UX, но расходится со спекой и прячет ошибку конфигурации.

**A-6. В историю и `lastRawTranscript` попадает сырой транскрипт с хвостом «press enter», хотя freeflow сохраняет текст после вырезания команды.**
- `Sources/AppState.swift:1462` (`lastRawTranscript = rawTranscript`), `:1471` (`rawTranscript: rawTranscript` в `recordPipelineHistoryEntry`).
- Референс: freeflow сохраняет `parsedTranscript.transcript` (уже без press-enter-хвоста) и в `lastRawTranscript`, и в историю. OmniFlow — unparsed raw.
- Эффект: только отображение в Run Log / экспорт кейса; retry корректно переразбирает строку заново. Верdict — divergence, низкий риск.

**A-7. `finishRetry`/`retryItemFailed` глушат ошибки Core Data (`try? pipelineHistoryStore.update`).**
- `Sources/AppState.swift:2281, 2314`. Freeflow оборачивает в `do/catch` с `errorMessage = "Failed to save retry result: …"`.
- Эффект: при ошибке сохранения UI покажет «Retried»/«Retry failed» как успешно записанные, хотя история не изменилась. Silent-failure техдолг.

**A-8. Лишний `requestScreenCapturePermission()` при каждом command-старте.**
- `Sources/AppState.swift:996`: после успешного `CGPreflightScreenCaptureAccess()` безусловно вызывается `requestScreenCapturePermission()` (`SCShareableContent.getExcludingDesktopWindows`) — полномасштабное перечисление окон на каждый Edit Mode-старт.
- Ожидаемое: спека 00 §2.7 / freeflow `ensureScreenCaptureAccess()` — только preflight + `hasScreenRecordingPermission = granted`; никакого request на горячем пути. Здесь безвредно (при отсутствии права ветка уже отсечена guard'ом выше), но лишний системный вызов в latency-критичном пути старта.

**A-9. `startRecording` логирует абсолютное время как длительность.**
- `Sources/AppState.swift:950-951`: `os_log("Starting recording after %.0f ms", …, CFAbsoluteTimeGetCurrent() * 1000)` — это Unix-эпоха в мс, а не «после X мс». Спека 00 §2.7 упоминает os_log-замеры `CFAbsoluteTimeGetCurrent`; freeflow логирует дельту от `startedAt`. Косметика наблюдаемости.

**A-10. Gemini Live: теоретический двойной resume + сокет живёт дольше нужного; `closeSocket` — мёртвый код.**
- `Sources/GeminiLiveTranscriptionService.swift:103-106`: если `audioStreamEndMessage()` не соберётся, `continuation.resume(throwing:)` выполняется, но `finalContinuation` остаётся в состоянии → пришедший позже `turnComplete` сделает второй `resume` (краш). Практически недостижимо (JSONSerialization на литерале не падает), но паттерн хрупкий — снимать continuation из состояния до resume.
- `:250-258` `closeSocket(_:)` не вызывается нигде; после успешного финала сокет закрывается только `defer { activeRealtime?.cancel() }` в transcriptionTask — т.е. после пост-обработки (до ~20 с простаивающего открытого WSS).

**A-11. Порядок снятия типов pasteboard-снапшота расходится со спекой/референсом.**
- `Sources/AppState.swift:81-88` (`PreservedPasteboardItem.init`): string → **data → propertyList**; спека 00 §4.9 и freeflow (AppState.swift:81-87): string → **propertyList → data**.
- Эффект нейтральный или лучший: типы, читаемые и как data, и как plist, восстанавливаются исходными байтами (`setData`) — lossless. Дивергенция без ущерба.

**A-12. `AppSettingsStorage` — read-modify-write без синхронизации.**
- `Sources/KeychainStorage.swift:12-28`: `load/save/delete` каждый раз перечитывают файл и перезаписывают; два конкурентных вызова потеряют обновление. Сегодня все вызывающие на main-очереди (AppState didSet/init), поэтому риск теоретический; но API статический и публичный для всего модуля. Рекомендация: serial queue или lock вокруг чтения-записи. Мелочь: миграция сохраняет значение в словарь нетриммированным (`dictionary[account] = value`, проверка на `trimmed`, KeychainStorage.swift:69-71).

**A-13. Восстановление повреждённого стора истории осиротляет WAV-файлы.**
- `Sources/PipelineHistoryStore.swift:52-58`: при неудаче загрузки файлы `.sqlite/-wal/-shm` удаляются, история стирается, но `audio/<UUID>.wav` остаются на диске без записей-владельцев (чистятся только trim/clear/delete). Накопительный мусор при повторных повреждениях. Фикс: перед destroy собрать `audioFileName` и удалить файлы.

**A-14. `transcriptionAPIURL` didSet проверяет пустоту без trim.**
- `Sources/AppState.swift:285`: `if transcriptionAPIURL.isEmpty` — значение из одних пробелов будет сохранено в `.settings` (в отличие от `apiBaseURL`, где trim есть, :274-280). На резолв не влияет (там trim), но хранит мусор в секретном файле и маскирует «пустое» значение в UI.

**A-15. Тестовая компоновка тянет AppKit-файл.**
- `Makefile:13-27` `TEST_PRODUCTION_SOURCES` включает `Sources/UpdateManager.swift` (import AppKit) ради `SemanticVersion`. Спека 32 §1.3: «тесты не тянут AppKit/SwiftUI-слой». На macOS-раннере работает, но связность тестов с GUI-слоем лишняя; `SemanticVersion` стоило бы вынести в отдельный файл.

---

## Проверено и ОК

Полный конвейер и подсистемы, по которым найдено соответствие спеке и/или референсу (цитируемые проверки сделаны по коду, не по тестам):

**Тайминги/константы (00 §2.1)** — все сверены в коде: 0.03 / 0.08 / 1.0 / 20 записей / 7 с напоминание / 24×25 мс / 0.2 c init-таймер / 3 с и 2 с сбросы статуса / 2.5 c failure-indicator / 6 c error-toast (90 символов, токен) / 20 c таймауты с override-ключами / 10 c validateAPIKey / watchdog 2.0 c / log limit 40 / WAV 16 kГц Int16 mono / realtime 24 000 / history 20 / 4096+«low» для дефолтной LLM / 3600 с и 60 с кулдауны / 3 дня stability / 7 дней автопроверка / 24 ч reminder / 5 c первая проверка + timer 3600±300 / 1000 терминов Gemini / 0.1 no_speech порог / все 13 констант нормализатора / 500 000 символов data URL / температура 0.2 контекста. Список языков — ровно перечисленные в спеке пары (заголовочное «31 пара» в спеке off-by-one, код соответствует перечислению).

**FSM и триггеры** — `DictationShortcutSessionController`: полный граф 23 §4.1 (в т.ч. `toggleStopArmed`, `switchedToToggle`, блокировка при `isTranscribing`); `handleShortcutEvent` (00 §2.5) — copyAgain до контроллера, `.stop`-ветка, pending-toggle; Esc-семантика (keyCode 53, без repeat; глотается при транскрипции и toggle-сессии, иначе проходит); `toggleRecording`, stop-кнопка оверлея.

**Интенты command mode** — `resolveSessionIntent` по 00 §2.6 (автомат: непустой trim-выделенный; ручной: биндинг-модификатор → dictation, коллизия → reject c текстами из спеки, нет выделения → reject, тексты `"Select text to transform first"` / `"Fix Edit Mode modifier"`, Basso, сброс 2 c); `SessionIntent.fromPersisted` (command-интенты только с непустым selectedText).

**Старт/стоп записи** — порядок 00 §2.7–2.8: AX → intent → screen-capture preflight → mic-permission (notDetermined: подготовка, рестарт мониторинга, .toggle-возобновление / hold-сообщение 2 c) → mute-логика (`previouslyMuted`) → `disableAutomaticTermination` с флагом → flag-файл из `isRecording.didSet` → init-таймер 0.2 c → onRecordingReady/OnFailure → realtime → контекст; stop: фиксация интента/контекста/in-flight задачи (без отмены), last*-чистка, `saveAudioFile` до транскрипции, повторный guard `isTranscribing`, bootstrap `lastTranscript` после транскрипции (00 §2.8 п.10).

**Отмены** — `cancelToggleShortcutSession` и `cancelTranscription` по 00 §2.9 (включая удаление файла текущего прогона, restore mute, сбросы статуса 2 c matching `["Cancelled"]`); `handleRecordingFailure` — полная расчистка (колбэки, realtime, cleanup, mute restore, isRecording/isTranscribing=false, удаление аудио, тексты `formattedRecordingStartError`).

**Realtime-роутинг** — матрица 10 §7.2 (live-модель → Gemini Live; batch-Gemini в transcriptionModel → стриминг скип; пустой base → скип; иначе OpenAI realtime); ошибка старта → без realtime; `resolveRawTranscript`: строгий порядок «сначала realtime, при любой ошибке кроме CancellationError → файловый POST»; санитарные проверки (`activeRealtime`, `onPCM16Samples = nil`, `defer cancel`).

**Вставка** — regex press-enter `(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$` и парсер по 00 §4.7; хвостовой пробел после `.!?`; 4 transient-маркера с пустыми строками + declared types; plain-режим `keepDictationInClipboardHistory`; restore по `changeCount` ИЛИ совпадению строки через 1.0 c; poll 25 мс × ≤24 + 0.03; Cmd+V через UCKeyTranslate c fallback 9; Enter = 36; 0.08 до Enter. `statusText`-реестр и matching-сбросы — по 00 §2.4.

**Таймаут-гонка `TranscriptionService`** — `TranscriptionTimeoutRaceState` выверен вручную: все порядки `setContinuation/finish/register` под NSLock, `pendingResult` для досрочной отмены, `finished`-гейт; двойной resume и утечка continuation невозможны; `URLError.timedOut` → `transcriptionTimedOut`; multipart-порядок model→response_format→(language)→file, boundary UUID, content-type таблица, `response_format` (3 модели verbose_json), нормализация base URL, friendlyHTTPMessage дословно, Gemini-подмена хоста и Interactions-вызов (`x-goog-api-key`, failureMessage двух форм, error-конверты при HTTP 200, status != completed, join `model_output`, empty → ошибка).

**OpenAI Realtime** — deriveWebSocketURL (ws/wss, /v1-хвост, `intent=transcription` без дублей); `session.update` (rate 24000, `turn_detection: NSNull`, model/language условно); append base64, commit однократно, финал-детекция `commitSent && partialText.isEmpty && postCommitCompleted` с `serverEventCount/commitEventCount`; delta/completed/committed/error-таблица 10 §5.6; `finishWithClose` отдаёт финал при закрытии после completed; cancel идемпотентен; receive-loop завершается после `task = nil` (нет «вечернего лупа» и retain-цикла: Task создан с `[weak self]`, сильная ссылка живёт только пока цикл активен).

**Gemini Live** — socketURL (фоллбек не-Google хоста, дроп query — секрет не протекает), `x-goog-api-key`, setup `models/`+`SMART`+опциональный `custom_vocabulary`, audioStreamEnd, парсер фреймов (error/setupComplete/inputTranscription|modelTurn/turnComplete|generationComplete), commit/streamEnded/notConnected/terminalError семантика 10 §6.5-6.8, «Could not connect to Gemini live transcription…» до setupComplete, cancel `.goingAway`.

**Пост-обработка** — три системных промпта и user-шаблоны дословно (включая `<<<RAW_TRANSCRIPTION`-маркеры, нетриммированные аргументы в command-шаблоне — как в спеке 11 §3.2); payload и условные параметры (4096/«low»/false для дефолта) — по 11 §4.4; 429 → `rateLimitCooldown`+`setCooldown(persist:)`+`.rateLimited` (в cleanup и command; в translate — нет); fallback-матрицы (cleanup: rateLimited/429/empty/suspected; command: rateLimited/429/empty; translate: 429/empty, без circuit breaker и без записи кулдаунов); обе модели в кулдауне → raw/selectedText без запроса; instruction guard — маркеры (21 слово), stopWords, preamble-regex, вердикт `(preamble && !rawPreamble) || (preservedMarkers.isEmpty && overlap < 0.35)`, только cleanup, только при пустом Output Language; task-group таймаут; `LLMAPITransport` — ephemeral per request, no cache, таймауты с фолбэком 60, `finishTasksAndInvalidate`.

**Кулдауны** — actor; память + UserDefaults `llm_cooldown_expiry_<model>`, удаление просроченных; порог 3600/persist; `effectivePrimary`; приоритет заголовков RPD → retry-after → reset-tokens → 60; парсер длительностей (`ms`-юнит целостной строкой, `"1h30"` → nil, nan/inf/отрицательные → nil).

**Санитайзеры/парсеры** — `postProcessedTranscript` (кавычки+EMPTY→""), `verbatimTranslation` (EMPTY сохраняется), `commandModeTranscript` (trim), галлюцинации Whisper (10 фраз, `no_speech_prob >= 0.1` по `segments.first`, отсутствие метаданных → пропуск фильтра), plain-text fallback, `stripThinkTags` (два якорённых regex), таблица `ModelConfiguration` (4096/low у gpt-oss-20b; none/false/strip у qwen3.6-27b; strip у qwen3-32b; алиасы).

**Аудио** — `makeSession` порядок 1–14 (гонки с первым буфером нет: guard `recordingFlag` закрывается после `tempFileURL` в том же sync-блоке); два конвертера под отдельными локами с пересозданием по смене входного формата; WAV-валидность = frames>0 и нет ошибки записи; дренаж `sampleBufferQueue.sync` перед финализацией; watchdog (baseline, заморозка при interrupted, одноразовый); interruption/runtimeError-ветки; atomic `reportRecordingFailure` (один раз, temp-удаление, main-колбэки); rms-формулы Float32/64/Int16/Int32; `onRecordingReady` один раз по rms>0; re-entrancy через DispatchSpecificKey (cleanup/deinit/ошибка старта); устройства: DiscoverySession по ОС, дедуп по uniqueID, сортировка по имени, `"default"`→`AVCaptureDevice.default`→первый.

**Хранилища** — `.settings` 0600 atomic, битый JSON → `[:]`, ключи и правила удаления (`api_base_url` при дефолте не хранится), Keychain-миграция одним флагом `keychain_migration_done` в самом словаре + SecItemDelete; Core Data: программная модель, entity `PipelineHistoryEntry`, 21 атрибут с точной optionality/default, sync-загрузка (semaphore+lock), recovery (sqlite/-wal/-shm) → in-memory fallback, `isStoreLoaded`-гейт, `update()` не трогает timestamp/скриншот/аудио, trim/clear возвращают имена аудио и AppState удаляет файлы; лимит 20.

**Шорткаты** — OptionSet-биты, Codable как Int; таблицы keycodes (модификаторы/спец/F1–F20); `id`, `specificityScore`, `withAddedModifiers`, `normalizedForStorageMigration`; exact-match по группам-синонимам с `permittedAdditionalExactMatchModifiers`; редьюсер: consume before||after, snapshot-consume при событиях, repeat не меняет состояние, copyAgain leading edge, backendReset всегда passthrough, сортировка активаций/деактиваций; конфликты перебором 2^9 + равный specificity; тексты `setShortcut` и command-коллизий дословно; CGEventTap: session/headInsert/defaultTap, main run loop, авто-re-enable с `notifyBackendReset` и пере-read Fn, keyDown/keyUp = snapshot+keyChanged с OR-consume, Esc 53; `HotkeyManager` фасад (сброс inputState при ошибке старта); `LocalShortcutCaptureBackend` всегда `return nil`, сидирование Fn, `allowBareModifier`-логика в UI-слое; `suspend/resumeHotkeyMonitoring` гвард `shouldMonitorHotkeys && !isCapturingShortcut && !isAwaitingMicrophonePermission`; `ModifierKeyEventState` NX-маски + доверенный Fn.

**Системное** — `SystemAudioStatus` (mute/volume, `kAudioObjectPropertyElementMain`, «ошибка чтения = не muted»); `NetworkMonitor` (default true, идемпотентный start из AppDelegate первой строкой); `SystemAudioStatus` mute-restore на всех путях выхода из записи; flag-файл: серийная очередь, float-timestamp, удаление при false, сброс в init/deinit (crash-путей утечки нет: единственный способ оставить флаг — падение процесса, что и есть его контракт); `pasteWordToVocabulary` по 00 §4.12; `AppDelegate` lifecycle (setup 520×680, settings 780×540, reopen, restore при bail-out визарда); UpdateManager: semver-сравнение, 404→«up to date», агрегированные notes, skip только в авто-проверке, reminder-условия §5, диалоги, bash-подмена строго argv-массивом (инъекций нет), hdiutil attach -plist / detach в defer; `SemanticVersion` — все негативные кейсы и prerelease-порядок.

**Тесты** — `make test` зелёный; 8 сюитов соответствуют спеке 32 (SemanticVersion 4, ShortcutCore 13, TranscriptTextCore 8, ModelConfiguration 4, AppContextService 5, GeminiTranscription 6, GeminiLive 5, LLMCooldownManager 4); чистое ядро без сети.

---

## Дивергенции от референса (freeflow)

| # | Место | Расхождение | Вердикт |
|---|---|---|---|
| D1 | AppState.swift:558 | `command_mode_enabled` дефолт **true**; спека и freeflow — **false** | **Требует правки** (P1, A-1) |
| D2 | AppState.swift:560 | `command_mode_manual_modifier` дефолт **.command**; спека и freeflow — **.option** | **Требует правки** (P2, A-3) |
| D3 | UpdateManager.swift:644 | Отмена скачивания не работает — дефект **общий с freeflow**; спека 31 §7.2 однозначна | **Требует правки по спеке** (P1, A-2) |
| D4 | AppState.swift:1841-1847 | `resolvedTranscriptionBaseURL`: нетриммированный override + подмена пустого на дефолт Groq; freeflow/спека — trim и без подмены | Правка желательна (P3, A-5); текущее поведение мягче, но прячет ошибку конфигурации |
| D5 | AppState.swift:1462,1471 | В историю/`lastRawTranscript` идёт unparsed raw (с press-enter хвостом); freeflow — после вырезания | Допустимо, зафиксировать выбор (P3, A-6) |
| D6 | AppState.swift:2281,2314 | `try?` на store.update в retry; freeflow — do/catch с errorMessage | Правка желательна (P3, A-7) |
| D7 | AppState.swift:2283-2287 | retry пишет клипборд даже при пустом результате; freeflow — `guard !isEmpty` | **Требует правки** (P2, A-4) |
| D8 | AppState.swift:81-88 | Порядок снапшота типов string→data→plist; freeflow — string→plist→data | Ок по сути (lossless data), расходится с текстом спеки (P3, A-11) |
| D9 | AppState.swift:996 | `requestScreenCapturePermission()` на каждом command-старте; freeflow/spec — нет | Ок, но лишняя работа на горячем пути (P3, A-8) |
| D10 | AppState.swift:1716-1721 | В `resolveRawTranscript` нет повторного `checkCancellation` после ошибки realtime перед fallback (в freeflow есть) | Эквивалентно по эффекту: cancel-путь даёт CancellationError из самого бэкенда, а fallback-транскрипция сама бросает CancellationError при отмене. Ок |

---

## Итоговая сводка

| Приоритет | Кол-во |
|---|---|
| P0 | 0 |
| P1 | 2 (A-1 дефолт command mode; A-2 отмена обновления) |
| P2 | 2 (A-3 дефолт manual-модификатора; A-4 retry затирает клипборд) |
| P3 | 11 (A-5…A-15) |

**Чего не хватает в тестах (критичное):** (1) press-enter парсер (`parseTranscriptCommands`) — private в AppState и не покрыт, хотя это парсинг пользовательского ввода с regex; (2) fallback-матрица пост-обработки (`runCleanupPath/runCommandPath/runTranslatePath`) — не извлечена в чистые функции, а это самая рискованная логика ретраев; (3) actor-поведение `LLMCooldownManager` (`setCooldown`/`effectivePrimary`/persist) — протестирован только статический парсер заголовков; (4) `LiveAudioLevelNormalizer` — не покрыт вовсе, при том что спека 01 §10 заявывает его как покрытый (противоречие со списком 8 сюитов в спеке 32); (5) `TranscriptionTimeoutRaceState` — гонка не тестируема в текущей компоновке; (6) `PipelineHistoryStore`/`AppSettingsStorage` (можно покрыть in-memory store и временным каталогом). Существующие 45 тестов добротны, но закрывают «лёгкую» половину: парсеры и чистые редьюсеры.

**Оценка готовности к рантайм-тесту:** готов — с двумя оговорками. Инженерно код в хорошей форме: конвейер соответствует спеке, гонки continuation и WebSocket-лупы выверены, краш-пути чистят состояние (запись/флаги/аудио/mute), тесты зелёные. Перед рантайм-тестом стоит внести два однострочных фикса P1/P2 по дефолтам (`command_mode_enabled=false`, `manual modifier=.option`) и A-4 — иначе первые же сценарии «диктовка при выделенном тексте» и «retry пустой записи» дадут ложные дефекты, а поведение будет расходиться со спекой на чистом профиле. Фикс отмены обновления (A-2) можно вести параллельно — он не блокирует диктовку, но является реальным P1 по спеке 31.
