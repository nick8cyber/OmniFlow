# 33 — Сборка и упаковка (Makefile, Info.plist, entitlements)

Спека сборочного слоя. Референс: `Makefile`, `Info.plist`,
`OmniFlow.entitlements`, `Resources/`, `.github/`. Проект собирается **без
Xcode-проекта и SPM-манифеста** — единственный компилятор вызывается вручную
через `swiftc` из Makefile.

---

## 1. Makefile — переменные

```make
APP_NAME ?= OmniFlow Dev
BUNDLE_ID ?= com.nick8cyber.omniflow.dev
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CODESIGN_IDENTITY ?= OmniFlow Dev
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
APP_EXECUTABLE = $(MACOS_DIR)/$(APP_NAME)
```

- `APP_NAME` переопределяется для стейбл-сборки (`OmniFlow`, bundle id
  `com.nick8cyber.omniflow`) — вся сборка параметрическая по имени.
- `empty :=` / `space :=` и
  `APP_EXECUTABLE_TARGET := $(subst $(space),\ ,$(APP_EXECUTABLE))` — цель с
  **экранированным пробелом** в имени (`build/OmniFlow\ Dev.app/…`), т.к. дефолтное
  имя содержит пробел.
- `SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)` — все
  swift-файлы рекурсивно, детерминированный порядок (LC_ALL=C sort).
- `TEST_RUNNER = $(BUILD_DIR)/OmniFlowTests` — бинарник тест-раннера.
- `ARCH ?= $(shell uname -m)`; спец-значение `universal`.
- `SHELL_SCRIPTS = $(shell find .github/scripts .agents/skills -name '*.sh' -type f | LC_ALL=C sort)`
  (фактически: `.github/scripts/changelog-section.sh`,
  `.agents/skills/freeflow-release/scripts/freeflow-release-check.sh`).
- `YAML_FILES = $(shell find .github -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)`.
- `RESOURCES = $(CONTENTS)/Resources`.

### Выбор иконки по каналу сборки

```make
ifeq ($(APP_NAME),OmniFlow Dev)
ICON_SOURCE = Resources/AppIcon-Dev-Source.png
ICON_ICNS   = Resources/AppIcon-Dev.icns
else
ICON_SOURCE = Resources/AppIcon-Source.png
ICON_ICNS   = Resources/AppIcon.icns
endif
```

Dev-иконка — «hammer-on-waveform», чтобы в доке отличать dev-сборку при
параллельной установке. Ресурсы: `AppIcon-Dev-Source.png`, `AppIcon-Dev.icns`,
`AppIcon-Source.png`, `AppIcon.icns`, `dmg-background.tiff` (+ png/@2x
исходники), `demo.gif`.

### TEST_PRODUCTION_SOURCES — точный список (16 файлов)

Компиляция тестов тянет **только** эти продакшн-файлы (UI/AppKit-слой в тесты
не входит):

```
Sources/AppContextService.swift
Sources/AppName.swift
Sources/AppSettingsDefaults.swift
Sources/GeminiLiveTranscription.swift
Sources/GeminiTranscription.swift
Sources/LLMAPITransport.swift
Sources/LLMCooldownManager.swift
Sources/LiveAudioLevelNormalizer.swift
Sources/ModelConfiguration.swift
Sources/PostProcessingService.swift
Sources/SemanticVersion.swift
Sources/TranscriptTextCore.swift
Sources/TranscriptionService.swift
Sources/ShortcutCore/DictationShortcutSessionController.swift
Sources/ShortcutCore/ShortcutMatcher.swift
Sources/ShortcutCore/ShortcutModels.swift
```

(`UpdateManager.swift` исключён из тестовой компоновки — он тянет AppKit ради
одного `SemanticVersion`, а `SemanticVersion` давно живёт в отдельном файле;
`PostProcessingService`/`LiveAudioLevelNormalizer`/`AppSettingsDefaults`
добавлены сюитами аудита A.)

`TEST_SOURCES = $(shell find Tests -name '*.swift' | LC_ALL=C sort)` (14 файлов,
спека 32).

---

## 2. Цель `all` (сборка .app)

Зависимости: `$(APP_EXECUTABLE_TARGET)` от `$(SOURCES) Info.plist $(ICON_ICNS)`.

### 2.1 Компиляция

`ARCH != universal` — одна проходка:

```make
swiftc -parse-as-library \
    -o "$(MACOS_DIR)/$(APP_NAME)" \
    -sdk $(shell xcrun --show-sdk-path) \
    -target $(ARCH)-apple-macosx13.0 \
    $(SOURCES)
```

`ARCH == universal` — две проходки
(`-target arm64-apple-macosx13.0` и `-target x86_64-apple-macosx13.0`, выходы
`$(APP_NAME)-arm64` / `$(APP_NAME)-x86_64`) + **`lipo -create -output`** в
финальный бинарник + удаление промежуточных. Минимальная ОС — **macOS 13.0**
(и в swiftc target, и в Info.plist `LSMinimumSystemVersion`).

`-parse-as-library` обязателен: в дереве нет main-файла для app-цели
(точка входа — `@main` в `App.swift`, который Swift сам оборачивает).

### 2.2 Сборка бандла

```
OmniFlow Dev.app/
  Contents/
    MacOS/<APP_NAME>          — бинарник
    Resources/AppIcon.icns    — копия выбранного ICON_ICNS (имя всегда AppIcon.icns)
    Info.plist
```

Порядок и содержимое plutil-пропатчивания копии `Info.plist` (все замены
обязательны, именно они параметризуют бандл):

| Ключ | Значение |
|---|---|
| `CFBundleName` | `$(APP_NAME)` |
| `CFBundleDisplayName` | `$(APP_NAME)` |
| `CFBundleExecutable` | `$(APP_NAME)` |
| `CFBundleIdentifier` | `$(BUNDLE_ID)` |
| `NSMicrophoneUsageDescription` | `"$(APP_NAME) needs microphone access to transcribe your speech."` |
| `NSSpeechRecognitionUsageDescription` | `"$(APP_NAME) needs speech recognition to convert your voice to text."` |
| `NSAccessibilityUsageDescription` | `"$(APP_NAME) needs accessibility access to detect the text cursor position and paste transcribed text."` |

Три usage-описания подставляются с `$(APP_NAME)` в тексте — System Settings
показывает имя канала сборки в запросах разрешений.

### 2.3 Код-подпись

```make
codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" \
    --entitlements OmniFlow.entitlements "$(APP_BUNDLE)"
```

- `--options runtime` — **Hardened Runtime обязателен** (требование нотаризации).
- `CODESIGN_IDENTITY ?= "OmniFlow Dev"` — имя сертификата в keychain.
- Энтитлмент-файл один на оба канала (§4).

---

## 3. Прочие цели

### 3.1 `check` = `typecheck` + `test` + `validate`

- **typecheck**:
  `swiftc -parse-as-library -typecheck -warnings-as-errors -sdk … -target $(ARCH)-apple-macosx13.0 $(SOURCES)`
  — **любое предупреждение ломает сборку**.
- **test**:
  1. `mkdir -p $(BUILD_DIR)`;
  2. `swiftc -parse-as-library -warnings-as-errors -o $(TEST_RUNNER) -sdk … -target $(ARCH)-apple-macosx13.0 $(TEST_PRODUCTION_SOURCES) $(TEST_SOURCES)`
     (тоже с `-warnings-as-errors`);
  3. запуск `$(TEST_RUNNER)` — бинарник из спеки 32; успех = строка
     `OmniFlowTests passed`, неудача — fatalError с файлом и строкой.
- **validate**:
  - `plutil -lint Info.plist OmniFlow.entitlements`;
  - `bash -n` для каждого файла из `SHELL_SCRIPTS`;
  - YAML-синтаксис всех файлов `.github` через
    `ruby -e 'require "yaml"; ARGV.each { |file| YAML.load_file(file) }'`.

### 3.2 `icon`

`$(ICON_ICNS)` из `$(ICON_SOURCE)` (`sips` + `iconutil`): иконсет в
`build/AppIcon.iconset` из 10 размеров — 16, 32 (16@2x), 32, 64 (32@2x), 128,
256 (128@2x), 256, 512 (256@2x), 512, 1024 (512@2x); `iconutil -c icns`;
удаление временного iconset.

### 3.3 `dmg` / `codesign-dmg` / `notarize` (обзор)

- **dmg** (зависимость `all`): очистить старые артефакты; staging
  `build/dmg-staging` с копией .app; символическая ссылка на `/Applications`
  создаётся через Finder (`osascript` alias file), переименовывается в
  `Applications`, кастомная иконка папки через `fileicon set` (системная
  ApplicationsFolderIcon); сборка `create-dmg`:
  `--volname $(APP_NAME)`, `--volicon $(ICON_ICNS)`,
  `--background Resources/dmg-background.tiff`, `--window-pos 200 120`,
  `--window-size 660 400`, `--icon-size 128`, иконка .app в (180, 170),
  `--hide-extension $(APP_NAME).app`, `Applications` в (480, 170),
  `--no-internet-enable`; выход `build/$(APP_NAME).dmg`.
- **codesign-dmg**: подписать сам DMG (`codesign --force --sign …`).
- **notarize**: `xcrun notarytool submit <dmg> --keychain-profile $(NOTARIZE_PROFILE) --wait`
  + `xcrun stapler staple <dmg>`.
- **run**: `make all` + `open` бандла.
- **clean**: `rm -rf $(BUILD_DIR)`.

`.PHONY: all check clean run icon dmg codesign-dmg notarize test typecheck validate`.

---

## 4. OmniFlow.entitlements

Единственный ключ:

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

Микрофон под Hardened Runtime. Никаких sandbox-ключей (апп не sandboxed),
никаких entitlements на accessibility/screen-recording (это TCC-разрешения,
не entitlements — фиксировать, чтобы не «чинили» не туда).

---

## 5. Info.plist (базовый, до пропатчивания)

Все ключи и значения:

| Ключ | Значение |
|---|---|
| `CFBundleName` | `OmniFlow` |
| `CFBundleDisplayName` | `OmniFlow` |
| `CFBundleIdentifier` | `com.nick8cyber.omniflow` |
| `CFBundleVersion` | `0.3.0` |
| `CFBundleShortVersionString` | `0.3.0` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleExecutable` | `OmniFlow` |
| `CFBundleIconFile` | `AppIcon` |
| `LSMinimumSystemVersion` | `13.0` |
| `LSUIElement` | `true` |
| `NSMicrophoneUsageDescription` | `OmniFlow needs microphone access to transcribe your speech.` |
| `NSSpeechRecognitionUsageDescription` | `OmniFlow needs speech recognition to convert your voice to text.` |
| `NSAccessibilityUsageDescription` | `OmniFlow needs accessibility access to detect the text cursor position and paste transcribed text.` |

Примечания:

- `LSUIElement = true` — приложение без Dock-иконки по умолчанию; активация
  окон Settings/Setup переключает `NSApp.setActivationPolicy(.regular)` в
  рантайме (спека 30, §2), при закрытии окон — обратно `.accessory`.
- `CFBundleVersion == CFBundleShortVersionString` — build-номер совпадает с
  маркетинговой версией; реальный build-тег (канал/SHA) кладётся CI в
  **отдельный ключ `OmniFlowBuildTag`** (см. спеку 31, §3): `CFBundleName ==
  "OmniFlow Dev"` — признак dev-канала для `AppBuild.isDevBundle` (видимость
  Debug-вкладки и dev-иконки в меню-баре).
- Версия `0.3.0` — базовая на момент референса; релизный CI поднимает её сам.

---

## 6. CI-обвязка (.github, обзор)

Файлы: `workflows/check.yml`, `workflows/dev-release.yml`,
`workflows/release.yml`, `workflows/labeler.yml`, `dependabot.yml`,
`ISSUE_TEMPLATE/{bug,feature,config}.yml`, `pull_request_template.md`,
`scripts/changelog-section.sh`. Валидируются целью `check` (§3.1). Dev-релиз
штампует `OmniFlowBuildTag` (формат `dev-<sha>`), стейбл — тег `v<version>`;
апдейтер (спека 31) читает их из Info.plist.

---

## Чек-лист реализации сборки

- [ ] Переменные: APP_NAME ?= OmniFlow Dev, BUNDLE_ID ?= com.nick8cyber.omniflow.dev, CODESIGN_IDENTITY ?= OmniFlow Dev, ARCH ?= uname -m; экранирование пробела в пути цели
- [ ] SOURCES = find Sources -name '*.swift' | LC_ALL=C sort
- [ ] TEST_PRODUCTION_SOURCES — ровно 13 файлов из §1 (без UI-слоя)
- [ ] all: swiftc -parse-as-library -target <arch>-apple-macosx13.0; universal = arm64 + x86_64 + lipo
- [ ] Бандл: Contents/MacOS + Contents/Resources/AppIcon.icns; plutil -replace: CFBundleName/DisplayName/Executable/Identifier + 3 usage-описания с $(APP_NAME)
- [ ] codesign --force --options runtime --sign identity --entitlements OmniFlow.entitlements
- [ ] check = typecheck (-warnings-as-errors) + test (сборка раннера + запуск) + validate (plutil -lint, bash -n, ruby YAML)
- [ ] icon: sips 10 размеров → iconutil -c icns; выбор dev/stable иконки по APP_NAME
- [ ] dmg: staging + Finder-alias /Applications + create-dmg (параметры §3.3); codesign-dmg; notarize = notarytool + stapler
- [ ] Entitlements: только com.apple.security.device.audio-input = true
- [ ] Info.plist: все ключи §5, LSUIElement, LSMinimumSystemVersion 13.0, CFBundleVersion == CFBundleShortVersionString; OmniFlowBuildTag добавляет CI
