# Аудит B — UI и пользовательские сценарии (OmniFlow, ветка rewrite)

Аудитор: B (слепой, независимый). Дата: 2026-09-24.
Объект: `/Users/surja/Projects/OmniFlow` (Sources/, ветка rewrite).
Эталон: `docs/spec/30-ui.md`, `docs/spec/00-architecture.md`, `docs/spec/23-shortcuts.md` (§9 — захват).
Референс старой версии: `/Users/surja/Projects/freeflow` (только чтение, для сравнения регрессий).
Код не запускался и не изменялся; все выводы — из чтения исходников со ссылками на строки.

---

## 1. Методология

1. Прочитаны спеки 30-ui (целиком), 00-architecture (целиком), 23-shortcuts §9 (захват) и построчно — все UI-файлы: `SetupView.swift`, `SettingsView.swift`, `MenuBarView.swift`, `RecordingOverlay.swift`, `ShortcutComponents.swift`, `ModelDropdownView.swift`, `PipelineDebugContentView.swift`, `PipelineDebugPanelView.swift`, `App.swift`, `AppDelegate.swift`, а также поведенческое ядро `AppState.swift` (все 2596 строк), `AudioRecorder.swift`, `TranscriptionService.swift`, `SetupTestHotkeyHarness.swift`, `TestCaseExporter.swift`, `UpdateManager.swift` (диалоги и напоминания), `PostProcessingService.swift` (пути кулдаунов), `AppState+AddVocabularyButton.swift`.
2. По каждому сценарию из ТЗ (онбординг → диктовка → настройки → Edit Mode → меню → границы) восстановлена цепочка «действие → код → что видит пользователь», с проверкой гейтинга, таймеров поллинга и путей выхода из ошибок.
3. Регрессии относительно `/Users/surja/Projects/freeflow` помечены явно (файл:строка референса).
4. Тексты сверены между Setup / Settings / ошибками / меню и со старой версией;grep по `FreeFlow` в `Sources/` — 0 совпадений (остатков старого имени нет).

Оценки: **P0** — пользователь застревает/теряет текст; **P1** — путаница или нерабочий сценарий; **P2** — шероховатость UX; **P3** — полировка.

---

## 2. Находки

### P0

#### P0-1. Мастер Setup: шаг «Screen Recording» — жёсткий тупик («Granted» показано, Continue заблокирован навсегда)

- **Где:** `Sources/SetupView.swift:393-396` (поллинг), `SetupView.swift:1127-1134` (гейтинг Continue), `SetupView.swift:667-679` (карточка шага); `Sources/AppState.swift:484` (инициализация), `AppState.swift:2369-2375` (обновление свойства).
- **Сценарий воспроизведения:** свежая установка. Пользователь доходит до шага 4 (Screen Recording) и выдаёт разрешение вручную через System Settings (либо кликает «Grant Access», в системном диалоге выбирает «Open System Settings» и включает тумблер там), не дожидаясь завершения колбэка `SCShareableContent`.
- **Что происходит:** локальный таймер раз в 1 с обновляет **локальный** `@State screenRecordingGranted = appState.hasScreenCapturePermission()` (`SetupView.swift:395`) — карточка переключается на зелёную «Granted», кнопка исчезает. Но Continue гейтится на **другое** состояние — `appState.hasScreenRecordingPermission` (`SetupView.swift:1133-1134`), которое поллинг не обновляет. Во время Setup никаких других обновляющих путей нет (2-секундный поллинг AppState стартует только после `completeSetup`, `AppDelegate.swift:69-70`). Итог: интерфейс сообщает «Granted», кнопки действия нет, Continue неактивен — шаг непроходим до перезапуска приложения (при старте `AppState.init` префлайтит заново, `AppState.swift:484`).
- **Что должно:** отображение и гейтинг должны читаться из одного источника; выданное разрешение разблокирует Continue немедленно.
- **Фикс:** в `.onReceive(screenPollTimer)` писать `appState.hasScreenRecordingPermission = appState.hasScreenCapturePermission()` (как это делала старая версия — `freeflow/Sources/SetupView.swift:1208-1218`), либо гейтить Continue на тот же `screenRecordingGranted`. Это **регрессия относительно референса**: старый мастер обновлял именно свойство AppState.

---

### P1

#### P1-1. Первый запуск: закрытие окна Setup крестом оставляет глобальные шорткаты мёртвыми — молча

- **Где:** `Sources/AppDelegate.swift:20-31` (`applicationDidFinishLaunching`), `AppDelegate.swift:79-105` (`handleShowSetup`).
- **Сценарий:** первый запуск, пользователь закрывает мастер крестом (шаги разрешений пугают, откладывают «на потом»).
- **Что происходит:** `applicationDidFinishLaunching` при `!hasCompletedSetup` вызывает только `showSetupWindow()` — `startHotkeyMonitoring()` / `startAccessibilityPolling()` / `UpdateManager` не стартуют. Восстановление при закрытии окна (bail-restore observer) навешивается **только** для повторного прохождения (`guard wasCompleted`, `AppDelegate.swift:92`); для первого запуска пути нет. Приложение живёт как `.regular` без окон, меню-бар пишет «Hold Fn or tap Fn+Cmd to dictate» (`AppState.shortcutStatusText`), но нажатия ничего не делают — event tap не установлен. Пользователь не получает никакого сигнала, почему «не работает».
- **Что должно:** либо стартовать мониторинг и при незавершённом setup (глобальные шорткаты не требуют завершения онбординга), либо при закрытии первого мастера показывать подсказку/повторно открывать мастер.
- **Фикс:** в `willCloseNotification` при `!wasCompleted` сделать то же, что в bail-restore (старт мониторинга/поллинга, `.accessory`), и/или показывать алерт «Setup is not finished — dictation shortcuts are disabled until you complete Setup».

#### P1-2. Шаг API Key: сетевая ошибка/недоступность провайдера выдаёт «Validation failed… check your API key»

- **Где:** `Sources/SetupView.swift:1200-1219` (`validateAndContinue`), `Sources/TranscriptionService.swift:114-127` (`validateAPIKey`).
- **Сценарий:** онбординг без интернета / каптивный портал / GitHub-like блокировка провайдера; пользователь вставляет корректный ключ и жмёт Continue.
- **Что происходит:** `validateAPIKey` сваливает **все** неудачи (таймаут, DNS, 429, 5xx, 401) в `false`, и Setup показывает ровно один текст: «Validation failed. Please check your API key and provider settings, then try again.» (`SetupView.swift:1215`). Пользователя с лежащей сетью направляют чинить исправный ключ; продолжить мастер он не может (шаг обязателен).
- **Что должно:** различать «ключ неверный (401/403)» и «провайдер недоступен — проверьте сеть» (в основном конвейере это уже сделано: `AppState.formattedTranscriptionError`, `AppState.swift:1863-1889`, и `friendlyHTTPMessage`, `TranscriptionService.swift:129-149`).
- **Фикс:** вернуть из `validateAPIKey` причину (статус/ошибку) и показать соответствующий текст; при сетевой ошибке разрешить «Continue offline» с предупреждением.

#### P1-3. Шаг «Microphone Access» не поллит разрешение: после выдачи в System Settings Continue остаётся заблокирован

- **Где:** `Sources/SetupView.swift:458-466` (`initialize`, статус читается один раз), `SetupView.swift:389-396` (поллятся только accessibility и screen recording), `SetupView.swift:640-651` (обновление только через кнопку).
- **Сценарий:** пользователь на шаге 2 кликает «Grant Access», в системном диалоге отвечает отказом (приложение само открывает System Settings — `AppState.requestMicrophoneAccess`, `AppState.swift:2354-2363`), затем включает доступ тумблером в System Settings.
- **Что происходит:** `micPermissionGranted` остаётся `false`; поллинга нет; Continue неактивен. Выход есть, но неочевиден — ещё раз нажать «Grant Access» (тогда `AVCaptureDevice.requestAccess` вернёт `authorized` мгновенно). На шаге нет ни подсказки «I've enabled it — check again», ни реакции на фактический статус.
- **Что должно:** шаг реагирует на выдачу разрешения из System Settings (как шаг Accessibility — там поллинг 1 c есть и работает корректно).
- **Фикс:** добавить третий поллинг-таймер `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized` (по образцу `accessibilityPollTimer`), либо на `onReceive` общего тика. (В старой версии то же ограничение — не регрессия, но в rewrite, где поллинг уже есть для двух других шагов, смотрится как недоделка.)

#### P1-4. «Paste Custom Word to Vocabulary» может быть молча отменён черновиком окна Settings

- **Где:** `Sources/SettingsView.swift:106-110, 156-170` (драфт из appState на `onAppear`), `SettingsView.swift:639-659` (`commitVocabulary` на `onDisappear`); `Sources/AppState+AddVocabularyButton.swift` (внешний писатель `customVocabulary`); `Sources/MenuBarView.swift:83-87`.
- **Сценарий:** открыты Settings → General (в `customVocabularyDraft` загружен текущий словарь). Пользователь копирует слово в чужом приложении и через меню-бар жмёт «Paste Custom Word to Vocabulary» — `appState.customVocabulary` дополняется, в статус-баре вспыхивает галочка. Затем пользователь возвращается в Settings и переключает вкладку (или закрывает окно).
- **Что происходит:** `GeneralSettingsView.onDisappear → commitVocabulary()` пишет в `appState.customVocabulary` **устаревший** драфт — добавленное слово бесследно исчезает. Успешное действие пользователя отменяется побочным эффектом другого окна без каких-либо сообщений.
- **Что должно:** коммит на `onDisappear` не должен откатывать внешние изменения; либо драфт должен синхронизироваться с `appState.customVocabulary` (как это сделано для моделей и transcription-полей через `onChange`, `SettingsView.swift:986-994`).
- **Фикс:** добавить `.onChange(of: appState.customVocabulary) { if !focused → customVocabularyDraft = $0 }` или коммитить только при реальном редактировании (флаг «dirty»).

---

### P2

#### P2-1. Тест-прогон в Setup: рекордер без `onRecordingFailure` — «Listening...» висит до ручного стопа

- **Где:** `Sources/SetupView.swift:1017-1035` (`startTestRecording` — подписка только на `$audioLevel`), сравни: `freeflow/Sources/SetupView.swift:1228-1240` (старая версия подписывалась и переводила тест в `done` с ошибкой).
- **Сценарий:** на шаге «Let's Try It Out!» микрофон отцепляют / capture-сессия падает (watchdog `noAudioBuffersReceived`, `AudioRecorder.swift:392-419`) во время записи.
- **Что происходит:** `onRecordingFailure` рекордера никем не установлен — фаза остаётся `.recording` с плоской волной; пользователь видит «Listening...» без конца. Спасение — вручную нажать toggle-стоп, тогда `stopRecording` вернёт nil и появится «No audio file was created.» (`SetupView.swift:1042-1050`).
- **Что должно:** ошибка записи сразу переводит тест в `done` с текстом ошибки.
- **Фикс:** вернуть `recorder.onRecordingFailure = { … testError = …; testPhase = .done }` (регрессия).

#### P2-2. Кастомная модель: мусор/пустая строка принимаются молча, выстреливают HTTP 400 во время диктовки

- **Где:** `Sources/ModelDropdownView.swift:48-57` (TextField, commit без валидации), `Sources/SettingsView.swift:847-893` (`onCommit: { appState.X = normalized(draft) }`, `normalized` = trim, `SettingsView.swift:1001-1003`).
- **Сценарий:** пользователь выбирает «Custom...», стирает содержимое или вводит «gpt-99», кликает мимо поля.
- **Что происходит:** пустая строка сохраняется в `post_processing_model`/`transcription_model` и т.д.; UI продолжает показывать «Custom...» с пустым полем; после переоткрытия Settings пикер вообще отображает пустой selection. Ошибка всплывает только при следующей диктовке тостом «Provider rejected the request (HTTP 400). Check your model name and Base URL in Settings.» — далеко от места ошибки.
- **Что должно:** пустой ввод отклоняется/возвращается к дефолту на месте; нестандартный id — предупреждение «will be sent as-is».
- **Фикс:** в `commit` при пустом значении вызывать `onReset()`; при вводе вне predefined показывать caption «Custom model ID — used verbatim in API requests».

#### P2-3. Кулдаун обеих LLM-моделей — «Post-processing succeeded» с сырым текстом и без единого сигнала

- **Где:** `Sources/PostProcessingService.swift:314-318` (circuit breaker возвращает raw с результатом-успехом), `Sources/AppState.swift:194-195` (статус `.postProcessingSucceeded`), `AppState.swift:1496-1501` (следовательно — без красного X).
- **Сценарий:** дневной лимит Groq исчерпан (обе модели в кулдауне), пользователь диктует.
- **Что происходит:** пост-обработка пропускается, вставляется сырой транскрипт («emm, so like…»), Run Log пишет «Post-processing succeeded», оверлей просто исчезает. Предупреждение о кулдауне существует только в Settings → Advanced Provider Settings (`SettingsView.swift:857-871`) — в момент диктовки пользователь не понимает, почему очистка «сломалась».
- **Что должно:** хотя бы красный X-индикатор / отдельный статус «Skipped post-processing — daily limit», как это сделано для `.postProcessingFailedFallback`.
- **Фикс:** возвращать из circuit-breaker пути отдельный outcome (например `.postProcessingSkippedCooldown`) и обрабатывать его в `completeTranscription` через `scheduleOverlayDismissAfterFailureIndicator`.

#### P2-4. Run Log: «Clear History» удаляет 20 прогонов и все аудиофайлы без подтверждения

- **Где:** `Sources/SettingsView.swift:1603-1606`; `AppState.clearPipelineHistory` (`AppState.swift:2171-2178`) удаляет и аудио.
- **Сценарий:** пользователь хочет удалить одну запись, но промахивается по «Clear History» (кнопка в хедере рядом со списком).
- **Что происходит:** мгновенное необратимое удаление всей истории и аудио; undo нет.
- **Что должно:** confirmation dialog для деструктивного массового действия.
- **Фикс:** `.confirmationDialog("Delete all N runs and their audio?")` перед `clearPipelineHistory()`.

#### P2-5. Плеер Run Log молча не реагирует на битое/удалённое аудио

- **Где:** `Sources/SettingsView.swift:1996-2016` (`play()` — `catch { // Playback is best-effort }`).
- **Сценарий:** файл истории удалён вручную/антивирусом, либо WAV повреждён; пользователь жмёт play.
- **Что происходит:** ничего — ни ошибки, ни изменения состояния; кнопка выглядит сломанной.
- **Что должно:** сообщение «Audio file is missing or unreadable» и/или скрытие плеера при отсутствии файла.
- **Фикс:** в `catch` выставлять `@State playError` и показывать `Label`; при `onAppear` проверять `FileManager.fileExists`.

#### P2-6. Экспорт test case падает целиком из-за опционального артефакта (скриншот)

- **Где:** `Sources/TestCaseExporter.swift:92-100` (`guard let data = decodeDataURL(...) else { throw .screenshotDecodeFailed }`).
- **Сценарий:** у записи есть `contextScreenshotDataURL`, но base64 обрезан/бит; пользователь жмёт Export.
- **Что происходит:** весь экспорт отменяется с «Could not decode screenshot data URL», хотя case.json и аудио в порядке.
- **Что должно:** скриншот — опциональная часть; экспорт продолжается без него, статус остаётся в case.json (`screenshot_status` уже сохраняется).
- **Фикс:** заменить `throw` на пропуск секции с записью `"screenshot_decode_failed"` в pipeline.

#### P2-7. Ошибки теста транскрипции в Setup — сырой `localizedDescription`, несовместимый с основным конвейером

- **Где:** `Sources/SetupView.swift:1022, 1058` (`testError = error.localizedDescription`).
- **Сценарий:** на шаге теста рвётся сеть / таймаут 20 с (`TranscriptionError.transcriptionTimedOut` → «Transcription timed out after 20s» — терпимо), но URLError даёт «A server with the specified hostname could not be found.» и т.п.
- **Что происходит:** в мастере — технический текст, тогда как основная диктовка в той же ситуации покажет аккуратное «No internet — check connection» (`AppState.swift:1863-1889`). Разнобой терминов в первый час использования.
- **Что должно:** единый user-facing маппинг ошибок.
- **Фикс:** сделать `AppState.formattedTranscriptionError` доступным (static) и использовать в Setup-тесте.

#### P2-8. Лента «recent stargazers» показывает первых (старейших) звёздящихся, не последних

- **Где:** `Sources/SetupView.swift:93-104` (жёстко `page=1`, затем `records.reversed().prefix(15)`).
- **Сценарий:** у репозитория >100 звёзд; открывается Setup/Settings.
- **Что происходит:** запрашивается первая страница (первые 100 звёзд за всю историю) и берутся 15 с её конца — т.е. звёздящие №86–100, а не свежие. Спека 30-ui §9.5 прямо требует «последняя страница `stargazers?per_page=100&page=<last>`».
- **Что должно:** аватары последних звёздящихся.
- **Фикс:** прочитать `last_page` из заголовка `Link` и запросить её (или брать `page=<ceil(count/100)>` после fetch repo info).

#### P2-9. Retry в Run Log: молчаный отказ при невалидном Transcription API URL и копирование без уведомления

- **Где:** `Sources/AppState.swift:2212-2219` (`try makeTranscriptionService()` → catch → `retryingItemIDs.remove; return` — без `errorMessage`), `AppState.swift:2283-2287` (успех кладёт текст в клипборд без какого-либо подтверждения).
- **Сценарий:** пользователь ввёл мусор в «Transcription API URL»; жмёт retry у ошибочной записи.
- **Что происходит:** спиннер мигнёт и исчезнет — ни ошибки, ни результата; при успехе — клипборд меняется без единого сигнала (пользователь мог держать в буфере важное).
- **Что должно:** ошибка сервиса — в `errorMessage`/алерт; успех — вспышка/статус.
- **Фикс:** в catch ставить `errorMessage = …`; при успехе переиспользовать паттерн «Copied to clipboard!».

---

### P3

#### P3-1. `statusText` — state «в никуда»: «Pasted at cursor!», «Nothing to transcribe», «Pressed Enter» не видны нигде
`Sources/MenuBarView.swift:149-170` — статусная строка меню показывает `shortcutStatusText`/`debugStatusMessage`, но не `statusText`; grep по всем UI-файлам — ни одного чтения `statusText`. Пустая диктовка и «press enter» не имеют видимого отклика (оверлей просто исчезает). Унаследовано от референса (там так же) и соответствует спеке 30 §3.4, но сам факт: ~15 тщательно написанных строк статуса — write-only. Фикс: показывать краткий `statusText` в статусной строке меню в idle-состоянии, либо удалить поле.

#### P3-2. `PipelineDebugPanelView` и `toggleDebugPanel` — мёртвый код
`Sources/PipelineDebugPanelView.swift` (весь файл) не инстанцируется нигде; `AppState.toggleDebugPanel` (`AppState.swift:2515-2518`) не вызывается. Живой debug-панели из спеки 30 §6.10 в dev-сборке не открыть (Debug-вкладка даёт только оверлей-симуляцию). Унаследовано от старой версии (там тоже мёртвый). Фикс: встроить панель в Debug-вкладку или удалить.

#### P3-3. Кнопка «Paste Custom Word to Vocabulary» без обратной связи при «нечего добавлять»
`Sources/MenuBarView.swift:83-87`: `pasteWordToVocabulary()` возвращает nil (пустой клипборд / всё уже в словаре) — ни галочки, ни сообщения. Пользователь не отличает «сработало» от «нет». Фикс: невидимая причина хотя бы в `errorMessage`/всплеск иконки.

#### P3-4. Permissions-карточка в Settings: микрофон не перепроверяется
`Sources/SettingsView.swift:172-174, 684-687` — `checkMicPermission()` только на `onAppear`; выдал доступ в System Settings при открытом окне — строка так и показывает «Grant Access». Для Accessibility/Screen Recording updates приходят (общий поллинг AppState после setup). Фикс: тот же 2-секундный тик или `onReceive` на `AVCaptureDevice` authorization change.

#### P3-5. Цифрово-тихий микрофон: `onRecordingReady` не срабатывает, «Starting...» и точки инициализации бесконечно
`Sources/AudioRecorder.swift:510-518` — ready только при `rms > 0`. Виртуальные/заглушённые устройства, выдающие цифровой ноль, дают: watchdog «healthy» (буферы идут), оверлей с точками инициализации навсегда, статус «Starting...». Стоп работает — тупика нет, но диагностика для пользователя отсутствует. Фикс: считать ready по первому буферу (или 1 c тикеру), а не по rms.

#### P3-6. Смена шортката во время hold-записи останавливает запись
`Sources/AppState.swift:316-324` (`didSet` → `restartHotkeyMonitoring`) → `GlobalShortcutBackend.stop()` шлёт `backendReset` → матчер эмитит `holdDeactivated` → `.stop` → стоп и вставка. Редкий, но неожиданный побочный эффект правки настроек «на живую». Фикс: при `isRecording` откладывать restart хоткеев до конца сессии.

#### P3-7. Утечка block-based observer при повторных «Re-run Setup…»
`Sources/AppDelegate.swift:93-104` — observer на `willCloseNotification` добавляется на каждый re-run и никогда не снимается (накапливается по числу открытий мастера). Фикс: хранить токен и снимать, либо использовать `NotificationCenter.removeObserver(token)` в самом блоке.

#### P3-8. Два экземпляра приложения (OmniFlow + OmniFlow Dev) не защищены
Нет single-instance лока: две копии ставят по event tap (оба глотают Fn — шорткаты «двоят»), делят файл `is-recording` и AppSettings. Reopen обрабатывает лишь повторный launch того же бандла. Фикс: проверка другого инстанса при старте (например, по флаг-файлу с PID) + сообщение.

#### P3-9. «Show menu bar icon» OFF при закрытых окнах делает приложение недостижимым до перезапуска бандла
`Sources/App.swift:10-17` + `Info.plist LSUIElement`: Dock-иконки нет, меню-барной нет; Settings изнутри не открыть. Спека допускает (опция задумана), но подсказки «как вернуть» нет (например, « reopening the app from Finder opens Settings» — `applicationShouldHandleReopen` это покрывает, но пользователь не знает). Фикс: caption под тогглом.

#### P3-10. `prepareRecordingStart` дёргает `requestScreenCapturePermission()` (SCShareableContent) на КАЖДОЙ command-mode диктовке
`Sources/AppState.swift:986-996` — после успешного префлайта вызывается `requestScreenCapturePermission()`, т.е. перечисление всего shareable-контента на каждый Edit Mode старт. Не ломает UX, но лишняя работа и отложенное обновление `hasScreenRecordingPermission`. Фикс: вызывать только если `!CGPreflightScreenCaptureAccess()`.

#### P3-11. Алерт о нехватке Screen Recording для Edit Mode — однократный за запуск
`Sources/AppState.swift:2411-2413` (latch `hasShownScreenshotPermissionAlert`), сброс только в `beginRecording` (`AppState.swift:1163`), куда при отказе путь не доходит. Повторные попытки: только Basso + красный текст, спрятанный в меню-баре (`MenuBarView.swift:68-75`); оверлея нет (запись не начиналась). Фикс: показывать тост/алерт на каждую неудачу, либо сбрасывать latch в reject-пути.

#### P3-12. Edit Mode (manual) без выделенного текста: только звук Basso
`Sources/AppState.swift:1056-1066` — `errorMessage`/`statusText` выставляются, но видны только в раскрытом меню-баре (`MenuBarView.swift:68-75`); оверлей не появляется. Ошибка всплывает при открытом меню, а пользователь в этот момент печатает в чужом приложении. Фикс: короткий тост оверлеем (механизм `showError` уже есть и не требует сессии записи).

---

## 3. Пройденные сценарии и ОК

- **Порядок и состав 14 шагов Setup** — точно по спеке 30 §7.1 (`SetupView.swift:314-318`); индикатор из 14 точек; Back с клампом в welcome; `onDisappear` гасит таймеры и снимает захват (`SetupView.swift:374-379`).
- **Гейтинг Continue**: apiKey (непустой ввод, блокировка на время валидации), vocabulary (сохраняет trim), testTranscription (плюс доступный **Skip** — тупика нет), ready — соответствует спеке; шаги разрешений гейтятся (см. находки P0-1/P1-3 по источникам состояния).
- **Поллинг accessibility** в Setup работает: 1 c, `AXIsProcessTrusted()`, старт/стоп привязаны к появлению шага.
- **Захват шорткатов** (`ShortcutComponents.swift` + `LocalShortcutCaptureBackend`): голые модификаторы, Enter 36/76 и Esc с pending — подтверждение, Esc без pending — запись «Esc», повторы отсечены, глобальный мониторинг ставится на паузу через `suspendHotkeyMonitoringForShortcutCapture`/`resume…` и в `onChange` трёх флагов, и в `onDisappear`. Конфликтные тексты `setShortcut` — дословно по спеке 23 §5.2 (`AppState.swift:809-850`).
- **Диктовка hold/toggle**: FSM-переходы (hold→toggle latch, armed stop), отложенный старт с `shortcutStartDelay`, Esc-отмена toggle-сессии и транскрипции — по спеке 23 §4 (`AppState.swift:854-944`, `cancelToggleShortcutSession`/`cancelTranscription` полностью расчищают состояние: оверлей, флаг-файл, аудио, mute, `disableAutomaticTermination`).
- **Тупиков оверлея не найдено**: `AudioRecorder.stopRecording` гарантированно вызывает completion (sessionQueue → main, `AudioRecorder.swift:171-189`); тост ошибки 6 c с токеном `toastID` не задевает новые тосты (`RecordingOverlay.swift:103-129`); `dismissAll` демонтирует SwiftUI-иерархию перед `close()` (нет вечных spinners). Быстрый старт/стоп <0.5 c: пустой файл → «No audio recorded» (тост), нет буферов 2 c → watchdog-ошибка — состояние всегда возвращается в idle.
- **Ошибки диктовки**: 401 → «Invalid API key for … Open Settings to fix it.», 429/413/5xx, сеть → «No internet — check connection» с учётом `NetworkMonitor.isOnline`; fallback пост-обработки вставляет сырой текст и показывает красный X 2.5 c. Транскрипт бутстрапится в `lastTranscript` до пост-обработки — Paste Again работает даже при падении LLM (`AppState.swift:1404-1407`).
- **«press enter»**: regex по спеке, удаление команды, Enter после paste с задержкой 0.08; при пустом тексте — только Enter. Cmd+V через `UCKeyTranslate` с фолбэком 9 — раскладко-независимо (`AppState.swift:2050-2098`).
- **Клипборд**: transient/concealed-маркеры (4 шт), опция plain-режима, хвостовой пробел после `.!?`, восстановление по changeCount/тексту с задержкой 1 c — по спеке 00 §4.9.
- **Оверлей**: интерактивность только stop-кнопка (recording+toggle) и update-баннер; выбор дисплея 0/−1/>0 с фолбэком; winged-геометрия по нотчу; блокировка ширины на transcribing; сон во время записи обрабатывается (`wasInterrupted` ставит watchdog на паузу, `interruptionEnded` перезапускает — `AudioRecorder.swift:323-341`).
- **Settings — применение без перезапуска**: все ключевые настройки идут через `didSet` с persist и побочными эффектами (`restartHotkeyMonitoring`, `rebuildContextService`); ни один контрол не требует рестарта, об этом честно и не приходится писать. Cooldown-предупреждения читаются из UserDefaults с 5-секундным тиком. Draft-поля провайдера синхронизируются снаружи, пока не в фокусе.
- **Edit Mode automatic** без выделения — тихо падает в обычную диктовку (лучший из сценариев); **manual** с коллизией модификатора — валидация красным прямо в Settings/Setup (`commandModeManualModifierValidationMessage`).
- **Меню-бар**: состояние иконки (record/ellipsis/waveform + checkmark 2 c + dev-штамп), баннеры разрешений orange/red, History ≤10 с фильтром пустых и сниппетом 48, «Paste Again  (…)» с двумя пробелами,disabled-пункты пресетов по конфликтам, mic-подменю, Quit ⌘Q — всё по спеке 30 §3.
- **Обновления**: авто-чек не раньше 3-дневного stability buffer; «Skip This Version» гасит баннер и напоминания; напоминание после диктовки — раз в 24 ч на версию, клик по оверлею открывает Settings + алерт; «Remind Me Later» подавляет напоминание. Модальные алерты — только по явному действию пользователя.
- **Run Log**: retry — только для ошибочных записей с аудио, со спиннером по `retryingItemIDs`; пустая история — заглушки и disabled-кнопки; three-step pipeline с Show/Hide Prompt; FlowLayout-чипы словаря; время `m:ss / m:ss`.
- **Тексты**: EN везде, опечаток не найдено; `FreeFlow` в `Sources/` — 0 вхождений; терминология («dictation», «Edit Mode», «Paste Again», «Run Log») согласована между Setup/Settings/меню/ошибками.
- **Тема и локализация**: все цвета семантические (`controlBackgroundColor`, `.secondary`, accent) либо осознанно чёрно-белые в оверлее-«нотче»; строк локализации нет — по спеке («не локализуются»); activation policy `.regular` на окнах / `.accessory` после закрытия; reopen без окон открывает Settings.
- **Приватность**: транскрипты и скриншоты уходят только в настроенный провайдер; история локальна (Core Data + аудио в AppSupport); в меню/логах контент не дублируется наружу (os_log — метаданные, тела запросов с `%private}`).

---

## 4. Итоговая сводка

| Приоритет | Кол-во | Ключевое |
|---|---|---|
| P0 | 1 | Тупик на шаге Screen Recording в онбординге (UI «Granted», Continue мёртв) — регрессия |
| P1 | 4 | Закрытие первого мастера убивает шорткаты молча; «Validation failed» при сетевой ошибке; mic-шаг без поллинга; откат словаря черновиком Settings |
| P2 | 9 | Висящий тест-прогон, мусорные кастомные модели, безмолвный кулдаун, Clear History без подтверждения, плеер/экспорт/рендер ошибок, лента звёзд |
| P3 | 12 | Невидимый `statusText`, мёртвая Debug-панель, отсутствие фидбеков, latch-алерты, конкурентные инстансы и пр. |

Ядро диктовки (FSM шорткатов, оверлей, конвейер транскрипции/пост-обработки, клипборд, отмены, сон/пробуждение) реализовано плотно по спекам, тупиков и потерянного текста в основном конвейере не обнаружено. Основной риск первого контакта сосредоточен в онбординге — именно там обе самые серьёзные находки, и обе лечатся точечно (синхронизация источника состояния гейта и bail-restore для первого запуска).

### Топ-5 проблем, которые пользователь заметит в первый час

1. **P0-1** — на шаге Screen Recording мастер показывает «Granted», но Continue навсегда неактивен (выдача разрешения через System Settings); спасает только перезапуск приложения и повторное прохождение мастера.
2. **P1-1** — закрыл окно Setup на первом запуске → шорткаты молча не работают, хотя меню-бар уверенно пишет «Hold Fn or tap Fn+Cmd to dictate».
3. **P1-2** — при проблемах с сетью мастер требует «check your API key», хотя ключ верный; продолжить онбординг нельзя.
4. **P1-3** — выдал доступ к микрофону через System Settings на шаге 2 — Continue не реагирует; непонятно, что нужно ещё раз нажать «Grant Access».
5. **P2-2/P2-3** — первый же эксперимент с кастомной моделью или упор в дневной лимит Groq оборачивается диктовкой без очистки/HTTP 400 без объяснения в момент ошибки.
