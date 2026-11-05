# Спецификация 12 — ModelConfiguration и парсеры (`TranscriptTextCore`)

Референс: FreeFlow / OmniFlow, `Sources/ModelConfiguration.swift`, `Sources/TranscriptTextCore.swift`.

---

## 1. `ModelConfig` / `ModelConfiguration`

```swift
public struct ModelConfig {
    public let maxCompletionTokens: Int?
    public let reasoningEffort: String?
    public let includeReasoning: Bool?
    public let shouldStripThinkTags: Bool
}
```

`nil` в опциональных полях означает «параметр в запрос не добавляется». `shouldStripThinkTags` управляет вызовом `ModelConfiguration.stripThinkTags` над `choices[0].message.content` (см. `11-postprocessing.md`, раздел 4.5).

### 1.1. Нормализация алиасов

`config(for:)` сначала приводит модель: trim + lowercased, затем алиасы без провайдера разворачиваются:

| Вход | Нормализуется в |
|---|---|
| `qwen3-32b` | `qwen/qwen3-32b` |
| `qwen3.6-27b` | `qwen/qwen3.6-27b` |
| `gpt-oss-20b` | `openai/gpt-oss-20b` |
| `gpt-oss-120b` | `openai/gpt-oss-120b` |
| `gpt-oss-safeguard-20b` | `openai/gpt-oss-safeguard-20b` |

### 1.2. Таблица конфигов

| Модель (после нормализации) | maxCompletionTokens | reasoningEffort | includeReasoning | shouldStripThinkTags |
|---|---|---|---|---|
| `openai/gpt-oss-20b` | `4096` | `"low"` | `false` | `false` |
| `openai/gpt-oss-120b` | `nil` | `nil` | `nil` | `false` |
| `openai/gpt-oss-safeguard-20b` | `nil` | `nil` | `nil` | `false` |
| `qwen/qwen3-32b` | `nil` | `nil` | `nil` | **`true`** |
| `qwen/qwen3.6-27b` | `nil` | **`"none"`** | **`false`** | **`true`** |
| `llama-3.1-8b-instant` | `nil` | `nil` | `nil` | `false` |
| `llama-3.3-70b-versatile` | `nil` | `nil` | `nil` | `false` |
| `meta-llama/llama-4-scout-17b-16e-instruct` | `nil` | `nil` | `nil` | `false` |
| `meta-llama/llama-prompt-guard-2-22m` | `nil` | `nil` | `nil` | `false` |
| `meta-llama/llama-prompt-guard-2-86m` | `nil` | `nil` | `nil` | `false` |
| `allam-2-7b` | `nil` | `nil` | `nil` | `false` |
| `canopylabs/orpheus-arabic-saudi` | `nil` | `nil` | `nil` | `false` |
| `canopylabs/orpheus-v1-english` | `nil` | `nil` | `nil` | `false` |
| `groq/compound` | `nil` | `nil` | `nil` | `false` |
| `groq/compound-mini` | `nil` | `nil` | `nil` | `false` |
| `whisper-large-v3` | `nil` | `nil` | `nil` | `false` |
| `whisper-large-v3-turbo` | `nil` | `nil` | `nil` | `false` |
| **любая другая (fallback)** | `nil` | `nil` | `nil` | `false` |

Особенности, которые легко потерять при переписывании:
- Единственная модель с `maxCompletionTokens: 4096` в таблице — `openai/gpt-oss-20b`. (Отдельно в `PostProcessingService` есть страховка: если конфиг вернул `nil`, а модель == дефолтная, всё равно ставится 4096 / `"low"` / `false`.)
- `qwen/qwen3.6-27b` — единственная с `reasoningEffort: "none"`; плюс `includeReasoning: false` и strip think tags.
- `qwen/qwen3-32b` — strip think tags, но без прочих параметров (в списке `llmModels` её нет, алиас оставлен для совместимости).
- Strip think tags включён ровно у трёх моделей: `qwen/qwen3-32b`, `qwen/qwen3.6-27b` — и ни у кого больше.

### 1.3. `stripThinkTags(_:)` — точные regex

Назначение: удалить `think`-блоки из НАЧАЛА ответа; незакрытый тег (модель упёрлась в лимит токенов) срезается до конца строки.

```swift
// 1. Полностью закрытые блоки, в том числе несколько подряд:
let closedRegexPattern = "^(?:\\s*<think>[\\s\\S]*?</think>)+"
// т.е. ^(?:\s*<think>[\s\S]*?</think>)+   — заменить на ""

// 2. Незакрытый <think> — от открывающего тега до конца строки:
let openRegexPattern = "^\\s*<think>[\\s\\S]*$"
// т.е. ^\s*<think>[\s\S]*$                — заменить на ""

return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
```

Важно: оба паттерна **якорены на начало строки** — `<think>` в середине ответа не режется.

### 1.4. Списки моделей

```swift
public static let llmModels = [
    "openai/gpt-oss-20b",
    "openai/gpt-oss-120b",
    "openai/gpt-oss-safeguard-20b",
    "qwen/qwen3.6-27b",
    "groq/compound",
    "groq/compound-mini"
]

// Vision-capable: контекстная модель обязана уметь картинки (скриншот-анализ).
public static let visionModels = [
    "qwen/qwen3.6-27b"
]

public static let transcriptionModels = [
    "whisper-large-v3",
    "whisper-large-v3-turbo",
    // Свой ключ и provider URL в transcription overrides; smart mode
    // сам чистит текст, пост-обработке остаётся меньше работы.
    "gemini-3.5-transcribe"
]
```

Дефолт контекстной модели: `AppContextService.defaultContextModel = "qwen/qwen3.6-27b"` (vision-модель — обязательное условие для скриншотов).

---

## 2. `TranscriptionResponseParser` — парсинг ответа батч-транскрипции

```swift
enum TranscriptionResponseParsingError: Error, Equatable {
    case invalidResponse
}

static func parse(_ data: Data) throws -> String
```

Алгоритм:
1. `JSONSerialization.jsonObject`; ошибка парсинга → `invalidResponse`.
2. Если это объект и в нём `"text"` — строка:
   - `isHallucination(text:json:)` == true → вернуть `""` (пустая строка — легитимный «тишина/шум»);
   - иначе вернуть текст как есть.
3. **Не-JSON fallback** (некоторые провайдеры/шлюзы отвечают plain text): весь body как UTF-8; переносы строк (`components(separatedBy: .newlines)`) склеиваются пробелом; trim. Пусто → `invalidResponse`. Иначе вернуть.

### 2.1. Фильтр галлюцинаций Whisper

Стоковые фразы Whisper для тишины/фонового шума (точное множество, после нормализации):

```swift
private static let hallucinationPhrases: Set<String> = [
    "thank you",
    "thank you for watching",
    "thank you very much",
    "thank you so much",
    "thanks for watching",
    "please subscribe",
    "like and subscribe",
    "subtitles by",
    "subtitles by the amara.org community",
    "you"
]
```

Нормализация кандидата: `text.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))` — только точное совпадение со всей строкой.

Порог:

```swift
private static let hallucinationNoSpeechThreshold = 0.1
```

(Подобран консервативно примерно на 500 записях — тихих, шумных и с реальной речью — чтобы не фильтровать настоящие короткие диктовки.)

Условие фильтрации — ВСЕ должны выполняться:
1. Нормализованный текст входит в `hallucinationPhrases`.
2. В JSON есть `segments: [[String: Any]]` (массив). Нет — фильтр ПРОПУСКАЕТСЯ (лог «provider response has no segments/no_speech metadata») → текст возвращается. Это защищает короткие настоящие «thank you» у провайдеров без verbose_json.
3. `segments.first["no_speech_prob"]` читается как `Double`. Отсутствует — фильтр пропускается (лог «provider response omitted no_speech_prob»).
4. `no_speech_prob >= 0.1` → галлюцинация → `""`.

Обратите внимание на направление порога: 0.1 — низкий барьер; даже небольшая вероятность «нет речи» вместе со стоковой фразой даёт фильтрацию. Это pairs с `response_format = verbose_json` из `10-transcription.md`: только verbose_json-модели дают `segments`.

---

## 3. `TranscriptOutputSanitizer`

### 3.1. `postProcessedTranscript(_:)` — cleanup

```
trim whitespace → пусто → ""
→ если обрамлён одной парой двойных кавычек (hasPrefix "\"" && hasSuffix "\"" && count > 1):
     снять первую и последнюю, trim снова
→ если результат == "EMPTY" → ""
→ иначе вернуть
```

### 3.2. `verbatimTranslation(_:)`

```
trim → пусто → ""
→ снять одну пару обрамляющих двойных кавычек, trim
→ вернуть (сознательно НЕ конвертирует "EMPTY" — в переводе это может быть легитимная речь)
```

### 3.3. `commandModeTranscript(_:)`

Только `trimmingCharacters(in: .whitespacesAndNewlines)`. Никаких кавычек, никакого EMPTY.

### 3.4. `appearsToHaveExecutedInstruction(rawTranscript:cleanedTranscript:outputLanguage:)` — детектор guard

Полное описание (множества, regex, формулы, предусловия) — в `11-postprocessing.md`, раздел 6. Здесь только точные константы для перекрёстной проверки:

- Предусловие-страж: `outputLanguage` после trim НЕ пуст → `false` (guard отключён при переводе).
- `instructionMarkers` (21 слово): `ask, answer, compose, create, draft, email, generate, make, message, prompt, reply, respond, response, summarize, tell, translate, write, claude, chatgpt, ai, llm`.
- `assistantPreamblePattern`: `(?i)^\s*(sure|certainly|absolutely|here(?:'s| is)|i(?:'d| would) be happy to|i can)\b` — применяется и к cleaned, и к raw (`options: .regularExpression`).
- StopWords токенизатора (точный список):

```swift
"a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could",
"for", "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
"in", "into", "is", "it", "its", "just", "me", "my", "of", "on", "or", "our",
"please", "she", "so", "that", "the", "their", "them", "then", "there", "this",
"to", "um", "uh", "was", "we", "were", "what", "when", "where", "who", "with",
"would", "you", "your"
```

- Токен значим: `token.count > 1 && !stopWords.contains(token)`; split по `!isLetter && !isNumber`; всё lowercased.
- Вердикт `true` ⇔ `(cleanedHasPreamble && !rawHasPreamble) || (preservedMarkers.isEmpty && overlapRatio < 0.35)`, где `overlapRatio = |rawTokens ∩ cleanedTokens| / max(|rawTokens|, 1)`.

---

## 4. Лог ошибок и логгирование (для воспроизведения наблюдаемости)

- OSLog subsystem: `"com.nick8cyber.omniflow"`; categories: `"Transcription"` (TranscriptionService и TranscriptTextCore), `"RealtimeTranscription"`, `"GeminiLiveTranscription"`.
- TranscriptTextCore логирует пропуск фильтра галлюцинаций на уровне `.info`.

---

## Чек-лист «что должно получиться в коде»

- [ ] `ModelConfig` с четырьмя полями; `config(for:)` c нормализацией trim+lowercase и пятью алиасами без провайдера.
- [ ] Таблица конфигов 1-в-1: 4096/`"low"`/false только у `openai/gpt-oss-20b`; `"none"`+false+strip у `qwen/qwen3.6-27b`; strip у `qwen/qwen3-32b`; fallback — все `nil`/`false`.
- [ ] `stripThinkTags`: два якоренных regex `^(?:\s*<think>[\s\S]*?</think>)+` и `^\s*<think>[\s\S]*$`, затем trim; вызывается только при `shouldStripThinkTags`.
- [ ] Списки `llmModels` (6 моделей), `visionModels` (`qwen/qwen3.6-27b`), `transcriptionModels` (`whisper-large-v3`, `whisper-large-v3-turbo`, `gemini-3.5-transcribe`).
- [ ] Парсер ответа транскрипции: JSON `text` → hallucination check → текст или `""`; не-JSON → склейка строк пробелом + trim; пусто → `invalidResponse`.
- [ ] Галлюцинации: точные 10 фраз, нормализация lowercase + срез пунктуации/пробелов по краям, порог `no_speech_prob >= 0.1` по `segments.first`, отсутствие segments/prob — фильтр пропускается.
- [ ] Санитайзеры: `postProcessedTranscript` (кавычки + `EMPTY`→""), `verbatimTranslation` (кавычки, EMPTY сохраняется), `commandModeTranscript` (только trim).
- [ ] Guard-детектор: маркер-множество (21 слово), preamble-regex, stopWords (точный список), overlap-порог 0.35, страж пустого Output Language.
