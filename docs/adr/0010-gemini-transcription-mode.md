# ADR-0010: Режим транскрипции Gemini — настраиваемый smart/verbatim

- Статус: accepted (2026-11-11)
- Контекст: ADR-0006 вывел Gemini из второго LLM-cleanup — smart-режим Gemini
  сам чистит текст. Но smart иногда слишком агрессивно переписывает диктовку
  (резолвит самоисправления, меняет формулировки), и у пользователя не было
  способа получить дословный транскрипт: `mode` был константой `"SMART"` в
  Live и `"smart"` в Interactions API. Просто отдать verbatim без cleanup —
  регресс: сырой текст с филлерами пошёл бы прямо в буфер, ведь
  `skipsLLMCleanup` глушил OmniFlow-cleanup для любого Gemini.

## Решение

- `enum GeminiTranscriptionMode: String` (`smart` | `verbatim`) в
  `Sources/AIProvider.swift`; wire-значения: `batchWireValue` — нижний регистр
  (`smart`/`verbatim`) для `generation_config.transcription_config.mode.type`,
  `liveWireValue` — верхний (`SMART`/`VERBATIM`) для
  `inputAudioTranscription.mode` сетап-фрейма Live.
- Настройка `gemini_transcription_mode` в UserDefaults, дефолт `"smart"` —
  поведение существующих установок не меняется; segmented-пикер в
  Settings → AI Provider (Gemini-карточка).
- `AIProvider.skipsLLMCleanup(geminiTranscriptionMode:)` возвращает true
  только у Gemini + smart. При verbatim дословный транскрипт проходит обычный
  пайплайн OmniFlow (макросы → preserve → LLM-cleanup с системным промптом и
  guard, спека 11), который настраивается на вкладке Processing — карточки
  cleanup/prompts/safety при verbatim показываются.
- Параметр `mode` проброшен: `GeminiLiveTranscription.setupMessage` ←
  `GeminiLiveTranscriptionService.Configuration.transcriptionMode` ← AppState;
  `GeminiTranscription.requestBody` ← `TranscriptionService` ← AppState.
- Диаризация/таймстемпы verbatim-режима в Live **не используются**: Live API
  их не поддерживает ни в одном режиме; в батчe не поднимаем — out of scope.

## Последствия

- Smart остаётся дефолтом и единственным режимом без дополнительного
  LLM-запроса. Verbatim добавляет один cleanup-запрос на диктовку (как у
  OpenAI-compatible) — цена точности формулировок.
- У verbatim-текста сохраняется полная семантика диктовки; дальнейшая
  степень чистки управляется системным промптом OmniFlow, а не решением
  Gemini на стороне транскрибации.
- Спеки 10 (§4.5, §6.3), 11 (§11), 30 (§6.3–6.5, §10), 32 (§3, §8d)
  обновлены; ADR-0006 уточнён — пропуск cleanup относится к smart-режиму.
