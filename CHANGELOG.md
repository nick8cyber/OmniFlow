# OmniFlow — changelog

> OmniFlow — форк-продолжение FreeFlow (MIT, © Zach Latta и контрибьюторы).
> Записи ниже вплоть до 1.2.1 — унаследованная история апстрима.

# Changelog

All notable changes to FreeFlow are documented here.

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

## [1.2.1] - 2026-08-11

### Improved

- Model pickers now show only currently supported Groq options, with context models limited to those that can analyze screenshots.

### Fixed

- Fixed typing lag in custom vocabulary and prompt editors by saving changes when editing finishes instead of after every keystroke.

## [1.2.0] - 2026-07-14

### Added

- A Preserve exact wording option that skips transcript cleanup while still supporting literal translation, voice macros, and Edit Mode.
- An instruction guard that retries or falls back to the literal transcript when cleanup appears to answer a dictated prompt instead of preserving it.
- An option to keep dictations in clipboard-manager history.
- A menu bar action for adding copied words directly to the custom vocabulary while avoiding duplicates.

### Improved

- Post-processing now switches to the fallback model immediately when the primary model is rate-limited, remembers daily limits across restarts, and shows their reset times in Settings.
- The default fallback model now uses Qwen 3.6 27B, and models scheduled for Groq shutdown in July or August 2026 have been removed from the picker.
- Transcription failures now distinguish network outages from slow providers and display clearer errors in the recording overlay.
- The default context model now uses Qwen 3.6 27B and strips reasoning tags from context summaries.
- Local model requests now honor their configured timeouts, and transcription uses response formats compatible with a wider range of OpenAI-style models.
- Permission and update checks use fewer unnecessary background wakeups.

### Fixed

- Fixed a recording overlay resource leak that could leave hidden animations running after the overlay closed.

## [1.1.0] - 2026-06-03

### Added

- Model pickers in Settings for post-processing, fallback, context, and transcription models, including Qwen 3 32B and custom model entries.
- A recording overlay display picker for choosing the active window, primary display, or a specific connected monitor.
- In-pill error notifications so transient failures such as network or provider errors are visible without opening logs.
- Advanced timeout overrides for local model and slow network setups.

### Improved

- Retried dictations now place the successful transcript on the clipboard and update Paste Again.
- Paste Again now preserves the latest raw transcript earlier in the dictation flow, so it remains useful if later cleanup or pasting fails.
- Post-processing handles reasoning-oriented model output more cleanly, including Qwen thinking tags and providerless model aliases.

### Fixed

- Fixed cases where transcription could hang indefinitely when a provider accepted a connection but never returned a response.
- Fixed false screen-recording permission alerts from unrelated permission messages.
- Fixed duplicate in-pill error notifications being dismissed by an older timer.

## [1.0.0] - 2026-05-20

FreeFlow is now considered feature-complete and stable enough for a 1.0 release.

### Added

- Paste Again shortcut for re-pasting the most recent dictation.
- Recent transcript history in the menu bar, with copy actions for quickly reusing previous dictations.
- Run Log copy controls for both literal and cleaned transcript output.
- Menu bar actions for opening the Run Log and checking for updates.
- Debug settings for troubleshooting overlays and update prompts.
- A polished drag-to-Applications DMG background for installer builds.

### Improved

- Recording feedback now uses a cleaner minimalist menu-bar overlay, with clearer command-mode state.
- Transcribing and processing feedback appears sooner and more consistently after recording stops.
- Shortcut labels now use friendlier modifier names alongside symbols.
- Setup and recovery flows are more resilient when restoring app state.
- Sentence-ending dictations now paste with trailing spacing that better matches normal writing.
- Development builds and main-branch release automation are easier to identify and validate.

### Fixed

- Fixed shortcut collision checks for edit mode and manual modifier bindings.
- Fixed cases where dictation could terminate automatically while still in progress.
- Fixed clipboard restoration after dictation when the original clipboard content is unchanged.
- Marked transient dictation clipboard contents so clipboard managers can avoid saving them.
- Preserved spoken instructions verbatim during post-processing.
- Simplified transcription submission errors into clearer one-line messages.

## [0.3.3] - 2026-04-25

### Added

- Output Language setting for automatically translating dictated text before it is pasted.
- Transcription Language setting for choosing the language FreeFlow listens for during dictation.
- Recording state flag file for external tools that need to know when FreeFlow is actively recording.
- Distinct FreeFlow Dev app and menu bar icons so development builds are easier to tell apart from release builds.

### Improved

- Permission prompts and setup screens now use the correct app name for the installed build.
- Release notes in update prompts now render changelog formatting more clearly.
- Development builds now have clearer bundle naming and icon handling.

### Fixed

- Fixed audio recording crashes caused by unexpected input formats, resampling, and upload-path conversion.
- Fixed cases where FreeFlow could silently fall back when the selected microphone was unavailable.
- Fixed paste shortcuts on Colemak-DH and other non-QWERTY keyboard layouts.
- Fixed output language handling when custom system prompts are enabled.

## [0.3.2] - 2026-04-23

### Fixed

- Removed the pause-based audio interruption mode that could misfire and resume playback unexpectedly; dictation now only mutes audio.

## [0.3.1] - 2026-04-23

### Added

- Faster live dictation with realtime transcription support.
- A setting for choosing the realtime transcription model.
- Run log exports, so you can save a full dictation run for debugging or sharing.
- A Copy Transcript action in the run log.
- A voice command for submitting text: say "press enter" at the end of a dictation.
- Audio controls that can mute or pause other audio while you dictate, then restore it when recording stops.
- Build details in Settings for easier troubleshooting.
- Direct shortcuts from FreeFlow to the right macOS permission settings.
- A What’s New popup when an update is available.

### Improved

- Recording feedback now feels more responsive.
- The run log is easier to scan and use.
- Exported run logs include more useful context for reproducing issues.
- Realtime transcription is more reliable when recordings are cancelled, retried, or finish with no text.
- Provider settings are easier to edit without accidental whitespace or half-saved values.
- FreeFlow now warns you if alert sounds may be hard to hear because system audio is muted or very low.
- Update prompts now show the version, release date, and release notes more clearly.
- FreeFlow now uses proper version numbers for updates instead of internal build names.

### Fixed

- Fixed cases where arrow or navigation keys could be mistaken for Fn shortcut input.
- Fixed a clipboard timing issue that could paste the wrong content.
- Fixed empty realtime transcriptions getting stuck instead of finishing cleanly.
- Fixed waveform glitches caused by invalid audio levels.
- Filtered out more common transcription artifacts.
- Fixed alert sound hints staying visible after alert sounds are turned off.
- Fixed update checks so users only see real app releases, not internal builds.
- Fixed update checks so the app does not offer an older or already-installed version.
