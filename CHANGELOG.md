# OmniFlow — changelog

# Changelog

All notable changes to OmniFlow are documented here.

This project uses semantic versioning for public releases. Use `MAJOR.MINOR.PATCH`, where:

- `MAJOR` changes include breaking behavior or major compatibility changes.
- `MINOR` changes add user-visible features and improvements.
- `PATCH` changes fix bugs, polish existing behavior, or make small internal improvements.

## [0.5.1] - 2026-11-08

### Fixed

- **Вставка больше не слепая (ADR-0009)**: перед Cmd+V перечитывается цель — для Edit-сессий выделение обязано совпасть с захваченным, для диктовки фронтовое приложение — с целью сессии; при несовпадении вставка отменяется, транскрипт остаётся на буфере с внятной ошибкой. Источник «каретка прыгает и стирает лишнее»: вставка стреляла через 5–45 с после захвата и съедала выделение, сделанное во время конвертации.
- **Упавший Edit-трансформ больше не вставляет старое выделение** поверх текущего — отмена вставки, текст в истории.
- **«press enter»-команда выключена по умолчанию** (случайные Enter в документах и чатах).
- Paste Again не срабатывает в живой сессии; хвостовой пробел после `.!?` — настройка (Settings → Dictation → Pasting & Audio).
- Paste-цепочка логируется (os_log, категория `Paste`): решение гейта, факты нажатий, исход рестора буфера — без текста транскрипта.

### Tests

- Realtime-сервисы вошли в тест-таргет (`GeminiLiveTranscriptionService`, `RealtimeTranscriptionService` + протокол); адаптивный финиш Live извлечён в чистую функцию `shouldFinishLiveTranscript` и покрыт 7 сьютами (`LiveFinishDecisionTests`) — минимальная задержка, settle по тишине, абсолютный кап 6 с, включительные границы.

## [0.5.0] - 2026-11-03

### Fixed (2026-11-04 audit follow-ups)

- OpenAI realtime finish capped at 6 s (the non-Gemini realtime path could hang until manual Esc on a stalled-but-open socket; empty result falls back to file transcription).
- Realtime service no longer leaks when a recording ends with no audio file.
- History retry is coordinated with live dictation (guarded, cancellable) instead of racing it.
- Paste Last Recording no longer violates Preserve Clipboard; clipboard restore ignores identical-content rewrites ("Paste Again" within the restore window pasted the wrong thing).
- Re-entrancy guard on the microphone-permission completion (double start + realtime leak); atomic realtime-sample callback hand-off; same-model suspected-instruction cleanup path per spec 11 §6.5; six dead members removed; specs 00/10/32 actualized.

### Fixed (2026-11-05)

- **Crash during dictation**: stack overflow of the Gemini Live state lane — the audio-chunk callback nested one level per streamed chunk and the 520 KB GCD thread blew up after ~240 chunks. The callback property is back to a plain stored property and nested chunk emissions are dropped.
- **Stale two-line transcript while speaking**: the overlay now ports the Windows `OverlayTextFit.FitTail` — the visible two lines always show the newest words (SwiftUI head-truncation rendered stale lines).
- **Spoken language in Live**: the setup frame now carries `inputAudioTranscription.languageCodes = ["ru"]` (Windows wire parity) — the session no longer mis-guesses the language in its opening seconds when a Spoken language is set.

### Changed

- **Новая иконка приложения**: macOS-squircle с сине-фиолетовым градиентом и мотивом «волна речи → строки текста»; dev-сборка отличается янтарным градиентом. Генератор — `Resources/generate-app-icon.swift` (иконки регенерируются `make icon`).
- **GitHub-промо убрано из UI**: шапка настроек и welcome-шаг мастера показывают только иконку/имя/версию; `GitHubMetadataCache` и связанные модели удалены.

- **Настройки переработаны**: 5 вкладок → 7 (General, Dictation, AI Provider, Processing, Macros, History, Debug — dev), монолит `SettingsView.swift` (2154 строки) разбит на `Sources/Settings/*`, общий UI-кит `Sources/UITheme.swift` (карточки с иконочными чипами, строки формы, баннеры, CopyButton, пустые состояния). General сжат с 16 карточек до 6.
- **Провайдер — первичная развилка**: явный выбор Google Gemini ⇄ Groq/OpenAI-compatible (`ai_provider`, миграция по transcription-модели). Поля, валидация ключа (Gemini — через OpenAI-совместимый эндпоинт Google) и вкладка Processing адаптируются; переключение провайдера согласует batch/live-модели. У Gemini отдельный LLM-постпроцессинг не запускается — он возвращает готовый текст (outcome `.builtInProviderCleanup`).
- **Меню-бар сокращён** с ~18 строк до 15 быстрых действий: убраны заголовок версии, три подменю пресетов шорткатов, «Paste Custom Word to Vocabulary» и «Re-run Setup…» (переехали в Settings: Dictation, Processing → Vocabulary «Add from Clipboard», General → App «Re-run…»); «Open Run Log» → «Open History», у Settings — ⌘,.
- **Мастер установки сокращён** с 14 шагов до 7: Permissions — один экран, Shortcuts — один экран, Personalize объединяет Edit Mode/словарь/логин/экран оверлея; шаг 2 — выбор провайдера с валидацией ключа по провайдеру.

### Removed

- Мёртвая опция «Minimalist menu-bar overlay» (`use_compact_overlay` писался, но никогда не читался оверлеем; ключ стирается при старте) и осиротевшая Pipeline Debug-панель (`PipelineDebugPanelView`/`PipelineDebugContentView` не открывались никем).

## [0.4.0] - 2026-11-01

### Added

- Windows-parity dictation overlay card: gradient card with an animated 5-bar equalizer, a live two-line interim transcript (newest words visible, tail-fitted), a REC badge and a "→ App" paste-destination pill; errors render the whole card red. The card sits top-center under the menu bar instead of the old notch wings/pill.
- "Paste Last Recording": when transcription fails, the recording is kept and a menu-bar item re-transcribes and pastes it; the marker clears on success so a stale recording cannot be pasted twice by accident.
- Transcription retry policy (Windows parity): three attempts per provider for transient failures only — empty output, timeouts, malformed responses, transport errors, HTTP 5xx. Rate limits (429) and other 4xx fail fast into the fallback chain.
- Microphone watchdog re-arm: the first capture session after a long device idle may open without delivering buffers; one silent re-open wakes the device before the recording is failed.

### Fixed

- Accidental hotkey taps and abandoned holds no longer wait 20-40 s for a provider error: the capture is analyzed locally against its own noise floor (seconds of sustained speech via SpeechHeuristics) — a tap, a "thought about it and decided not to speak" hold, or a cough finish as "Nothing to transcribe" in under a second, with no transcription request at all.
- Live transcript no longer duplicates itself ("раз раз проверка" appearing twice, slightly reworded): the server refines each segment by re-sending its final text in `inputTranscription` — both text fields now REPLACE the open segment exactly like the Windows build, instead of appending the refinement onto the interim it refines. `modelTurn` frames are ignored entirely.
- Audio captured before the Live handshake completes is now buffered (drop-oldest, ~10 s cap) and flushed in capture order — the server discards chunks sent during setup, which could drop the first words of a dictation.
- An empty interim frame now resets the open segment (Windows parity) instead of being dropped, so a server-side reset cannot leave stale text behind.
- Long holds no longer fail with notConnected: `turnComplete` closes the server's SPEECH TURN, not the session — the model emits it mid-dictation during tail refinement. It now only ends the commit wait when the end was already requested; otherwise the frame is ignored instead of killing the socket (which sent every long dictation to the file fallback and burned the 25-requests/day transcription tier).
- Gemini batch HTTP failures now carry the status into the retry classifier: 429/4xx fail fast instead of being retried as "transient" — the old path burned three requests per failure against the same per-minute rate limit (which is what made retry-from-menu impossible for a minute straight).
- Live diagnostics: frame-shape wire log, settle/timeout outcome, receive failures, and the exact reason a dictation fell back to file transcription.
- Dictation with empty audio no longer hangs the overlay spinner forever: `gemini-*-transcribe-live` never sends a guaranteed turnComplete (pure silence never opens a VAD turn), so the final wait is now adaptive (interim quiet 1.0 s, min 0.8 s after stream end, hard cap 6 s) and empty results finish as "Nothing to transcribe".
- Live protocol now speaks the transcribe-live dialect: interim text arrives in `interimInputTranscription` and REPLACES the current voice-activity segment — a `LiveTranscriptAccumulator` commits segments on ACTIVITY_START/END boundaries so pauses no longer lose the beginning of the dictation.
- An empty live result with audible audio now falls back to file transcription; digital silence ends immediately without provider calls.
- Equalizer animation no longer fights the main runloop: display-link driven rendering with SwiftUI-smoothed level attack/decay.
