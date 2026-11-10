# ADR-0006: Провайдер — первичная развилка (Gemini ⇄ OpenAI-compatible)

- Статус: accepted (2026-11-03; уточнён ADR-0010: пропуск LLM-cleanup —
  только в режиме транскрипции `smart`, при `verbatim` cleanup OmniFlow
  работает; пункты ниже про «у Gemini нет LLM-постобработки» читать в этой
  оговорке)
- Контекст: выбор провайдера был неявным (по имени модели), поля API свалены в
  одну кучу; для Gemini отдельный LLM-постпроцессинг избыточен — модель возвращает
  готовый чистый текст, а лишний запрос ест 20k TPM (см. ADR-0003).

## Решение

- Явная настройка `ai_provider`: `gemini` | `openAICompatible` (карточки в
  Settings → AI Provider и в шаге 2 мастера); первичная миграция по
  `transcription_model`.
- Поля, валидация ключа (Gemini — через OpenAI-совместимый эндпоинт Google
  `generativelanguage.googleapis.com/v1beta/openai`) и состав вкладки Processing
  зависят от провайдера: Cleanup/System Prompt/Safety — только OpenAI-compatible.
- Пайплайн: `AIProvider.skipsLLMCleanup` — у Gemini LLM-cleanup не запускается,
  outcome `.builtInProviderCleanup`; макросы не затронуты.
- LLM-зависимые пути (Edit Mode, перевод Output language, контекст) идут через
  OpenAI-совместимый эндпоинт Google (`geminiValidationBaseURL`) с тем же
  ключом; модели постобработки/контекста согласуются при смене провайдера
  (`adjustedLLMModel`, дефолт `gemini-3.5-flash-lite`; устаревшие
  `gemini-2.x` id при запуске мигрируют на него — Google с 01.12.2026
  роутит `gemini-2.5-flash` на `gemini-3.5-flash-lite`).
- Переключение провайдера согласует модели (`adjustedBatchModel` /
  `adjustedLiveModel`), live-модель при уходе с Gemini сбрасывается в дефолт.

## Последствия

Минус один LLM-запрос на каждую диктовку; UI показывает только осмысленные поля.
Windows-версия: семантика развилки нативна с самого начала (cleanup — опция
только Groq-режима); 2026-11-04 страница настроек переименована в соответствие
с мак-IA (Windows 0.5.1, вин-репо `691d987`, см. parity-таблицу в
`windows/README.md`).
