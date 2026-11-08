# ADR — Architecture Decision Records

Каталог значимых архитектурных и продуктовых решений OmniFlow. Формат —
короткие иммутабельные записи (Status / Context / Decision / Consequences);
живые детали остаются в `docs/spec/*`, здесь — «почему так».

| ADR | Статус | Решение |
|---|---|---|
| [0001](0001-cleanroom-rewrite.md) | accepted | Чистовая переписка OmniFlow с нуля вместо форка FreeFlow |
| [0002](0002-gemini-live-first.md) | accepted | Live-канал включается сразу; адаптивный финиш без turnComplete |
| [0003](0003-rate-limits-fail-fast.md) | accepted | 429/4xx — fail fast, ретраи только транзиентных ошибок |
| [0004](0004-empty-recording-gate.md) | accepted | Гейт пустой записи до провайдера (длительность/речь/пик) |
| [0005](0005-overlay-single-card.md) | accepted | Один оверлей-карточка (порт OverlayForm.cs), стили удалены |
| [0006](0006-provider-fork.md) | accepted | Провайдер — явная развилка; у Gemini нет LLM-постобработки |
| [0007](0007-settings-ia-redesign.md) | accepted | Настройки: 7 вкладок, UI-кит, меню — быстрые действия, мастер 7 шагов |
| [0008](0008-branding.md) | accepted | Новая иконка «волна → текст», GitHub-промо убрано из UI |
| [0009](0009-paste-target-gate.md) | accepted | Верификация цели вставки перед Cmd+V/Ctrl+V; упавший Edit-трансформ не вставляет |

Дерево принятия решений: [decision-tree.md](decision-tree.md).

Правило: новое значимое решение → новый файл `NNNN-kebab-title.md` + строка
в индексе + ссылка из дерева. Изменение решения → новый ADR, ссылающийся на
старый (старый получает статус superseded by NNNN), история не переписывается.
