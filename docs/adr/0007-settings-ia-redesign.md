# ADR-0007: Редизайн настроек, меню и мастера

- Статус: accepted (2026-11-03, после интерактивного HTML-макета)
- Контекст: вкладка General — 16 карточек подряд, `SettingsView.swift` — монолит
  2154 строки, меню-бар — ~18 строк с тремя подменю пресетов, мастер — 14 шагов;
  структура повторяла историю кода, а не ментальную модель пользователя.

## Решение

1. Настройки: 7 вкладок — General, Dictation, AI Provider, Processing, Macros,
   History (+ Debug в dev); General сжат до 6 секций; UI-кит `Sources/UITheme.swift`
   (карточка с чипом, FormRow, баннеры, CopyButton, EmptyState, switch-тумблеры).
2. Меню-бар — только быстрые действия; шорткаты/словарь/мастер живут в Settings.
3. Мастер: 14 → 7 шагов (Permissions и Shortcuts собраны по одному экрану,
   Personalize объединяет необязательное).
4. Удалены мёртвые опция оверлея (ADR-0005) и Pipeline Debug-панель.

## Последствия

`SettingsView.swift` удалён, вкладки — по файлу в `Sources/Settings/`;
навигация deep-link'ами через `selectedSettingsTab` сохранена.
