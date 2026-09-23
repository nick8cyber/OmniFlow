# Спецификация 23 — Шорткаты: модель, матчер, FSM-сессия, глобальный/локальный бэкенды, системные датчики

Референс: `Sources/ShortcutCore/ShortcutModels.swift`, `Sources/ShortcutCore/ShortcutMatcher.swift`, `Sources/ShortcutCore/DictationShortcutSessionController.swift`, `Sources/ShortcutBinding.swift`, `Sources/HotkeyManager.swift`, `Sources/GlobalShortcutBackend.swift`, `Sources/LocalShortcutCaptureBackend.swift`, `Sources/ModifierKeyEventState.swift`, `Sources/SystemAudioStatus.swift`, `Sources/NetworkMonitor.swift`. Хранение и конфликты: `Sources/AppState.swift`.

Архитектурный принцип: **матчер — чистый редьюсер** (без I/O), бэкенды превращают ОС-события в `ShortcutInputEvent`, контроллер сессии превращает `ShortcutEvent` в действия записи. Это позволяет тестировать логику без эвентов (см. `32-tests.md`, `SetupTestHotkeyHarness.swift`).

---

## 1. Типы модели

### 1.1 `ShortcutModifiers` — OptionSet

```swift
struct ShortcutModifiers: OptionSet, Hashable, Codable { let rawValue: Int }
```

| Бит | Статик | Логическая клавиша |
|---|---|---|
| `1 << 0` | `.command` | Cmd ⌘ |
| `1 << 1` | `.control` | Ctrl ⌃ |
| `1 << 2` | `.option` | Option ⌥ |
| `1 << 3` | `.shift` | Shift ⇧ |
| `1 << 4` | `.function` | Fn 🌐 |

Codable — кодируется как голый `Int` (singleValueContainer, собственные init(from:)/encode(to:)).

`orderedDisplayNames: [String]` — в фиксированном порядке при наличии: `"Cmd ⌘"`, `"Ctrl ⌃"`, `"Option ⌥"`, `"Shift ⇧"`, `"Fn 🌐"`.

Расширение в `ShortcutBinding.swift`: `init(eventFlags: NSEvent.ModifierFlags)` — копирует command/control/option/shift/function.

### 1.2 Перечисления

```swift
enum ShortcutBindingKind: String, Codable { case disabled, key, modifierKey }

enum RecordingTriggerMode: String, Codable { case hold, toggle
    var badgeTitle: String { .hold: "Hold"; .toggle: "Tap" } }

enum ShortcutRole { case hold, toggle, copyAgain
    var title: String { "Hold to Talk" / "Tap to Toggle" / "Paste Again" } }

enum ShortcutEvent: Equatable {
    case holdActivated, holdDeactivated, toggleActivated, toggleDeactivated, copyAgainTriggered
}
```

### 1.3 `ShortcutConfiguration`

```swift
struct ShortcutConfiguration: Equatable {
    let hold: ShortcutBinding
    let toggle: ShortcutBinding
    let copyAgain: ShortcutBinding          // default .disabled
    let permittedAdditionalExactMatchModifiers: ShortcutModifiers  // default []
    static let disabled = …(hold: .disabled, toggle: .disabled, copyAgain: .disabled)
}
```

`permittedAdditionalExactMatchModifiers` — логические модификаторы, которые разрешено зажать «сверху» exact-биндинга без срыва матча (используется command-режимом).

### 1.4 `ShortcutPreset`

```swift
enum ShortcutPreset: String, CaseIterable, Identifiable, Codable {
    case fnKey = "fn", rightOption = "rightOption", f5 = "f5"
}
```

| Пресет | title | Биндинг |
|---|---|---|
| `.fnKey` | `Fn 🌐` | keyCode **63**, display `"Fn"`, modifiers `[]`, kind `.modifierKey` |
| `.rightOption` | `Right Option ⌥` | keyCode **61**, display `"Right Option"`, modifiers `[]`, kind `.modifierKey` |
| `.f5` | `F5` | keyCode **96**, display `"F5"`, modifiers `[]`, kind `.key` |

`var binding: ShortcutBinding` — строит биндинг с `preset: self`.

### 1.5 `ShortcutBinding` (Codable, Hashable, Identifiable, Equatable)

```swift
struct ShortcutBinding: Codable, Hashable, Identifiable, Equatable {
    let keyCode: UInt16
    let keyDisplay: String
    let modifiers: ShortcutModifiers
    let kind: ShortcutBindingKind
    let preset: ShortcutPreset?
    let exactModifierKeyCodes: Set<UInt16>?   // nil = не требовать точного набора
}
```

Производные:
- `id: String` = `"\(kind.rawValue):\(keyCode):\(modifiers.rawValue):\(preset?.rawValue ?? "custom"):\(orderedExactModifierKeyCodes.map(String.init).joined(separator: ","))"`.
- `isDisabled` = `kind == .disabled`; `isCustom` = `preset == nil && !isDisabled`.
- `displayName`: `"Disabled"` | `modifierDisplayNames + [primaryDisplayName]` через `" + "`; `primaryDisplayName` — для `.modifierKey` это `exactModifierDisplayLabel(keyCode)` (например `"Right Option ⌥"`), иначе `keyDisplay`.
- `selectionTitle` = `preset?.title ?? displayName`.
- `specificityScore: Int` = `modifierDisplayNames.count` (число отображаемых модификаторов).
- `usesFnKey` = `!isDisabled && (keyCode == 63 || modifiers.contains(.function))`.
- `requiresExactModifierMatch` = `kind == .modifierKey || exactModifierKeyCodes != nil`.
- `withAddedModifiers(_:)`: union модификаторов; если были exact-коды — долить коды добавляемых модификаторов через `exactModifierKeyCodesPreservingSides`; disabled возвращается как есть.

Статики-дефолты:
- `static let disabled = ShortcutBinding(keyCode: 0, keyDisplay: "Disabled", modifiers: [], kind: .disabled, preset: nil)`.
- `static let defaultHold = ShortcutPreset.fnKey.binding` (Fn).
- `static let defaultToggle = defaultHold.withAddedModifiers(.command)` (Fn+Cmd).
- Legacy-загрузка (AppState): `hotkey_option` (UserDefaults string) → пресет, fallback `.fnKey`; hold = пресет, toggle = hold+Cmd.

### 1.6 Миграция при загрузке: `normalizedForStorageMigration()`

1. `normalizedExactModifierKeyCodes = normalizedExactModifierKeyCodes(exactModifierKeyCodes)` (фильтр по `modifierKeyCodes`, пусто → nil).
2. Для `.modifierKey`: лишние коды = нормализованные минус `[keyCode]`; иначе = нормализованные.
3. `normalizedModifiers = modifiers ∪ modifiers(for: лишние коды)`.
4. Если ничего не изменилось — вернуть self; иначе новый биндинг. Используется при каждом сохранении и загрузке (`loadShortcut`, `persistShortcut`).

---

## 2. Полные таблицы virtual keycodes

### 2.1 `modifierKeyCodes: Set<UInt16>` = `[54, 55, 56, 58, 59, 60, 61, 62, 63]`

| Код | Клавиша | Логический модификатор (`logicalModifier(forKeyCode:)`) | NSEvent-флаг (`ModifierKeyEventState`) | Канонический код |
|---|---|---|---|---|
| 54 | Right Command (Right Cmd ⌘) | `.command` | `.rightCommand` (NX_DEVICERCMDKEYMASK) | 55 |
| 55 | Command (Cmd ⌘) | `.command` | `.leftCommand` (NX_DEVICELCMDKEYMASK) | 55 |
| 56 | Shift (Shift ⇧) | `.shift` | `.leftShift` (NX_DEVICELSHIFTKEYMASK) | 56 |
| 58 | Option (Option ⌥) | `.option` | `.leftOption` (NX_DEVICELALTKEYMASK) | 58 |
| 59 | Control (Ctrl ⌃) | `.control` | `.leftControl` (NX_DEVICELCTLKEYMASK) | 59 |
| 60 | Right Shift (Right Shift ⇧) | `.shift` | `.rightShift` (NX_DEVICERSHIFTKEYMASK) | 56 |
| 61 | Right Option (Right Option ⌥) | `.option` | `.rightOption` (NX_DEVICERALTKEYMASK) | 58 |
| 62 | Right Control (Right Ctrl ⌃) | `.control` | `.rightControl` (NX_DEVICERCTLKEYMASK) | 59 |
| 63 | Fn (Fn 🌐) | `.function` | `.function` | 63 |

`canonicalModifierKeyCode`: 54→55, 60→56, 61→58, 62→59, остальное — как есть.

`exactModifierDisplayLabel`: 55 `"Cmd ⌘"`, 54 `"Right Cmd ⌘"`, 59 `"Ctrl ⌃"`, 62 `"Right Ctrl ⌃"`, 58 `"Option ⌥"`, 61 `"Right Option ⌥"`, 56 `"Shift ⇧"`, 60 `"Right Shift ⇧"`, 63 `"Fn"`, иначе nil.
`logicalModifierDisplayLabel`: 55 `"Command"`, 59 `"Control"`, 58 `"Option"`, 56 `"Shift"`, 63 `"Fn"`, иначе `"Modifier"`.

`modifierDisplayOrder: [UInt16]` = `[55, 54, 59, 62, 58, 61, 56, 60, 63]` — порядок перечисления exact-кодов в `id` и подписях.

`modifierKeyCodeMatchSpecs` (группы синонимов для точного матча):
`(.command, {54,55}), (.control, {59,62}), (.option, {58,61}), (.shift, {56,60}), (.function, {63})`.

`modifierDisplaySpecs` (подписи): `(.command, "Cmd ⌘", [(55,"Cmd ⌘"),(54,"Right Cmd ⌘")]), (.control, "Ctrl ⌃", [(59,"Ctrl ⌃"),(62,"Right Ctrl ⌃")]), (.option, "Option ⌥", [(58,"Option ⌥"),(61,"Right Option ⌥")]), (.shift, "Shift ⇧", [(56,"Shift ⇧"),(60,"Right Shift ⇧")]), (.function, "Fn 🌐", [(63,"Fn 🌐")])`.

`exactModifierKeyCodes(for modifiers:)` — канонические коды: Cmd→55, Ctrl→59, Option→58, Shift→56, Fn→63.
`exactModifierKeyCodesPreservingSides(for:)` — обе стороны: Cmd→{54,55}, Ctrl→{59,62}, Option→{58,61}, Shift→{56,60}, Fn→63.
`matchingModifierKeyCodes(for:)` — все коды из `modifierKeyCodes`, чей логический модификатор входит в набор.
`normalizedExactModifierKeyCodes(_:)` — nil → nil; фильтр по `modifierKeyCodes`; пусто → nil.
`orderedExactModifierKeyCodes(_:)` — `modifierDisplayOrder.filter(набор.contains)`.

### 2.2 `specialKeyNames` (из `ShortcutBinding.swift`)

| Код | Имя | Код | Имя | Код | Имя | Код | Имя |
|---|---|---|---|---|---|---|---|
| 18 | 1 | 19 | 2 | 20 | 3 | 21 | 4 |
| 23 | 5 | 22 | 6 | 26 | 7 | 28 | 8 |
| 25 | 9 | 29 | 0 | 27 | - | 24 | = |
| 33 | [ | 30 | ] | 42 | \ | 41 | ; |
| 39 | ' | 43 | , | 47 | . | 44 | / |
| 50 | ` | 36 | ↩ | 48 | ⇥ | 49 | Space |
| 51 | ⌫ | 53 | Esc | 117 | Del | 123 | ← |
| 124 | → | 125 | ↓ | 126 | ↑ | 115 | Home |
| 119 | End | 116 | Pg Up | 121 | Pg Down | | |

### 2.3 `functionKeyNames`

| Код | Имя | Код | Имя | Код | Имя | Код | Имя |
|---|---|---|---|---|---|---|---|
| 122 | F1 | 120 | F2 | 99 | F3 | 118 | F4 |
| 96 | F5 | 97 | F6 | 98 | F7 | 100 | F8 |
| 101 | F9 | 109 | F10 | 103 | F11 | 111 | F12 |
| 105 | F13 | 107 | F14 | 113 | F15 | 106 | F16 |
| 64 | F17 | 79 | F18 | 80 | F19 | 90 | F20 |

### 2.4 `displayLabel(for:event:)` и конструкторы захвата

Порядок: `modifierKeyNames` (та же таблица 2.1: 54 "Right Command", 55 "Command", 56 "Shift", 58 "Option", 59 "Control", 60 "Right Shift", 61 "Right Option", 62 "Right Control", 63 "Fn") → `specialKeyNames` → `functionKeyNames` → иначе `event.charactersIgnoringModifiers`: один символ после trim — uppercase; иначе строка; пусто → nil-результат.

- `ShortcutBinding.from(event:pressedModifierKeyCodes:)`: игнор repeat и modifier-кодов; label непуст; `exactModifierKeyCodes = normalized(pressed)`; `modifiers = modifiers(for: pressed)`; kind `.key`, preset nil.
- `ShortcutBinding.fromModifierKeyCode(_:pressedModifierKeyCodes:allowBareModifier: false)`: код — модификатор; `primaryModifier = logicalModifier`; активные модификаторы обязаны содержать primary; `extraModifiers = активные − primary`; вернуть nil если `!allowBareModifier && extra.isEmpty` (голый модификатор не захватывается); иначе биндинг kind `.modifierKey` с exact = normalized(pressed) и `keyDisplay = displayLabel(keyCode)`.

---

## 3. `ShortcutMatcher` — чистый редьюсер

### 3.1 Вход/выход

```swift
enum ShortcutInputEvent: Equatable {
    case modifierChanged(keyCode: UInt16, isDown: Bool)
    case modifierSnapshot(Set<UInt16>)                       // полный срез зажатых модификаторов
    case keyChanged(keyCode: UInt16, isDown: Bool, isRepeat: Bool)
    case backendReset
}
enum ShortcutConsumeDecision: Equatable { case consume, passthrough }
struct ShortcutMatchResult: Equatable {
    let state: ShortcutInputState
    let emittedEvents: [ShortcutEvent]
    let consumeDecision: ShortcutConsumeDecision
}
```

```swift
struct ShortcutInputState: Equatable {
    var pressedKeyCodes: Set<UInt16> = []
    var pressedModifierKeyCodes: Set<UInt16> = []
    var holdIsActive = false
    var toggleIsActive = false
    var copyAgainIsActive = false
    var currentModifiers: ShortcutModifiers { ShortcutBinding.modifiers(for: pressedModifierKeyCodes) }
    func hasPressedShortcutInputs(configuration:) -> Bool   // см. 3.6
}
```

`static func reduce(state:event:configuration:) -> ShortcutMatchResult` — единственная точка входа, детерминированный, без побочных эффектов.

### 3.2 Общая переоценка (`updateActiveBindings`)

После каждого события (кроме repeat-ветки) пересчитать:
`holdIsActive / toggleIsActive / copyAgainIsActive = bindingIsActive(биндинг, state, configuration)`.

`bindingIsActive`:
1. disabled → false.
2. Модификаторы: `state.currentModifiers.isSuperset(of: binding.modifiers)` обязателен; если `exactModifierKeyCodes != nil` — дополнительно `ShortcutBinding.exactModifierKeyCodesMatch(pressedModifierKeyCodes, exactModifierKeyCodes:, permittedAdditionalExactMatchModifiers:)`.
3. `.key` → `pressedKeyCodes.contains(keyCode)`; `.modifierKey` → `pressedModifierKeyCodes.contains(keyCode)`.

`exactModifierKeyCodesMatch(pressed, exact, permittedAdditional)` — по группам-синонимам (`modifierKeyCodeMatchSpecs`):
- нормализовать exact;
- для каждой группы: `exactKeys = exact ∩ spec.keyCodes`, `pressedKeys = pressed ∩ spec.keyCodes`;
  - если exactKeys пуст: любые pressedKeys запрещены, если только `permittedAdditional.contains(spec.logicalModifier)` (лишний модификатор разрешён явно);
  - если exactKeys покрывают всю группу (обе стороны): pressedKeys непусты и ⊆ exactKeys;
  - иначе pressedKeys == exactKeys.

### 3.3 Эмиссия событий (`emitChanges`)

- Активации: hold/toggle по 0→1 фронту; **`copyAgainTriggered` — только leading edge (one-shot)**: пассивное удержание не ретриггерит, деактивация сбрасывает.
- Деактивации: 1→0 фронты hold/toggle.
- Порядок в списке: активации — по УБЫВАНИЮ `specificityScore` (более специфичный первым); деактивации — по ВОЗРАСТАНИЮ; результат `активации + деактивации`.

### 3.4 Обработка событий

**`.backendReset`**: очистить `pressedKeyCodes` и `pressedModifierKeyCodes`, переоценить активность (выключенные биндинги дадут деактивации), **всегда `.passthrough`**.

**`.modifierSnapshot(codes)`**: `nextState.pressedModifierKeyCodes = codes`; переоценка; consume = `.consume` только если есть emittedEvents, иначе `.passthrough`.

**`.modifierChanged(keyCode, isDown)`**:
1. `shouldConsumeBefore = shouldConsumeModifierEvent(keyCode, state)` (ДО изменения);
2. вставить/удалить код;
3. `shouldConsumeAfter` на новом состоянии;
4. переоценка активности;
5. consume = `before || after`.

`shouldConsumeModifierEvent`: среди биндингов `[hold, toggle, copyAgain]`, затронутых этим событием (`relevantModifierBindings`), есть активный (`bindingIsActive`) в текущем состоянии. Биндинг «затронут», если (по `modifierEvent`): `binding.keyCode == keyCode`, ИЛИ (для `.key` и `.modifierKey`) код — модификатор И (у биндинга есть exact-коды (любой модификаторный код влияет) ИЛИ логический модификатор кода входит в `binding.modifiers`). Disabled — никогда.

**`.keyChanged(keyCode, isDown, isRepeat)`**:
1. `shouldConsumeBefore = shouldConsumeKeyEvent(keyCode, state)` — среди биндингов kind `.key` с совпадающим keyCode есть активный;
2. **если `isRepeat` — состояние НЕ меняется, событий нет**, consume = `shouldConsumeBefore ? .consume : .passthrough`;
3. иначе вставить/удалить код из `pressedKeyCodes`;
4. `shouldConsumeAfter`; переоценка;
5. consume = `before || after`.

### 3.5 Проверка exact-матча внутри `isActive(for:)` (используется конфликтами, п. 6)

Тот же `exactModifierKeyCodesMatch`, но без permittedAdditional; для `.key` достаточно супермножества модификаторов (если exact нет); для `.modifierKey` — код должен быть среди зажатых.

### 3.6 `hasPressedShortcutInputs(configuration:)`

Используется AppState, чтобы понять, держит ли пользователь «свой» ввод (например, при выходе/сбросе). true, если:
- любой зажатый keyCode — primary-код hold/toggle/copyAgain kind `.key`;
- ИЛИ любой из hold/toggle/copyAgain «referencesPressedModifiers»: есть точные коды → пересечение с зажатыми модификаторами, либо пересечение кодов разрешённых дополнительных модификаторов (`matchingModifierKeyCodes(for: permittedAdditional)`); без точных кодов → пересечение логических модификаторов с `currentModifiers`; для `.modifierKey` дополнительно — зажат его primary-код.

---

## 4. `DictationShortcutSessionController` — FSM сессии

```swift
enum DictationShortcutAction: Equatable { case start(RecordingTriggerMode), stop, switchedToToggle }

final class DictationShortcutSessionController {
    private(set) var activeMode: RecordingTriggerMode?   // nil = сессии нет
    private(set) var toggleStopArmed = false
    func handle(event: ShortcutEvent, isTranscribing: Bool) -> DictationShortcutAction?
    func beginManual(mode: RecordingTriggerMode)         // activeMode = mode; armed = false (ручной старт из UI)
    func forceToggleMode()                               // activeMode = .toggle; armed = false
    func reset()                                         // activeMode = nil; armed = false
}
```

`.copyAgainTriggered` всегда `nil` (обрабатывается до контроллера; защита от будущего изменения).

### 4.1 Переходы

**Состояние «неактивен» (`activeMode == nil`)**:
- если `isTranscribing` — любые события → nil (новая сессия во время транскрипции запрещена);
- `.toggleActivated` → `activeMode = .toggle`, armed = false → **`.start(.toggle)`**;
- `.holdActivated` → `activeMode = .hold`, armed = false → **`.start(.hold)`**;
- `.holdDeactivated` / `.toggleDeactivated` → nil.

**Состояние `hold`:**
- `.toggleActivated` → `activeMode = .toggle`, armed = false → **`.switchedToToggle`** (запись продолжается, режим переключён);
- `.holdDeactivated` → `reset()` → **`.stop`**;
- `.holdActivated` / `.toggleDeactivated` → nil.

**Состояние `toggle`:**
- `.toggleDeactivated` → `toggleStopArmed = true` → nil (отпускание только взводит стоп);
- `.toggleActivated` при `toggleStopArmed` → `reset()` → **`.stop`** (второе нажатие останавливает);
- `.toggleActivated` без armed → nil (повторное нажатие без отпускания не глушит);
- `.holdActivated` / `.holdDeactivated` → nil.

Итого полный граф покрыт; любые комбинации вне таблицы — nil.

---

## 5. Конфликты биндингов

### 5.1 `ShortcutBinding.conflicts(with other: ShortcutBinding) -> Bool`

1. Любой disabled → false.
2. `primaryInputOverlaps`: kinds должны совпадать; `.disabled` → false; `.key`/`.modifierKey` → `keyCode == other.keyCode`.
3. Перебор всех подмножеств модификаторов: 9 кодов → `2^9 = 512` масок; для каждой маски `pressedModifierKeyCodes`; конфликт, если `isActive(for: pressed) && other.isActive(for: pressed) && specificityScore == other.specificityScore`.

Смысл: конфликт = существует сценарий нажатия, при котором оба срабатывают неразличимо.

### 5.2 Тексты ошибок `AppState.setShortcut(_ binding:for role:) -> String?`

Порядок проверок (binding сначала `normalizedForStorageMigration()`):
1. hold↔toggle: `"Hold and tap shortcuts must be distinct."`
2. hold/toggle↔copyAgain: `"This shortcut is already used by Paste Again."`
3. copyAgain↔hold: `"Paste Again cannot share a shortcut with Hold to Talk."`
4. copyAgain↔toggle: `"Paste Again cannot share a shortcut with Tap to Toggle."`
5. copyAgain vs command-режим (manual, `bindingCollides`): `"Paste Again cannot share the Edit Mode modifier."`

Успех: если `binding.isCustom` — сохранить в `saved<Role>CustomShortcut`; присвоить роль; вернуть nil.

Дополнительная валидация command-режима (`commandModeManualModifierCollisionMessage`): `"That modifier is already part of the hold shortcut."` / `…tap shortcut.` / `…Paste Again shortcut.`; для modifier-only биндингов (идентичность в keyCode): `"That modifier is already the hold shortcut."` / `…the tap shortcut.` / `…the Paste Again shortcut.`

Хранение: каждое из `hold_shortcut`, `toggle_shortcut`, `copy_again_shortcut`, `saved_hold_custom_shortcut`, `saved_toggle_custom_shortcut`, `saved_copy_again_custom_shortcut` — JSON `ShortcutBinding` в UserDefaults (legacy-ключ `hotkey_option` — строка пресета).

---

## 6. `GlobalShortcutBackend` — системный event tap

OSLog: category `"Shortcuts"`. Ошибки:

| Кейс | Текст |
|---|---|
| `.eventTapUnavailable` | `Global shortcut monitoring could not start. <AppName> requires keyboard monitoring permission for global shortcuts.` |
| `.eventTapRunLoopSourceUnavailable` | `Global shortcut monitoring could not start because the event tap run loop source could not be created.` |

### 6.1 Установка (`start()`)

1. `stop()` (идемпотентно).
2. `installEventTap()`:
   - маска: `flagsChanged | keyDown | keyUp` (битовые `CGEventMask(1) << rawValue`);
   - `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest:, callback:, userInfo: Unmanaged.passUnretained(self))`; nil → `.eventTapUnavailable`;
   - `CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)`; nil → invalidate tap, `.eventTapRunLoopSourceUnavailable`;
   - `CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)` — источник живёт на **main run loop**;
   - `CGEvent.tapEnable(tap:enable: true)`.
3. `fnKeyIsDown = ModifierKeyEventState.currentFunctionKeyIsDown()` (сидирование после установки).

`stop()`: снять source с main run loop, `CFMachPortInvalidate(tap)`, обнулить поля, затем `notifyBackendReset()` (`fnKeyIsDown = false` + `onInputEvent?(.backendReset)`, результат игнорируется). `deinit` → `stop()`.

### 6.2 Колбэк `handleEventTap`

Возвращает `Unmanaged<CGEvent>?`: **nil = событие поглощено**, иначе `Unmanaged.passUnretained(event)` — пропустить.

- `.tapDisabledByTimeout` / `.tapDisabledByUserInput`: `notifyBackendReset()` (сброс состояния матчера), `CGEvent.tapEnable(enable: true)`, пере-read Fn (`fnKeyIsDown = currentFunctionKeyIsDown()`), событие пропустить. **Авто-re-enable обязателен.**
- `.flagsChanged` / `.keyDown` / `.keyUp`: `NSEvent(cgEvent:)`; nil → пропустить.
- прочие типы — пропустить.

**flagsChanged**: код ∈ `modifierKeyCodes` и `isKeyDown(for:)` != nil, иначе passthrough(false); если код 63 — обновить `fnKeyIsDown`; consume = `onInputEvent?(.modifierChanged(keyCode:isDown:)) == .consume`.

**keyDown**:
- keyCode 53 (Esc): `guard !isARepeat` иначе false; consume = `onEscapeKeyPressed?() ?? false`;
- modifier-коды — passthrough(false);
- иначе ДВА события подряд: `.modifierSnapshot(ModifierKeyEventState.pressedModifierKeyCodes(for: event, trustedFunctionKeyIsDown: fnKeyIsDown))`, затем `.keyChanged(keyCode:, isDown: true, isRepeat: event.isARepeat)`; consume = OR решений.

**keyUp**: modifier-коды — passthrough; те же два события с `isDown: false, isRepeat: false`; consume = OR.

`onEscapeKeyPressed: (() -> Bool)?` прокидывается из HotkeyManager в `onEscapeKeyPressed` AppState.

---

## 7. `ModifierKeyEventState`

```swift
enum ModifierKeyEventState {
    static let fnKeyCode: UInt16 = 63
    static func isKeyDown(for event: NSEvent) -> Bool?     // nil для не-модификатора
    static func pressedModifierKeyCodes(for event:, trustedFunctionKeyIsDown: Bool? = nil) -> Set<UInt16>
    static func currentFunctionKeyIsDown() -> Bool          // NSEvent.modifierFlags.contains(.function)
}
```

- `mappedFlag`: 54→`.rightCommand`, 55→`.leftCommand`, 56→`.leftShift`, 58→`.leftOption`, 59→`.leftControl`, 60→`.rightShift`, 61→`.rightOption`, 62→`.rightControl`, 63→`.function` (остальные nil). Боковые флаги объявлены через Carbon-маски: `NX_DEVICELCTLKEYMASK`, `NX_DEVICELSHIFTKEYMASK`, `NX_DEVICERSHIFTKEYMASK`, `NX_DEVICELCMDKEYMASK`, `NX_DEVICERCMDKEYMASK`, `NX_DEVICELALTKEYMASK`, `NX_DEVICERALTKEYMASK`, `NX_DEVICERCTLKEYMASK` (import Carbon.HIToolbox).
- `isKeyDown` = `event.modifierFlags.contains(mappedFlag)`.
- `pressedModifierKeyCodes`: фильтр `modifierKeyCodes`; для кода 63, если передан доверенный `trustedFunctionKeyIsDown` — он и есть ответ (macOS ставит `.function` для стрелок/F-клавиш/навигации независимо от физического Fn, поэтому флаг ненадёжен); иначе mappedFlag-проверка.
- `currentFunctionKeyIsDown` — чтение `NSEvent.modifierFlags` (системный срез); используется для сидирования при старте бэкенда и после reset.

---

## 8. `HotkeyManager` — фасад

```swift
final class HotkeyManager {
    private let backend = GlobalShortcutBackend()
    private var configuration = ShortcutConfiguration(hold: .defaultHold, toggle: .defaultToggle)
    private var inputState = ShortcutInputState()
    var onShortcutEvent: ((ShortcutEvent) -> Void)?
    var onEscapeKeyPressed: (() -> Bool)?
    var currentPressedModifiers: ShortcutModifiers { inputState.currentModifiers }
    var hasPressedShortcutInputs: Bool { inputState.hasPressedShortcutInputs(configuration: configuration) }
    func start(configuration:) throws
    func stop()
}
```

- `start`: `stop()`; сохранить конфигурацию; `backend.onInputEvent = { handleInputEvent($0) ?? .passthrough }`; `backend.onEscapeKeyPressed` → наружный колбэк (nil → false); `backend.start()`; при ошибке — снять колбэки, `inputState = ShortcutInputState()`, rethrow.
- `handleInputEvent`: `ShortcutMatcher.reduce(state:event:configuration:)` → `inputState = result.state` → для каждого emitted — `onShortcutEvent?(event)` → вернуть `result.consumeDecision`.
- `stop`: `backend.stop()`, снять колбэки, сбросить inputState. `deinit` → `stop()`.

Esc (keyCode 53), условия consume в AppState (`handleEscapeKeyPress` — точная логика):

```swift
private func handleEscapeKeyPress() -> Bool {
    if isTranscribing { cancelTranscription(); return true }          // глотаем: Esc отменяет транскрипцию
    if pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle {
        cancelToggleShortcutSession(); return true                     // глотаем: Esc отменяет toggle-сессию
    }
    return false                                                       // Esc уходит в чужое приложение
}
```

---

## 9. `LocalShortcutCaptureBackend` — режим захвата (экран настроек)

Назначение: слушать события ТОЛЬКО своего приложения, не требуя permissions, во время записи пользовательского шортката.

```swift
final class LocalShortcutCaptureBackend {
    var onInputEvent: ((ShortcutInputEvent) -> Void)?   // события для UI-матчинга
    var onKeyDownEvent: ((NSEvent) -> Void)?            // сырой keyDown для рендера
    func start(); func stop()
}
```

- `start()`: `stop()`; если `currentFunctionKeyIsDown()` — сидировать 63 в локальный набор; мониторы: `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)` и `.keyDown`, оба обработчика **всегда `return nil`** (все локальные события глотаются, в чужие окна ничего не утекает).
- `stop()`: снять мониторы, очистить `pressedModifierKeyCodes`. `deinit` → `stop()`.
- flagsChanged: только модификаторные коды с валидным `isKeyDown`; вставка/удаление из локального `pressedModifierKeyCodes`; `onInputEvent?(.modifierChanged)`.
- keyDown: если код НЕ модификатор — два события: `.modifierSnapshot(pressedModifierKeyCodes(for: event, trustedFunctionKeyIsDown: локальный набор содержит 63))` и `.keyChanged(keyCode:, isDown: true, isRepeat: event.isARepeat)`; затем всегда `onKeyDownEvent?(event)`.
- Правила захвата (UI-слой `ShortcutComponents`, поверх событий; сам бэкенд — только трансляция):
  - `onInputEvent` гонит события через `ShortcutMatcher.reduce(state:, event:, configuration: .disabled)` — чисто для отслеживания `pressedModifierKeyCodes`;
  - модификатор → каждый `.modifierChanged` пробует `ShortcutBinding.fromModifierKeyCode(keyCode, pressedModifierKeyCodes:, allowBareModifier: true)` — **голый модификатор захватывается** (в отличие от дефолта функции); результат — pending-биндинг;
  - обычная клавиша → `ShortcutBinding.from(event:, pressedModifierKeyCodes:)` → pending; если nil — pending не меняется;
  - **Enter (36) или KP-Enter (76) при наличии pending → `finishCapture()`** = `onCapture(currentBinding)` + `stopCapture(clearCaptureState: true)`;
  - **Esc (53) при наличии pending → тоже `finishCapture()`** (подтверждает pending; `finishCapture` при пустом pending — страховочный путь в `cancelCapture`);
  - Esc без pending проходит общий путь → создаёт pending-биндинг «Esc» (specialKeyNames[53]);
  - повторные нажатия отсекаются в `ShortcutBinding.from` (`guard !event.isARepeat`).
  - `onDisappear` → `stopCapture(clearCaptureState: true)` (отмена сессии захвата).

### 9.1 Приостановка глобального мониторинга (AppState)

```swift
func suspendHotkeyMonitoringForShortcutCapture()   // isCapturingShortcut = true;  restartHotkeyMonitoring()
func resumeHotkeyMonitoringAfterShortcutCapture()  // isCapturingShortcut = false; restartHotkeyMonitoring()
private func restartHotkeyMonitoring() {
    guard shouldMonitorHotkeys, !isCapturingShortcut, !isAwaitingMicrophonePermission else {
        hotkeyManager.stop(); return
    }
    do { try hotkeyManager.start(configuration: activeShortcutConfiguration); hotkeyMonitoringErrorMessage = nil }
    catch { hotkeyMonitoringErrorMessage = error.localizedDescription … }
}
```

`activeShortcutConfiguration` = `ShortcutConfiguration(hold:, toggle:, copyAgain:, permittedAdditionalExactMatchModifiers:)`, где permitted = модификатор command-режима (manual), если тот включён, иначе `[]`. Т.е. во время захвата глобальный tap остановлен и не глотает нажатия.

---

## 10. `SystemAudioStatus` — CoreAudio

```swift
enum SystemAudioStatus {
    static func isDefaultOutputMuted() -> Bool
    @discardableResult static func setDefaultOutputMuted(_ muted: Bool) -> Bool
    static func defaultOutputVolume() -> Float?
}
```

- Устройство: `AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), …)` с селектором `kAudioHardwarePropertyDefaultOutputDevice`, scope `kAudioObjectPropertyScopeGlobal`, элемент `kAudioObjectPropertyElementMain`; ошибка → nil (mute: трактуется как «не заглушено»).
- Mute: property `kAudioDevicePropertyMute`, scope `kAudioDevicePropertyScopeOutput`, элемент `kAudioObjectPropertyElementMain`; `AudioObjectHasProperty` гейт; чтение — `UInt32` (1 = muted); запись — `AudioObjectSetPropertyData` c `UInt32` 0/1; успех = `noErr`. Сценарий: глушение вывода на время диктовки, восстановление предыдущего состояния (`ActiveAudioInterruption.muted(previouslyMuted:)` в AppState).
- Громкость: `kAudioDevicePropertyVolumeScalar` (Float32); сначала main-элемент; если нет — максимум по каналам 1…2 (`AudioObjectPropertyElement(channel)`); нет свойства/ошибка → nil/пропуск канала.

## 11. `NetworkMonitor`

```swift
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.nick8cyber.omniflow.network-monitor")
    private let lock = NSLock(); private var started = false
    private var _isOnline = true                      // дефолт ONLINE
    var isOnline: Bool { … под локом, потокобезопасно }
    func start() { … идемпотентно под локом }
}
```

- `start()`: guard от повторного запуска; `monitor.pathUpdateHandler = { path in _isOnline = (path.status == .satisfied) }` (под локом); `monitor.start(queue:)`.
- `start()` вызывается в `AppDelegate.applicationDidFinishLaunching` первой строкой.
- Семантика дефолта: до первого обновления пути сеть считается доступной, чтобы первый запрос не был ложно обвинён в оффлайне; используется классификацией ошибок транскрипции (отличить «сеть лежит» от «провайдер медленный»; см. `10-transcription.md`).

---

## 12. Чек-лист «что должно получиться в коде»

- [ ] `ShortcutModifiers` — OptionSet на битах 0…4, Codable как Int; `ShortcutBindingKind`, `RecordingTriggerMode`, `ShortcutRole`, `ShortcutEvent`, `ShortcutConfiguration` (c `permittedAdditionalExactMatchModifiers`), `ShortcutPreset` (63/61/96).
- [ ] `ShortcutBinding` — Codable c exactModifierKeyCodes; `id`, `displayName`, `specificityScore`, `usesFnKey`, `withAddedModifiers`, `normalizedForStorageMigration`; дефолты hold=Fn, toggle=Fn+Cmd.
- [ ] Таблицы keycode → имя (модификаторы 54…63, спецклавиши, F1…F20) воспроизведены дословно.
- [ ] `ShortcutMatcher.reduce` — чистый: 4 типа событий; consume «до ИЛИ после» изменения состояния; snapshot-consume только при наличии событий; repeat не меняет состояние; сортировка активаций по убыванию / деактиваций по возрастанию specificity; copyAgain — leading edge only; backendReset всегда passthrough.
- [ ] Exact-матч по группам синонимов с `permittedAdditionalExactMatchModifiers`.
- [ ] FSM `DictationShortcutSessionController`: все переходы раздела 4.1, включая `switchedToToggle`, arm-механику toggle-stop и блокировку старта при `isTranscribing`; `beginManual/forceToggleMode/reset`.
- [ ] Конфликты: перебор 2^9 подмножеств; тексты ошибок setShortcut и command-mode дословно.
- [ ] `GlobalShortcutBackend`: session tap, headInsert, defaultTap, маска flagsChanged|keyDown|keyUp, run loop source на main, tapEnable, авто-re-enable с backendReset и пере-read Fn; Escape через keyCode 53 без repeat; keyDown/keyUp = snapshot + keyChanged, consume = OR.
- [ ] `ModifierKeyEventState`: NX_DEVICEL*-маски, доверенный Fn (сидирование из `NSEvent.modifierFlags`), fnKeyCode 63.
- [ ] `HotkeyManager` — фасад: start/stop, прокидывание событий и Esc, сброс inputState при ошибке.
- [ ] `LocalShortcutCaptureBackend`: локальные мониторы flagsChanged/keyDown, всегда `return nil`; правила захвата UI-слоя: Enter 36/76 при pending — подтверждение, Esc при pending — подтверждение (`finishCapture`), `allowBareModifier: true`, reduce с `.disabled`-конфигурацией; `suspendHotkeyMonitoringForShortcutCapture` / `resumeHotkeyMonitoringAfterShortcutCapture` через `restartHotkeyMonitoring` (гвард `shouldMonitorHotkeys && !isCapturingShortcut && !isAwaitingMicrophonePermission`).
- [ ] `SystemAudioStatus` (mute/volume дефолтного выхода через kAudioObjectPropertyElementMain) и `NetworkMonitor` (NWPathMonitor, isOnline default true, start в AppDelegate).
