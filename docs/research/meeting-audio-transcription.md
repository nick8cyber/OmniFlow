# Исследование: запись и транскрипция голосовых звонков и конференций на macOS

- **Дата:** 2026-09-24
- **Ветка:** `rewrite`
- **Статус:** research (не спека); факты проверены по официальным документам, перечисленным в разделе «Источники». Всё, что требует живой проверки на нашем API-ключе, вынесено в «Открытые вопросы».
- **Контекст кодовой базы:** сейчас OmniFlow пишет микрофон через `AVCaptureSession` (спека `20-audio.md`), транскрипция — Groq Whisper батч, Gemini `gemini-3.5-transcribe` через Interactions API (режим `smart`) и `gemini-3.5-transcribe-live` по WebSocket `BidiGenerateContent` (спека `10-transcription.md`).

---

## Executive summary

1. **Гипотеза владельца подтверждена наполовину.** Модели Google Transcribe действительно умеют детектировать смену говорящих: `gemini-3.5-transcribe` с `"diarization_mode": "speaker"` в `transcription_config.mode` размечает реплики метками `spk_1`, `spk_2`, … до 8 спикеров. НО: (а) диаризация работает **только в режиме `verbatim`** — с `smart` несовместима (официально: «smart is not compatible with timestamp_granularities and diarization_mode»); (б) в **Live-стриминге диаризации нет вообще** (матрица Google: Live — «Not Supported»); (в) атрибуция для 3+ спикеров — Experimental; (г) при включённой диаризации/таймстампах лимит запроса падает с 1 часа до **30 минут**; (д) `custom_vocabulary` **несовместим с диаризацией** — API отклоняет запросы, где они вместе (а наш код сейчас всегда шлёт `custom_vocabulary`, если список непуст).
2. **Рекомендованный технопуть захвата: Core Audio Process Taps (macOS 14.4+)** — per-process тап (Zoom/Telegram/любое приложение) или system-wide тап, без драйверов и без Screen Recording permission. Нужен только TCC-промпт «Audio Capture» (`NSAudioCaptureUsageDescription` в Info.plist). Референс-реализация — `insidegui/AudioCap` (BSD-2): `CATapDescription` → `AudioHardwareCreateProcessTap` → private aggregate device → `AudioDeviceCreateIOProcIDWithBlock`. AudioCap работает в sandbox с обычными entitlements — спец-entitlement не нужен. Для быстрой проверки статуса разрешения AudioCap использует приватный TCC SPI (`kTCCServiceAudioCapture`) под build-флагом — для нотаризации ок, для App Store рискованно (можно жить без SPI: промпт придёт сам при первом тапе).
3. **Фолбэк для macOS 13: ScreenCaptureKit** (`SCStreamConfiguration.capturesAudio`, macOS 13+; per-app аудио — macOS 15+ через content filter). Цена — Screen Recording permission и то, что тянешь его ради аудио. Виртуальные драйверы (BlackHole — GPL-3.0/коммерческая лицензия, Loopback/ARK-SDK — коммерческое, Soundflower мёртв) — последний фолбэк, не рекомендуем: установка драйвера + ручной Multi-Output Device = худший UX.
4. **Универсальный путь для «любого звонка» — тап системного вывода**: звонилки (Zoom/Teams/Meet/Telegram) расшифровывают и проигрывают удалённый звук локально, поэтому он всегда присутствует в системном миксе. Отдельные треки участников «из коробки» даёт только локальная запись Zoom (опция «separate audio file per participant»); Meeting SDK raw audio — отдельная лицензия/approval через Zoom Marketplace. E2E-звонки Telegram не мешают: ключи шифрования и декодирование — на устройстве пользователя, в системный вывод уходит уже расшифрованный звук.
5. **Рекомендация v2 (диаризация): батч-транскрипция каждой дорожки отдельно.** Дёшево и надёжно: 2 известных канала — «мой микрофон» и «системный вывод» (удалённые участники смешаны). Системный канал → `gemini-3.5-transcribe` с `mode: {type: "verbatim", diarization_mode: "speaker"}` (метки `spk_N` для удалённых), микрофонный канал → как «Me». Звонки >30 мин — резать на чанки с перекрытием; метки `spk_N` между чанками модель не «сшивает» — нужен клиентский ремаппинг (по голосовому сходству или по порядку). Для `smart` (чистый текст без меток) диаризация недоступна по определению — компромисс: вербатим-диаризация для звонков, smart для диктовки.
6. **Рекомендация v3 (live): две параллельные Gemini Live-сессии** (микрофон + системный тап), метка канала клеится клиентом. Live-диаризации нет; сессии длиннее 15 мин (audio-only) требуют `contextWindowCompression` + `sessionResumption`; lifetime одного соединения ~10 мин — обязателен авто-reconnect.
7. **Квоты/цены не блокируют:** транскрипция ~$0.005/мин (≈$0.30/час звонка), Live ~$0.009/мин; есть free tier. Токены: ~25 audio tokens/s (транскрибирующая модель; generic-аудио в Gemini считается 32 tokens/s) → 60 мин ≈ 90–115k токенов — в контекст влезает. **Inline-лимит ~20 MB на запрос — не влезает**: наш WAV 16 kHz mono PCM16 = 1.92 MB/мин → уже с ~11 минут превышение. Для звонков нужен **Files API** (загрузка файла, потом file_uri) или сжатие (Opus/M4A ~24–32 kbps: час ≈ 11–14 MB). Уточнить совместимость Files API с Interactions API — см. «Открытые вопросы».

---

## 1. Перехват системного аудио на macOS

### 1.1 Core Audio Process Taps (macOS 14.4+) — рекомендованный путь

Apple ввела публичный API тапов процессов в CoreAudio начиная с **macOS 14.4 Sonoma**. Как работает (по README и коду `insidegui/AudioCap` — рабочее production-приложение на этом API):

1. Найти целевой процесс: `kAudioHardwarePropertyTranslatePIDToProcessObject` — PID (Zoom, Telegram, …) → `AudioObjectID` аудио-процесса. Либо system-wide тап (весь вывод системы).
2. Создать описание тапа: `CATapDescription` (AudioToolbox) — per-process или system-wide; опции: mono/stereo downmix, mute-поведение (глушить ли исходный вывод у пользователя).
3. `AudioHardwareCreateProcessTap(description, handler)` → `AudioObjectID` тапа, у тапа есть UUID.
4. Создать **private aggregate device** (`AudioHardwareCreateAggregateDevice`), включив тап как sub-device (`kAudioSubTapUIDKey`), флаг `kAudioAggregateDeviceIsPrivateKey = true`, чтобы девайс не светился в общесистемном списке.
5. Получать сэмплы через `AudioDeviceCreateIOProcIDWithBlock` на aggregate device; дальше обычный `AVAudioPCMBuffer` → конвертация → файл/сокет (наш существующий конвейер из `20-audio.md` переиспользуется почти целиком, меняется только источник буферов).

**Разрешения и entitlements (по фактическому коду AudioCap):**

| Требование | Значение |
|---|---|
| Info.plist | `NSAudioCaptureUsageDescription` — **ключ вводится вручную** (нет в выпадашке Xcode) |
| TCC-сервис | `kTCCServiceAudioCapture` («Audio Recording») — системный промпт согласия при первом тапе |
| Спец-entitlement | **Не нужен.** AudioCap собирается с `app-sandbox: true` + `com.apple.security.device.audio-input` + files.user-selected — и тапает чужие процессы |
| Проверка статуса разрешения | Публичного API нет («There's no public API to request audio recording permission or to check if the app has that permission»). AudioCap опционально использует приватный TCC SPI (preflight + request, `ENABLE_TCC_SPI`) |
| App Store | Приватный TCC SPI — риск ревью. Без SPI всё работает: промпт просто приходит при первом старте записи. Нотаризация — без проблем |
| Ограничение процессов | Тапается аудио-процесс, у которого есть активный audio output. Тап процесса, который не играет — пусто/ошибка (`kAudioHardwareIllegalOperationError` и родня) |

Вывод: это заменяет и ScreenCaptureKit, и драйверы на macOS 14.4+; согласие пользователя — один TCC-промпт, как у микрофона. AudioCap «обошёл» не согласие, а отсутствие API его проверки: тот же системный промпт вызывается проактивно через SPI, а сам тап легален и без SPI.

### 1.2 ScreenCaptureKit (macOS 13+, per-app аудио — macOS 15+)

- `SCStreamConfiguration.capturesAudio = true` (macOS 13.0+, default false) — поток получает системный аудио-микс как `CMSampleBuffer` (обычно 48 kHz float32; настраиваются `sampleRate`, `channelCount`, `excludesCurrentProcessAudio` — чтобы не зациклить собственный вывод).
- **Per-app аудио:** в macOS 15 фильтр контента (`SCContentFilter` с включением/исключением `SCRunningApplication`) распространяется и на аудио — можно взять звук только Zoom. На 13/14 — только системный микс.
- Микрофон через SCK **не захватывается** — микрофон остаётся на `AVCaptureSession` (наш текущий путь).
- Цена: **Screen Recording TCC permission** — отдельный и более «страшный» промпт (юзер чувствует слежку за экраном); `SCShareableContent` гейтится этим разрешением целиком, аудио-only пути без него нет.
- Качество/задержки: приемлемо для транскрипции; задержка выше, чем у тапов, буферы приходят вместе с видео-тактированием потока (нужен минимальный video config или `SCStreamConfiguration` только аудио — работает, но документирован слабее).

Когда брать: фолбэк для macOS 13.0–14.3, если захотим поддерживать их без драйверов.

### 1.3 Виртуальные аудио-устройства / драйверы

| Решение | Модель | Лицензия | Комментарий |
|---|---|---|---|
| BlackHole | виртуальный loopback-девайс (kext-драйвер по мотивам Apple NullAudio) | **GPL-3.0**; «A license is required for all non-GPLv3 projects» — для закрытого OmniFlow нужна коммерческая лицензия у автора | Бесплатен для пользователя; установка — pkg с admin-правами и подтверждением системного расширения; на Apple Silicon возможны предупреждения безопасности |
| Loopback / Audio Hijack (Rogue Amoeba) | пользовательский «Audio Capture Engine» (ACE), виртуальные девайсы без kext | Коммерческий продукт ($99 Loopback) | Встраивать нельзя; для third-party интеграции Rogue Amoeba лицензирует технологию (ARK-SDK / «Licensing Technology from Rogue Amoeba») — переговоры + роялти |
| Soundflower | легаси-kext | OSS, **мёртв** (не обновляется, проблемы на современных macOS) | Не рассматривать |
| DriverKit-аудио | — | Публичного семейства аудио-DriverKit нет; свои аудио-драйверы — это либо kext (угасающий путь), либо HAL-плагин в `coreaudiod` (вне-sandbox демон + installer) | Самый дорогой по поддержке путь |

Схема «Multi-Output Device» (BlackHole + реальные колонки): пользователь вручную в Audio MIDI Setup создаёт aggregate, переключает системный вывод на него, после звонка переключает обратно. Не забыть: в multi-output **нельзя контролировать громкость клавишами и нет автопереключения устройств** — это худший UX из всех вариантов. Итог: виртуальные девайсы — только как опция «для macOS 13 и для параноиков», не основной путь.

### 1.4 Веб-путь (для полноты карты)

Google Meet в браузере можно записывать через Chrome extension с `chrome.tabCapture` (звук только вкладки, есть индикатор записи) — это отдельный продукт (extension), не интегрируемый в нативное приложение напрямую. Упомянуто для карты решений; в OmniFlow не берём — у нас нативный тап покрывает Meet-вкладку в Chrome как обычный процесс (браузер).

### 1.5 Микрофон + системный звук: микширование, эхо, каналы

- Два источника = два независимых потока: наш `AVCaptureSession` (микрофон, уже есть) + тап системного вывода (новый `ProcessTapRecorder` по образцу `AudioRecorder`).
- Микшировать в один моно-поток — ошибка для диаризации: теряем границу «я vs остальные». Правильно: **раздельные каналы до транскрипции** (см. раздел 3.2), файл звонка можно дополнительно писать стерео (L=микрофон, R=система).
- Эхо: если удалённые слышат нас через колонки, микрофон ловит и их голос (echo). Полного решения на нашей стороне нет (это задача AEC звонилки); частично лечится тем, что системный тап даёт чистый удалённый звук, а дубль в микрофоне слабее и сдвинут по времени — на батч-транскрипции почти не влияет. Наушники — рекомендация в UI.
- Устройства: у пользователя может быть выбран не-дефолтный микрофон (наш селектор уже умеет); системный тап всегда берёт вывод «в динамики» независимо от устройства вывода.

### 1.6 Итоговая матрица вариантов захвата

| Вариант | macOS | Разрешения | Per-app / системный | Цена / лицензии | Сложность внедрения | Риски | UX |
|---|---|---|---|---|---|---|---|
| **Core Audio Process Tap** | 14.4+ | TCC «Audio Capture» (1 промпт), `NSAudioCaptureUsageDescription` | Оба (PID или system-wide) | Бесплатно, свой код | Средняя: aggregate device + IOProc (~несколько дней по образцу AudioCap) | Приватный TCC SPI — только опционально; тап неиграющего процесса пуст | Лучший: промпт как у микрофона, ничего вручную |
| **ScreenCaptureKit** | 13+ (per-app 15+) | **Screen Recording** TCC | Системный (13/14), per-app (15+) | Бесплатно | Средняя (SCStream + CM SampleBuffers) | «Страшный» промпт; аудио гейтится тем же разрешением, что и экран | Приемлемый, но промпт пугает |
| BlackHole + Multi-Output | 12+ | Нет TCC (аудио уже «наш») | Системный (всё, что выведено в девайс) | GPL-3.0 / коммерч. лицензия | Низкая в коде, высокая в онбординге | Установка драйвера; поломка звука при неверной конфигурации | Худший: ручной Audio MIDI Setup, переключения до/после |
| Loopback/ARK-SDK | 12+ | Нет TCC | Оба | Коммерческое лицензирование Rogue Amoeba | Низкая | Цена, вендор-лок | Хороший, но платный |
| Zoom локальная запись (файлы) | — | Нет наших разрешений | Per-участник (отдельные файлы!) | Бесплатно | Низкая (парсинг папки `Zoom/`) | Требует настройки Zoom хостом; не live | Плохой (вне приложения) |
| Meeting SDK raw audio | — | Свои SDK-ключи | Per-участник | Лицензия/approval Zoom Marketplace | Высокая | Лицензирование; bots-подход = отдельный участник | Специфичный |
| Chrome tabCapture (Meet) | — | Разрешение extension | Вкладка браузера | Бесплатно | Отдельный extension | Не нативно | Отдельный путь |

---

## 2. Специфика приложений

- **Zoom.** Системный тап ловит смешанный звук конференции (всё, что играет динамики). Бонус: у Zoom есть локальная запись с опцией **«Record a separate audio file of each participant who speaks»** — на выходе отдельный WAV на участника; OmniFlow теоретически может импортировать эти файлы (per-участник диаризация бесплатно, но пост-фактум и при настройке хоста). Meeting SDK rawdata (raw audio access) требует отдельной лицензии/approval от Zoom — не наш путь для v1.
- **Microsoft Teams.** Публичного локального API на аудио звонка нет (транскрипты — через Microsoft 365 Graph + политика организации + Premium). Работает универсальный путь: системный тап = смешанный звук звонка. Отдельные треки — недоступны.
- **Google Meet.** Нативного клиента нет (браузер). Для нас Meet — просто Chrome-процесс: тап браузера или system-wide тап даёт звук конференции. Web-путь (tabCapture extension) — альтернативный продукт, отметили в 1.4.
- **Telegram.** Десктопный клиент; 1:1 видеозвонки — E2E, групповые звонки — через облако Telegram. **E2E не препятствие:** дешифрование и воспроизведение происходят на устройстве пользователя, в системный вывод уходит уже расшифрованный звук — системный тап его получает. Тап по процессу Telegram покрывает и обычные звонки, и E2E.
- **«Любое голосовое взаимодействие» (вебинары, VLC, подкасты, курсы).** Только system-wide тап (или тап конкретного плеера/браузера) — универсально и без per-app интеграций. Это главный аргумент против зоопарка интеграций: один системный тап покрывает 95% кейсов.

---

## 3. Диаризация говорящих

### 3.1 Gemini Transcribe — что подтверждено по официальным документам (сентябрь 2026)

**Матрица возможностей (Google Cloud / Gemini API docs):**

| Возможность | `gemini-3.5-transcribe-live` (стриминг) | `gemini-3.5-transcribe` (батч/файл) | Статус |
|---|---|---|---|
| **Speaker diarization** | **Not Supported** | **Supported, до 8 спикеров** | Experimental; «Attribution for 3+ speakers is Experimental» |
| Word-level timestamps | Not Supported | Supported | Experimental; «Degrades transcription accuracy» |
| Custom vocabulary (до 1000 терминов) | Supported | Supported | Лучшие результаты до ~100 терминов |
| Smart dictation & formatting | Supported (с ручной endpointing: `ActivityStart`/`ActivityEnd`) | Supported | Experimental |
| Макс. длительность аудио | 10 мин/сессия | **1 ч** стандартно; **30 мин** при включённых диаризации/таймстампах | Лимит на запрос |

**Как включается (точные поля `transcription_config` в Interactions API, по ai.google.dev/gemini-api/docs/transcribe):**

```json
{
  "generation_config": {
    "transcription_config": {
      "mode": {
        "type": "verbatim",
        "diarization_mode": "speaker",
        "timestamp_granularities": ["word"]
      }
    }
  }
}
```

- `diarization_mode: "speaker"` — единственное значение; `diarization_count` в актуальных доках **не документирован** (число спикеров модель определяет сама, до 8).
- Режим `smart` — это `"transcription_config": {"mode": "smart"}` и он **несовместим** с `diarization_mode` и `timestamp_granularities` (дословно из доки: smart transcription is not compatible with `timestamp_granularities` and `diarization_mode`). Прошлое наблюдение владельца («diarization_mode существовал, но был несовместим с smart») — **подтверждено как текущее состояние**: diarization живёт внутри `mode` и требует `type: "verbatim"`.
- **`custom_vocabulary` несовместим с диаризацией/таймстампами: API отклоняет запрос, где `custom_vocabulary` присутствует вместе с ними.** Для OmniFlow это ломающее изменение в `GeminiTranscription.requestBody` (`10-transcription.md` § 4.5): при диаризации `custom_vocabulary` надо не отправлять.
- **Метки в ответе:** спикеры приходят как `spk_1`, `spk_2`, … (REST-пример — поле `speaker` в per-word аннотациях `word_info`). Точная форма ответа Interactions API (где именно `speaker` — в словах, сегментах или steps) требует живого теста: наш парсер `transcript(fromResponse:)` сейчас склеивает только `steps[].content[].text` и метки потеряет.
- **Live-стриминг:** `inputAudioTranscription` в setup поддерживает `mode` и `custom_vocabulary`, но **не диаризацию** (матрица: Live — Not Supported). Значит, live-транскрипция звонка с метками говорящих силами модели невозможна в принципе — только канальный трюк (3.2) или пост-обработка.

**Цены (ai.google.dev/gemini-api/docs/pricing, Standard tier):** batch — input $2/1M tokens (≈$0.003/мин аудио), output $12/1M; blended ≈ **$0.005/мин** (≈$0.30/час). Live — input $3.5/1M (≈$0.005/мин), output $21/1M; blended ≈ **$0.009/мин**. Обе доступны на free tier (лимиты free tier для transcribe-моделей на странице не расписаны — проверить в живом использовании).

### 3.2 Дешёвый трюк: каналы «мой микрофон» vs «системный звук»

Два раздельных потока дают **двух заведомо известных говорящих** бесплатно и детерминированно:

- Канал A = микрофон → «**Me**».
- Канал B = системный тап → удалённые участники (смешаны). Для 1:1 звонков (основной кейс) этого достаточно: ровно 2 говорящих без всякой ML-диаризации.
- Для конференций: канал B дополнительно прогоняется через `diarization_mode: "speaker"` (если спикеров ≥3 и нужен ML) — итоговая разметка: `Me` + `spk_1..spk_N`.

Как совмещать с API:
1. **Батч (v2, рекомендуем):** два запроса `POST /interactions` (или один файл-стерео нельзя — модель смешивает каналы: «multi-channel audio is merged into a single channel»), склейка в клиенте по таймкодам (у обоих каналов общий таймлайн записи; при word timestamps — точная вставка реплик «Me» между `spk_N`).
2. **Live (v3):** **две параллельные Live-сессии** (по WebSocket на канал). Один сокет = один аудиовход; «два потока в одну сессию» протоколом не предусмотрено. Клиент помечает каждый частичный транскрипт каналом. Два сокета = двойной расход live-квоты (≈$0.018/мин на звонок в blended-оценке, free tier может съедаться быстро).
3. Альтернатива без second API: Live только на системном канале, микрофон писать в файл и добавлять пост-фактум — но тогда live-текст неполный. Не рекомендуем.

### 3.3 Альтернативы Gemini-диаризации

| Провайдер/стек | Диаризация | Realtime | Лицензия/цена | Качество ru/en | Комментарий для OmniFlow |
|---|---|---|---|---|---|
| **Gemini 3.5 Transcribe (батч)** | Да, `diarization_mode: "speaker"`, ≤8 спикеров, 3+ experimental | Нет (Live — без диаризации) | ≈$0.005/мин; free tier | Крепкое, 85+ языков, автодетект + code-switching | Основной путь v2; минус — «30 мин/запрос при диаризации» |
| **Deepgram Nova-3** | Streaming: `diarize_model` (v1/latest; v2 — только pre-recorded), в стриме приходит только `speaker` (без confidence); `multichannel` — раздельная транскрипция каналов | Да | ≈$0.004–0.006/мин (Nova-2/3 streaming) | en отлично, ru заметно слабее | Запасной облачный путь, если у Gemini упрёмся в 30 мин/чанки |
| **AssemblyAI** | Async — зрелая (`speakers_labels`); Streaming: текущий quickstart (`universal-3-5-pro`) описывает turn-based output **без** speaker-атрибутов — streaming-диаризация в доках не подтверждена | Частично | ≈$0.005/мин | en/мультиязычное, ru средне | Не приоритет |
| **OpenAI (gpt-4o-transcribe / whisper)** | Диаризации нет ни в одном API | Realtime есть, диаризации нет | — | — | Не вариант для меток |
| **pyannote.audio 3.1 + WhisperX (локально)** | Да (speaker-diarization-3.1 + segmentation-3.1) | Нет (офлайн-пайплайн) | pyannote — MIT, **но веса на HF — gated**: юзер должен принять условия моделей и иметь HF token; WhisperX — BSD-2/BYOD | ru/en хорошее; но на **Intel Mac только CPU**: быстрее-реального-времени не будет (WhisperX оптимизирован под CUDA; на x86_64 с large-моделью — кратно медленнее реального времени) | Опциональная «приватная» кнопка для энтузиастов, не основной путь. Python-рантайм + HF-токен в GUI-приложении — тяжёлый UX |
| **NVIDIA NeMo / SpeechBrain** | Да (NeMo SortFormer/pyannote-подобные) | Ограниченно | OSS | en-центричные | CPU-only Intel Mac и без CUDA — нецелесообразно |

Итог: конкуренции у «Gemini батч + канальный трюк» по соотношению цена/качество/интеграция в наш Swift-стек нет.

---

## 4. Рекомендуемая архитектура для OmniFlow

### v1 — захват системного аудио + микрофон, запись файла звонка

- Новый `SystemAudioCaptureService` по образцу `AudioRecorder` (`20-audio.md`): macOS ≥ 14.4 → Core Audio Process Tap (per-process с UI-пикером процессов, как в AudioCap `ProcessSelectionView`, или system-wide — решение в спеке UI); macOS 13.0–14.3 → ScreenCaptureKit `SCStream(capturesAudio: true)`; ниже — сообщение о неподдерживаемой версии (драйверы не тащим в v1).
- Две дорожки, как сейчас: файловая (WAV PCM16 16 kHz mono на канал; для звонка — отдельный файл на канал или стерео L/R) + realtime-ветка PCM16 24 kHz (`realtimeSampleRate`) на канал.
- Каналы не смешивать до транскрипции. Эхо-советы в UI (наушники).
- Разрешение: добавить `NSAudioCaptureUsageDescription`; без TCC SPI промпт придёт сам при первом тапе; (опционально, за флагом) SPI-preflight для дружелюбного онбординга.
- Приёмочный критерий: записывается 10-минутный Zoom/Telegram-звонок, оба файла непусты, watchdog/прерывания из спеки 20 работают для нового источника.

### v2 — батч-транскрипция с диаризацией

- Расширить `GeminiTranscription.requestBody`: для звонкового режима `mode = {type: "verbatim", diarization_mode: "speaker"}` (+ `timestamp_granularities: ["word"]` по потребности) и **обязательная выкладка `custom_vocabulary`** (несовместим — API отклонит).
- Парсер ответа: дополнить `InteractionResponse`-модель полями спикера (`speaker: spk_N`), склейку `steps[].content[].text` заменить на сегментную структуру `{speaker, text, start?}`. Точную форму — живым тестом (см. «Открытые вопросы»).
- Чанкинг: звонки > 30 мин резать на куски ≤ 25–30 мин с перекрытием ~15–30 c; сшивка текста по таймкодам, ремаппинг `spk_N` между чанками (простая эвристика — по совпадению перекрытия, далее по желанию voice-embedding).
- Загрузка аудио: переключиться с inline base64 на **Files API** (наш WAV — 1.92 MB/мин, inline-лимит ~20 MB пробивается уже на ~11-й минуте). Формат для звонков — рассмотреть сжатый Opus/M4A вместо WAV.
- Мелодия «Me vs остальные»: канал микрофона — отдельным запросом (без диаризации, можно `smart`), метка «Me» ставится клиентом.

### v3 — live-транскрипция звонка с метками каналов

- Две параллельные `GeminiLiveTranscriptionService` (по сокету на канал), `inputAudioTranscription.mode = "SMART"`; `onPartialUpdate` оборачивается в `{channel: "me"|"remote", text}`. Диаризации в Live нет — метки только канальные.
- Долгие сессии (звонок 40–60 мин): лимит audio-only сессии 15 мин и lifetime соединения ~10 мин → обязателен `contextWindowCompression` (sliding window) + `sessionResumption` (handle-токены, живут 2 ч) + авто-reconnect по `GoAway` (приходит с `timeLeft`). Это доработка `GeminiLiveTranscriptionService` (сейчас сокет живёт на одну диктовку).
- Free tier Live при двух сокетах может исчерпываться — предусмотреть автопереключение на батч по исчерпанию (паттерн fallback из `10-transcription.md` § 7.3 уже есть).

### Риски

1. **Приватность/согласие на запись (законодательство, кратко).** США: федерально — one-party consent, но ряд штатов требует согласия всех сторон (California Penal Code §632, Florida, Illinois и др.). ЕС: GDPR (законное основание/согласие; в ряде стран запись третьих лиц без уведомления — уголовный состав, напр. §201 StGB в Германии). РФ: запись собственного разговора для личных нужд допустима, но обнародование ограничено (тайна связи, ст. 23 Конституции). Для продукта: дефолт — локальное хранение, явный дисклеймер/уведомление участникам перед записью (например, авто-фраза в чат/в эфир), запрет записи E2E-звонков «молча» — репутационно чувствительно. (Не юр. консультация; перед релизом — проверка юристом по целевым юрисдикциям.)
2. **E2E-звонки.** Технически перехватываются (звук расшифрован локально, раздел 2 — Telegram), но это чувствительная зона: продукт, «пишущий E2E», может блокироваться политиками сторов/антивирусов и осуждаться сообществом. Решение о поддержке — осознанное, с предупреждениями в UI.
3. **Квоты Gemini на длинные звонки.** Математика: ~25 audio tokens/s (транскрибирующая модель; generic-аудио Gemini считает по 32 tokens/s) → 60 мин ≈ 90–115k токенов ввода (≈$0.18–0.23 batch) — в 1M-контекст влезает, бесплатно тоже реально. Узкое место — не токены, а **inline-лимит ~20 MB/запрос** (наш WAV: пробивается на ~11-й минуте) и **30-минутный лимит при диаризации** → Files API + чанкинг обязательны для 40–60-минутных звонков. Live: 15-мин сессии/10-мин соединения — нужен reconnect-слой.
4. **App Store ревью** (если пойдём в Store): приватный TCC SPI у AudioCap — известный источник рисков; наш путь без SPI — легален, но первый промпт менее контролируемый. Screen Recording permission в фолбэке — тоже частая причина ревью-вопросов (нужен clear intent-текст).
5. **Экспериментальность диаризации:** 3+ спикеров и word timestamps — Experimental и «degrades accuracy» — в маркетинге не обещать точность per-спикер на больших конфах; для 1:1 канальный трюк детерминирован.

---

## Открытые вопросы (проверить живыми тестами на нашем ключе — вызовы API в этом исследовании НЕ делались)

1. **Форма ответа Interactions API с диаризацией:** где именно приходят `spk_N` (per-word аннотации? сегменты? новые step-типы?) и совместим ли текущий парсер `steps[].content[].text`. Тест: `POST /interactions`, `gemini-3.5-transcribe`, `mode: {type: "verbatim", diarization_mode: "speaker"}` на двухголосом WAV.
2. **`custom_vocabulary` + диаризация:** подтвердить реальным 400-ответом, что комбинация отклоняется, и что просто убрать поле достаточно (наш код сейчас шлёт его всегда при непустом списке).
3. **Files API × Interactions API:** принимает ли `input` file-ссылку (`file_uri`) вместо inline base64, и какие MIME (Opus/M4A?) реально берёт transcribe-модель. Если нет — чанкинг inline-аудио по 10 минут.
4. **Поведение `spk_N` между чанками** одного звонка: метки сбрасываются на `spk_1` в каждом чанке? Стабильность при перекрытии 15–30 с.
5. **Free tier лимиты transcribe/live** (RPM/RPD/TPM) — на странице цен не расписаны; замерить на ключе, чтобы спроектировать fallback.
6. **Два параллельных Live-сокета с одним API-ключом** — не считается ли второй соединением против лимитов concurrent sessions; живёт ли `SMART`-режим на системном канале (шум конференции) без деградации.
7. **Тап Telegram/Zoom в реальном окружении:** размер буферов/частота тапа (системный микс 48 kHz) и стабильность watchdog из спеки 20 при источнике-тапе; поведение при переключении аудиоустройства посреди звонка.
8. **macOS 13 фолбэк SCK:** подтверждить на целевых 13.x, что audio-only SCStream не требует видео-слоя и не провалирует TCC-квест у пользователей.

---

## Источники

| # | Источник | URL | Дата обращения / состояние |
|---|---|---|---|
| 1 | AudioCap README (insidegui) — process taps, macOS 14.4+, `NSAudioCaptureUsageDescription`, private aggregate device | https://github.com/insidegui/AudioCap | 2026-09-24 |
| 2 | AudioCap source: `AudioRecordingPermission.swift` (TCC SPI, `kTCCServiceAudioCapture`), `AudioCap.entitlements` (sandbox + device.audio-input, без спец-entitlement) | https://raw.githubusercontent.com/insidegui/AudioCap/main/AudioCap/ProcessTap/AudioRecordingPermission.swift | 2026-09-24 |
| 3 | Audio transcription — Gemini API (`transcription_config`: `mode` verbatim-объект с `diarization_mode`, `timestamp_granularities`; `custom_vocabulary` несовместим; 1 ч / 30 мин; Files API для длинных записей; `spk_1`-метки) | https://ai.google.dev/gemini-api/docs/transcribe | 2026-09-24 |
| 4 | Gemini 3.5 Transcribe — model card (≤8 спикеров, 3+ experimental; 1 ч; 30 мин при диаризации; live 10 мин/сессия; 85+ языков; не поддерживает caching/Batch API) | https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe | 2026-09-24 (стр. updated 2026-09-10) |
| 5 | Gemini 3.5 Transcribe (Gemini Enterprise Agent Platform / Vertex) — фичевая матрица: diarization Live=Not Supported / Sync=Supported (≤8); max duration 10/15 мин; SMART несовместим с word_timestamp и diarization; `AudioTranscriptionConfig(diarization=True, …)`; `speaker_label` в ответе; язык | https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-5-transcribe | 2026-09-24 |
| 6 | Gemini API pricing (transcribe: input $2/1M, ≈$0.003/мин, 25 audio tokens/s; live: $3.5/1M, ≈$0.005/мин; free tier) | https://ai.google.dev/gemini-api/docs/pricing | 2026-09-24 |
| 7 | Gemini audio understanding (inline ≤20 MB, ~32 tokens/s, 9.5 ч, даунсэмпл 16 kbps, multi-channel → mono) | https://ai.google.dev/gemini-api/docs/audio | 2026-09-24 |
| 8 | Gemini Live API — session management (audio-only 15 мин, audio+video 2 мин; connection lifetime ~10 мин; `contextWindowCompression`, `sessionResumption` (токены 2 ч), `GoAway`) | https://ai.google.dev/gemini-api/docs/live-session | 2026-09-24 |
| 9 | Gemini Live API — overview (вход audio 16 kHz PCM16 LE, WebSocket) | https://ai.google.dev/gemini-api/docs/live | 2026-09-24 |
| 10 | Deepgram diarization (`diarize_model` v1/v2/latest; streaming — без v2 и без confidence; Nova-1/2/3) | https://developers.deepgram.com/docs/diarization | 2026-09-24 |
| 11 | AssemblyAI Streaming STT quickstart (`universal-3-5-pro`, turn-based output без speaker-атрибутов) | https://www.assemblyai.com/docs/speech-to-text/streaming | 2026-09-24 |
| 12 | BlackHole (GPL-3.0, «license required for all non-GPLv3 projects»), Loopback $99, Rogue Amoeba tech licensing (ARK-SDK) | https://github.com/ExistentialAudio/BlackHole ; https://rogueamoeba.com | 2026-09-24 |
| 13 | Zoom local recording: «Record a separate audio file for each participant who speaks» | https://support.zoom.com ; https://devforum.zoom.us | 2026-09-24 |
| 14 | Apple — Core Audio process taps: `AudioHardwareCreateProcessTap` / `CATapDescription` (developer.apple.com/documentation/coreaudio, audiotoolbox) — страницы JS-gated, факты сверены по AudioCap | https://developer.apple.com/documentation/audiotoolbox/catapdescription | 2026-09-24 |
| 15 | Apple — ScreenCaptureKit (`SCStreamConfiguration.capturesAudio`, macOS 13+; Screen Recording TCC) | https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio | 2026-09-24 |
| 16 | Право на запись разговоров (обзор): US one-party/all-party (Cal. Penal Code §632), GDPR/§201 StGB, РФ — обзорно, требуется юр. проверка | обзорные источники (EN wiki /Cr/, официальные кодексы) | 2026-09-24 |
