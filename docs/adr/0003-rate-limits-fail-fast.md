# ADR-0003: Лимиты провайдера — fail fast

- Статус: accepted (2026-11-02, ревизия после живого 429-лога)
- Контекст: реальность лимитов Gemini — двойная: транскрипционные модели
  25 запросов/день (Free Tier, сброс ~11:00), остальные — 20 000 токенов/мин.
  Ретраи с аудио при 429 сжигали дневную квоту и растягивали ошибку на минуты.

## Решение

- `transcribeWithRetries` (3 попытки) — только транзиентные ошибки:
  emptyTranscript, таймауты, 5xx/URL errors, transcriptionFailed.
- 429/4xx, invalidBaseURL, audioPreparationFailed, Cancellation — fail fast.
- Оба HTTP-бранча бросают `.httpStatus(status, message)` — статус не прячется
  в строке.
- `LLMCooldownManager` гасит повторные удары по охлаждённой модели
  (заголовки 429 → cooldown), UI показывает «Daily limit — resets at HH:mm».
- Компенсация отказа — «Paste Last Recording» (аудио сохраняется, перегон
  одним пунктом меню/вкладки History).

## Последствия

Честная быстрая ошибка вместо 20–40 с ожидания; квота не сжигается ретраями.
