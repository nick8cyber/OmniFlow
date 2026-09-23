# 31 — Апдейтер (UpdateManager)

Спека модуля обновлений. Референс: `Sources/UpdateManager.swift` (916 строк).
Класс `@MainActor final class UpdateManager: ObservableObject`, синглтон
`UpdateManager.shared`. UI-потребители: MenuBarView, SettingsView (General →
Updates), RecordingOverlay (фаза `.updateAvailable`), post-transcription
reminder в AppState.

---

## 1. Источник данных

- URL релизов: `https://api.github.com/repos/nick8cyber/omniflow/releases?per_page=100`
  (константа `releasesURL`; регистр хоста не важен).
- Заголовок запроса: `Accept: application/vnd.github+json`;
  `cachePolicy = .reloadIgnoringLocalCacheData`.
- **Известное ограничение (зафиксировать):** репозиторий приватный. Без
  авторизационного токена GitHub API возвращает **404**, т.е. авто-проверки на
  машинах без доступа к репо всегда получают ветку «404 → обновлений нет»
  (см. §4). Это осознанное поведение: код трактует 404 как «релизов нет»,
  обновляет `lastCheckDate` и молчит (при ручной проверке — «You're Up to Date»).

### Модель ответа

```swift
struct GitHubRelease: Decodable {
    let tagName: String        // "tag_name"
    let name: String?
    let body: String?
    let htmlUrl: String        // "html_url"
    let publishedAt: String    // "published_at" (ISO8601)
    let assets: [GitHubReleaseAsset]
}
struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadUrl: String  // "browser_download_url"
    let size: Int
}
```

Парсинг даты публикации (`releasePublishedDate`): сначала ISO8601 с
`.withInternetDateTime + .withFractionalSeconds`, при неудаче — ISO8601
`.withInternetDateTime`. Обе неудачи → релиз отбрасывается.

---

## 2. SemanticVersion (semver 2.0)

`struct SemanticVersion: Comparable, Equatable { major, minor: Int; patch: Int; prerelease: [String] }`.

### Парсинг `init?(_ value: String)`

1. Trim пробелов/переводов строк.
2. Убрать ведущий `v` или `V`.
3. Отрезать build metadata: всё после первого `+` (`1.2.3+build.1` ≡ `1.2.3`).
4. Разделить по первому `-` на core и prerelease
   (`omittingEmptySubsequences: false`).
5. Core обязан быть ровно **3** числовых компонента через `.` — иначе nil.
6. Prerelease: пустая строка после `-` → nil; компоненты разделяются `.`
   (пустые компоненты запрещены → nil).

Невалидные примеры (проверяются тестом): `""`, `"1.2"`, `"1.2.3.4"`,
`"one.2.3"`, `"1.2.3-"`, `"1.2.3-alpha..1"`.

### Сравнение (`<`) — правила semver 2.0

1. Числово: major → minor → patch.
2. Стабильный релиз (prerelease пуст) **>** любого prerelease той же core-версии.
3. Оба prerelease: попарное сравнение идентификаторов:
   - оба числовые → числовое сравнение;
   - числовое < буквенное;
   - оба буквенные → лексикографическое (ASCII);
   - равные → следующая пара.
4. Если все пары равны — **короче** prerelease-список меньше
   (`1.2.3-alpha < 1.2.3-alpha.1`).

Канонический порядок (используется тестом):
`1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2 <
1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0`.

Вспомогательное: `normalizedVersionString(from:)` — trim + regex-удаление
ведущего `^v` (case-insensitive) для человекочитаемой версии.

---

## 3. Каналы сборок (FreeFlowBuildTag)

- Тег сборки читается из Info.plist: ключ **`OmniFlowBuildTag`**
  (`Bundle.main.infoDictionary?["OmniFlowBuildTag"] as? String`).
  (Историческое имя ключа; в UI Build-карточке это «Build number».)
- Версия текущей сборки — `CFBundleShortVersionString`, fallback `"0.0.0"`.
- **Dev-сборка = `OmniFlowBuildTag` отсутствует (nil)**:
  `if !userInitiated && currentBuildTag == nil { return }` — авто-проверки
  полностью пропускаются; ручная проверка (через меню/Settings) работает.
- Если тег есть и `release.tagName == currentBuildTag` — сборка совпадает с
  последним релизом → «обновлений нет» (до semver-сравнения).
- Каналы по суффиксу тега (`dev-<sha>` и т.п.) фактически обрабатываются
  semver-логикой: теги, не парсящиеся как semver, отбрасываются в
  `releaseCandidates` и не участвуют в выборе обновления.

---

## 4. Цикл проверок

### Расписание

- `checkIntervalSeconds = 7 * 24 * 60 * 60` (7 дней).
- `startPeriodicChecks()`:
  1. **Первая проверка через 5 секунд** после старта
     (`DispatchQueue.main.asyncAfter(deadline: .now() + 5)`).
  2. `Timer.scheduledTimer(withTimeInterval: 3600, repeats: true)` —
     ежечасная **переоценка** условия (переносит sleep/wake);
     `timer.tolerance = 300` (точность не важна, система коалесцирует пробуждения).
- `shouldAutoCheck()`: `autoCheckEnabled` (UserDefaults `updateAutoCheckEnabled`,
  дефолт `true`); `lastCheckDate == nil` → true; иначе
  `Date().timeIntervalSince(lastCheck) > 7 дней`.
- `lastCheckDate` (`@Published`, читается из UserDefaults `updateLastCheckDate`
  в init) при записи пишет себя в UserDefaults (didSet).

### checkForUpdates(userInitiated: Bool) — алгоритм

1. Прочитать `OmniFlowBuildTag` и `CFBundleShortVersionString`.
2. Dev-сборка без тега + авто-проверка → молча выйти (§3).
3. `isChecking = true` (defer → false).
4. GET releases (§1).
   - Ответ не HTTPURLResponse → при ручной проверке алерт «Could not reach GitHub.»
   - **404** → `lastCheckDate = Date()`; сброс
     `updateAvailable/latestRelease/latestReleaseVersion/latestReleaseDate`;
     при ручной проверке — алерт «You're Up to Date». (Сюда попадают и
     запросы к приватному репо без токена — ограничение §1.)
   - Код вне 200..<300 → при ручной «GitHub returned status <code>.»
   - Ошибка декодирования/сети → при ручной «Failed to check for updates: <localizedDescription>».
5. `lastCheckDate = Date()`.
6. Текущая версия не парсится как semver → `updateAvailable = false`; при
   ручной — «The current app version does not use semantic versioning.»
7. `releaseCandidates(from:)`: отфильтровать релизы с валидным semver-тегом и
   парсящейся датой → `SemanticRelease`, **отсортировать** по version
   возрастанию (при равных версиях — по publishedDate).
8. Последний элемент = кандидат. Пусто → «No semantic version release was
   found.» (при ручной).
9. **Агрегированные release notes**: `includedReleases` = все кандидаты `r`,
   где `currentVersion < r.version <= latestVersion`; notes = тела всех
   included в **хронологическом порядке** (reversed отсортированного списка),
   склеенные `"\n\n"`, пустые тела отбрасываются; если ни одного непустого —
   fallback на тело последнего релиза. Сконструированный
   `GitHubRelease` (tag/name/htmlUrl/publishedAt/assets от latest, body —
   агрегат) публикуется в `latestRelease`; также `latestReleaseVersion`
   (нормализованный тег без `v`) и `latestReleaseDate` (DateFormatter
   `.medium`/`.none`).
10. `release.tagName == currentBuildTag` → `updateAvailable = false`; ручная —
    «You're Up to Date».
11. `latestVersion <= currentVersion` → то же.
12. **Stability buffer** (`stabilityBufferDays = 3`):
    `daysSincePublished = Date().timeIntervalSince(publishedDate) / 86400`;
    если `< 3`:
    - авто-проверка — молча `updateAvailable = false` (слишком свежий релиз);
    - ручная — `updateAvailable = true` и диалог «New Release Available» (§6.2).
13. Skip-версия: только для авто-проверки — если `updateSkippedVersion ==
    release.tagName` → `updateAvailable = false`, молча.
14. Иначе `updateAvailable = true`; ручная проверка — сразу `showUpdateAlert()` (§6.1).

Сброс доступного обновления (`clearAvailableUpdate`): `updateAvailable=false`,
`latestRelease=nil`, `latestReleaseVersion=""`, `latestReleaseDate=""`.

---

## 5. Post-transcription reminder

Мягкое напоминание об обновлении после завершения диктовки (AppState вызывает
`shouldShowPostTranscriptionReminder()` / `markPostTranscriptionReminderShown()`,
а RecordingOverlay показывает фазу `.updateAvailable`).

`postTranscriptionReminderInterval = 24 * 60 * 60` (1 сутки).

`shouldShowPostTranscriptionReminder()` → true, только если **все** условия:
- `updateAvailable == true` и `latestRelease != nil` и `updateStatus == .idle`
  (не идёт скачивание/установка) и `updateSkippedVersion != release.tagName`;
- и ( `updateLastPostTranscriptionReminderVersion != release.tagName` **или**
  даты нет — ни разу не напоминали для этой версии; **или**
  `Date().timeIntervalSince(lastReminderDate) > 24 ч` ).

`markPostTranscriptionReminderShown()`: записать
`updateLastPostTranscriptionReminderVersion = release.tagName` и
`...ReminderDate = Date()`. Тот же эффект у приватного
`suppressPostTranscriptionReminder(for:)` — вызывается из кнопок «Remind Me
Later» / «Wait» в диалогах.

---

## 6. Диалоги (NSAlert, все `.alertStyle = .informational`, иконка
`NSApp.applicationIconImage`)

### 6.1 showUpdateAlert — «A New Version is Available»

- messageText: `"A New Version is Available"`.
- informativeText: `"\(AppName.displayName) \(versionText) was released
  \(latestReleaseDate).\n\nWould you like to download the update?"`, где
  `versionText` = `latestReleaseVersion.isEmpty ? release.tagName :
  "v\(latestReleaseVersion)"`.
- Кнопки (по порядку) и обработка:
  1. **Download Update** → `downloadAndInstall(release:)`.
  2. **What's New** → `showReleaseNotes(for:)`, затем **повторно**
     `showUpdateAlert()` (цикл до явного решения).
  3. **Remind Me Later** → `suppressPostTranscriptionReminder(tagName)`
     (не скрывает баннер, откладывает post-dictation напоминание на сутки).
  4. **Skip This Version** → `skippedVersion = release.tagName`
     (`updateSkippedVersion`) + `clearAvailableUpdate()`.

### 6.2 showRecentReleaseAlert — «New Release Available» (stable buffer, ручная проверка)

- ageText: `< 1 ч` → «less than an hour ago»; `< 24 ч` → `"\(h) hour(s) ago"`;
  иначе `"\(d) day(s) ago"`.
- informativeText: «… was released <ageText>. It's very recent — you can
  download it now or wait a few days for stability.\n\nWould you like to download it?»
- Кнопки: **Download Now** → install; **What's New** → notes + повтор диалога;
  **Wait** → `suppressPostTranscriptionReminder` + `updateAvailable = false`.

### 6.3 showUpToDateAlert

«You're Up to Date» / «You're running the latest version of \(AppName.displayName).»,
одна кнопка OK. Показывается при ручной проверке без обновления.

### 6.4 showErrorAlert

«Update Check Failed» / произвольный текст, `.warning`, OK. Только для
`userInitiated` проверок.

### 6.5 Release notes (showReleaseNotes)

- messageText: `"What's New in \(AppName.displayName) \(versionText)"`;
  informativeText: `"Release notes from GitHub."`.
-Accessory: `NSScrollView` **520×280** (bezel border, вертикальный скролл) c
  `NSTextView` (read-only, selectable, textBackgroundColor, inset 10×10).
- Рендер markdown-подмножества (`releaseNotesAttributedString`), построчно:
  - `### ` → bold `systemFontSize + 1` (заголовок-подзаголовок);
  - `## ` → bold `systemFontSize + 3`;
  - `- ` → строка `"• " + остаток`, параграф-стиль с `headIndent = 16`;
  - остальное — обычный шрифт; `lineSpacing = 2`; `paragraphSpacing` 6 (обычный) / 4 (буллеты);
  - инлайн `**bold**` → `NSFontManager` bold (незакрытый `**` — остаток как обычный текст).
- Срез заметок: если в body есть `"\n## Download"` — показывается только всё
  до него (секция «Download» с инструкциями скрывается). Пустое body →
  «No release notes were published for this version.»
- Кнопки: OK; и **Open on GitHub** (если `URL(string: htmlUrl)` валиден) →
  `NSWorkspace.shared.open`.

---

## 7. Загрузка и установка

### 7.1 Выбор ассета

`downloadAndInstall(release:)`: ищем первый asset с `name.hasSuffix(".dmg")`.
Нет DMG → просто открыть `htmlUrl` в браузере. Есть — отменить активную задачу
(`activeDownloadTask?.cancel()`) и запустить `Task { performUpdate(...) }`.

`cancelDownload()`: cancel задачи; `downloadProgress = nil`; `updateStatus = .idle`.

### 7.2 performUpdate — фазы

Состояния `UpdateStatus: idle → downloading → installing → readyToRelaunch`
или `error(String)`.

**Подготовка**: временный каталог
`tmp/omniflow-update-<UUID>/`, файл `OmniFlow.dmg`. Ошибка создания →
`.error("Failed to create temp directory: …")`.

**Downloading**:
- `updateStatus = .downloading`, `downloadProgress = 0`.
- `URLSession.shared.bytes(for:)` (запрос с `.reloadIgnoringLocalCacheData`);
  `totalSize` = Content-Length или `asset.size`.
- Запись в файл через `FileHandle` в `Task.detached`: буфер **65 536** байт,
  флаш на диск по заполнению; **прогресс троттлится до ~30 fps** — обновление
  `downloadProgress = receivedBytes / totalSize` не чаще, чем раз в **0.033 c**
  (по `CFAbsoluteTimeGetCurrent`), пуш на MainActor.
- Хвост буфера дописывается; `downloadProgress = 1.0`.
- `CancellationError` / `URLError.cancelled` → тихо удалить temp-каталог,
  статус не трогать. Прочая ошибка → `.error("Download failed: …")`,
  `downloadProgress = nil`, удалить temp.

**Installing**:
- `updateStatus = .installing`, `downloadProgress = nil`.
- `mountDMG`: `/usr/bin/hdiutil attach <dmg> -nobrowse -noverify -noautoopen -plist`
  (stdout в pipe); ненулевой exit → ошибка «hdiutil attach failed with exit code N».
  Парс plist (`PropertyListSerialization`) → `system-entities` → первый
  `mount-point`. Нет — «No mount point found in hdiutil output».
- **defer: всегда** `/usr/bin/hdiutil detach <mount> -quiet`.
- Найти `.app` в корне тома (`contentsOfDirectory`, первый с pathExtension
  `app`); нет → `.error("No .app found in DMG.")`.
- Стейджинг: `tmp/omniflow-staged-<UUID>/<AppName>.app`, `copyItem`.
- Удалить update-temp-каталог.
- `updateStatus = .readyToRelaunch` → `replaceAndRelaunch(stagedApp:stagingDir:)`.
- Любая ошибка фазы → `.error("Install failed: …")` + очистка temp.

### 7.3 replaceAndRelaunch — bash-скрипт с argv-массивом

```bash
while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
mv "$2" "$5" && mv "$3" "$2" && open "$2" && rm -rf "$4" "$5" \
    || { mv "$5" "$2" 2>/dev/null; exit 1; }
```

Запуск: `Process`, executableURL `/bin/bash`,
`arguments = ["-c", script, "--", pid, currentAppPath, stagedApp.path, stagingDir.path, backupPath]` —
**аргумент-массив, не строковая интерполяция** (защита от injection;
зафиксировать как требование).

Переменные: `$1` = PID текущего процесса; `$2` = `Bundle.main.bundlePath`;
`$3` = стейдженный .app; `$4` = staging-каталог; `$5` = `currentAppPath + ".bak"`.

Семантика: ждать смерти процесса (poll 0.2 c) → старый .app в `.bak` (сначала
move — чтобы неудачный mv не оставил машину без приложения) → staged на место
старого → `open` нового → удалить staging и `.bak`; при любой неудаче —
откатить `.bak` назад и выйти с 1.

Затем сразу `try? process.run()` и **`NSApp.terminate(nil)`** — текущий инстанс
завершается, скрипт дождивается и подменяет.

Замечание: `mv` на ту же файловую систему атомарен; обновление работает и для
/app, и для ~/Applications-установок.

---

## 8. Сводка констант

| Константа | Значение |
|---|---|
| `releasesURL` | `https://api.github.com/repos/nick8cyber/omniflow/releases?per_page=100` |
| Accept-заголовок | `application/vnd.github+json` |
| `stabilityBufferDays` | 3 |
| `checkIntervalSeconds` | 604 800 (7 дней) |
| Первая проверка | через 5 c после `startPeriodicChecks()` |
| Переоценка | Timer 3600 c, tolerance 300 c |
| `postTranscriptionReminderInterval` | 86 400 c (1 сутки) |
| Буфер скачивания | 65 536 байт |
| Троттлинг прогресса | 0.033 c (~30 fps) |
| hdiutil attach | `-nobrowse -noverify -noautoopen -plist` |
| hdiutil detach | `-quiet` (в defer) |
| Release notes view | NSScrollView 520×280 |
| Подмена | bash -c, argv после `--`: pid, appPath, stagedPath, stagingDir, appPath.bak |

---

## Чек-лист реализации апдейтера

- [ ] GitHubRelease/GitHubReleaseAsset c точными coding keys; парсинг даты в двух ISO8601-форматах
- [ ] SemanticVersion: strip v/V, build metadata, ровно 3 числовых компонента, prerelease по semver 2.0 (числа < букв, короче список меньше); все негативные кейсы из §2
- [ ] Приватный репо: 404 без токена трактуется как «нет релизов» (зафиксированное ограничение)
- [ ] Каналы: OmniFlowBuildTag из Info.plist; нет тега → пропуск только авто-проверок; tag == tagName → up-to-date
- [ ] Расписание: первая через 5 c, hourly timer 3600 c tolerance 300 c, shouldAutoCheck по 7-дневному интервалу и updateAutoCheckEnabled
- [ ] Стабильность: авто-проверка молчит при возрасте < 3 дней; ручная — диалог «New Release Available» с тремя кнопками
- [ ] Skip-версия применяется только в авто-проверке
- [ ] Агрегированные notes между текущей и последней версиями (хронологически, через \n\n)
- [ ] Post-transcription reminder: условия §5, интервал 24 ч, suppress из «Remind Me Later»/«Wait»
- [ ] Все 5 диалогов NSAlert с точными текстами, кнопками и повторными вызовами (What's New → снова диалог)
- [ ] Рендер notes: ##/###/-/**bold**/срез до «\n## Download»
- [ ] Скачивание: стриминг 64 KiB, прогресс 30 fps, отмена чистит temp
- [ ] Установка: hdiutil attach -plist → detach в defer → copyItem в staging → bash-скрипт с argv-массивом (ждать PID → .bak → swap → open → rm) → NSApp.terminate
