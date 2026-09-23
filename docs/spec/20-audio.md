# Спецификация 20 — Аудио: захват, форматы, watchdog, уровень сигнала, устройства

Референс: `Sources/AudioRecorder.swift`, `Sources/LiveAudioLevelNormalizer.swift`. Связанные файлы: `Sources/AppState.swift` (точки вызова, наблюдатели устройств, сохранение WAV), `Sources/RealtimeTranscriptionService.swift` / `Sources/GeminiLiveTranscriptionService.swift` (потребители realtime-потока, см. `10-transcription.md`).

Именование: очереди и OSLog-подсистема в референсе — `com.nick8cyber.omniflow.*`. В OmniFlow это аналоги с собственным bundle-id: паттерн `com.<team>.<app>.capture.session` и т.д. Ниже приведены значения референса — при переименовании меняется только префикс.

---

## 1. Движок захвата

### 1.1 Общая структура

`final class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate`.

Хранимое состояние (все поля приватные, кроме двух `@Published`):

| Поле | Тип / начальное значение | Назначение |
|---|---|---|
| `captureSession` | `AVCaptureSession?` | сессия захвата |
| `currentInput` | `AVCaptureDeviceInput?` | вход устройства |
| `audioDataOutput` | `AVCaptureAudioDataOutput?` | выход сэмплов |
| `sessionObservers` | `[NSObjectProtocol]` | токены NotificationCenter |
| `tempFileURL` | `URL?` | путь временного WAV |
| `recordingStartTime` | `CFAbsoluteTime = 0` | момент `startRecording` |
| `_bufferCount` | `OSAllocatedUnfairLock<Int>` (init 0) | счётчик принятых буферов |
| `fileWriteErrorLock` | `OSAllocatedUnfairLock<()>` | защита `fileWriteError` |
| `watchdogTimer` | `DispatchSourceTimer?` | watchdog (п. 4) |
| `sessionQueue` | serial `DispatchQueue("com.nick8cyber.omniflow.capture.session")` | владелец сессии |
| `sampleBufferQueue` | serial `DispatchQueue("com.nick8cyber.omniflow.capture.samples")` | очередь колбэков сэмплов |
| `activeAudioFile` | `AVAudioFile?` | открытый писатель WAV |
| `activeAudioFormat` | `AVAudioFormat?` | формат писателя |
| `recordedFrameCount` | `AVAudioFramePosition = 0` | записано кадров |
| `loggedCaptureFormat` | `Bool = false` | одноразовый лог формата |
| `fileWriteError` | `Error?` | первая ошибка записи |
| `isSessionInterrupted` | `Bool = false` | флаг прерывания сессии |
| `readyFired` | `Bool = false` | `onRecordingReady` уже сработал |
| `failureReported` | `Bool = false` | отказ уже доложен |
| `_recording` | `OSAllocatedUnfairLock<Bool>` (init false) | истинный флаг записи |
| `liveLevelNormalizerLock` | `OSAllocatedUnfairLock<LiveAudioLevelNormalizer>` | нормализатор уровня |
| `recordingConverterLock` | `OSAllocatedUnfairLock<AVAudioConverter?>` (nil) | конвертер файловой ветки |
| `pcm16ConverterLock` | `OSAllocatedUnfairLock<AVAudioConverter?>` (nil) | конвертер realtime-ветки |

Публикуемые свойства:
- `@Published var isRecording = false` — зеркалирует `_recording`, обновляется ТОЛЬКО на main queue.
- `@Published var audioLevel: Float = 0.0` — нормализованный уровень 0…1, обновляется только на main queue.

Колбэки (назначаются до `startRecording`):
- `var onRecordingReady: (() -> Void)?` — вызывается на main queue (п. 5).
- `var onRecordingFailure: ((Error) -> Void)?` — вызывается на main queue (п. 6).
- `var onPCM16Samples: ((Data) -> Void)?` — вызывается на `sampleBufferQueue`, чанк PCM16 для realtime-сокета (п. 3.2).

Константы:
- `static let realtimeSampleRate = 24_000` — sample rate исходящего PCM-потока.
- `static let watchdogTimeout: TimeInterval = 2.0`.
- `static let sampleRateLogLimit = 40` — логировать первые N буферов.
- OSLog: `OSLog(subsystem: "com.nick8cyber.omniflow", category: "Recording")`.

### 1.2 Целевые форматы

```swift
private let recordingTargetFormat: AVAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

private let pcm16TargetFormat: AVAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: Double(AudioRecorder.realtimeSampleRate),  // 24_000
    channels: 1, interleaved: true)!
```

ДВА независимых конвейера из одного и того же входного буфера:
1. **Файловая ветка** → `recordingTargetFormat` (Int16 / 16 000 Гц / mono / interleaved) → временный WAV.
2. **Realtime-ветка** → `pcm16TargetFormat` (Int16 / 24 000 Гц / mono / interleaved) → `onPCM16Samples(Data)` (сырые байты Int16 little-endian, без заголовка).

### 1.3 Очереди и реэнтрантность

- `init()` выполняет `sessionQueue.setSpecific(key: Self.sessionQueueKey, value: 1)`, где `sessionQueueKey = DispatchSpecificKey<UInt8>()` (static).
- Проверка «мы на session-очереди»: `DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil`. Используется в трёх местах:
  - `deinit`: очистка (`cancelWatchdog()` + `teardownSessionLocked()`) — синхронно, если уже на session-очереди; иначе `sessionQueue.sync`.
  - обработка ошибки `startRecording`: сброс `tempFileURL = nil` — тем же способом.
  - `cleanup()`: удаление temp-файла — тем же способом.
- Смысл: избегать deadlock от `sessionQueue.sync` при вызове с самой session-очереди.
- Все тяжёлые операции сессии (`makeSession`, `stopRecording`, `cancelRecording`, `reportRecordingFailure`, watchdog) исполняются на `sessionQueue`; колбэк `captureOutput` — на `sampleBufferQueue`; UI-обновления — через `DispatchQueue.main.async`.

### 1.4 Сборка сессии (`makeSession(deviceUID:outputURL:)`)

Порядок строго такой:

1. `teardownSessionLocked()`.
2. Выбрать устройство: `preferredCaptureDevice(for:reason:)` (п. 7.2).
3. `AVCaptureSession()`; `AVCaptureAudioDataOutput()`.
4. Настроить `dataOutput.audioSettings` — словарь:
   - `AVFormatIDKey: kAudioFormatLinearPCM`
   - `AVSampleRateKey: recordingTargetFormat.sampleRate` (16 000)
   - `AVNumberOfChannelsKey: 1`
   - `AVLinearPCMBitDepthKey: 16`
   - `AVLinearPCMIsFloatKey: false`
   - `AVLinearPCMIsBigEndianKey: false`
   - `AVLinearPCMIsNonInterleaved: false`
5. `dataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)`.
6. `AVCaptureDeviceInput(device:)` — при ошибке бросить `.failedToCreateCaptureInput(error.localizedDescription)`.
7. `session.beginConfiguration()`; флаг `needsCommitConfiguration = true`; `defer` коммитит, если не закоммичено вручную.
8. `session.canAddInput(input)` — иначе `.failedToCreateCaptureInput("Session rejected device input for \(name)")`; затем `addInput`.
9. `session.canAddOutput(dataOutput)` — иначе `.failedToStartCaptureSession("Session rejected audio data output")`; затем `addOutput`.
10. `session.commitConfiguration()`; `needsCommitConfiguration = false`.
11. Присвоить поля `captureSession/currentInput/audioDataOutput`; сбросить: `isSessionInterrupted = false`, `activeAudioFile = nil`, `activeAudioFormat = nil`, оба конвертера = nil, `recordedFrameCount = 0`, `loggedCaptureFormat = false`, `fileWriteError = nil`.
12. `installSessionObservers(for:)` (п. 6).
13. `session.startRunning()`; если `!session.isRunning` — `.failedToStartCaptureSession("Session failed to enter running state.")`.
14. `tempFileURL = outputURL`.

---

## 2. Временный WAV-файл

- Путь: `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")` — создаётся в `startRecording` ДО `makeSession`.
- `AVAudioFile` создаётся лениво при ПЕРВОМ буфере (в `appendSampleBufferToFile`), настройками `pcmFileSettings(for: recordingTargetFormat)`:

```swift
[AVFormatIDKey: kAudioFormatLinearPCM,
 AVSampleRateKey: 16000.0,
 AVNumberOfChannelsKey: 1,
 AVLinearPCMBitDepthKey: 16,
 AVLinearPCMIsFloatKey: false,
 AVLinearPCMIsBigEndianKey: false,
 AVLinearPCMIsNonInterleaved: false]
```

конструктор: `AVAudioFile(forWriting:outputURL, settings:, commonFormat: .pcmFormatInt16, interleaved: true)`.
- Если `sourceFormat == targetFormat`, буфер пишется как есть; иначе через конвертер (п. 3.1). `recordedFrameCount += outputBuffer.frameLength`.
- Файл финализируется присваиванием `activeAudioFile = nil` (в `finishAudioFileLocked`, дренаж очереди — `sampleBufferQueue.sync`).
- «Файл валиден» = `!discard && recordedFrameCount > 0 && fileWriteError == nil`. Иначе URL возвращается как nil и файл удаляется.

---

## 3. Конвертация

### 3.1 Файловая ветка (`convertRecordingBuffer`)

- Конвертер кэшируется под `recordingConverterLock`: если существует и `existing.inputFormat == sourceFormat` — переиспользуется; иначе создаётся новый `AVAudioConverter(from: sourceFormat, to: recordingTargetFormat)` и записывается на место старого. Т.е. **пересоздание ровно при смене входного формата** (например, устройство сменило частоту на лету).
- Если конвертер создать не удалось — `.failedToBeginFileRecording("Could not create recording converter.")`.
- `convertBuffer(from:using:to:)` (общая для обеих веток):
  - ёмкость выходного буфера: `ceil(frameLength * targetRate/sourceRate) + 32` кадров;
  - один вызов `converter.convert(to:error:)` с замыканием: первый вызов получает `inputStatus = .haveData` и входной буфер, все последующие — `.noDataNow` и nil;
  - при ошибке конвертера — `.failedToBeginFileRecording("Audio conversion failed: …")`;
  - при `status == .error` или пустом выходе — `.failedToBeginFileRecording("Audio conversion produced no data.")`.

### 3.2 Realtime-ветка (`emitPCM16IfNeeded`)

- Выполняется после записи в файл, только если `onPCM16Samples != nil`.
- Вход валидируется тем же `validatedPCMBufferFormat` (только PCM, >0 каналов, >0 Гц); при невалидности — тихий return.
- Кэш конвертера `pcm16ConverterLock` — аналогично п. 3.1, цель `pcm16TargetFormat` (24 кГц).
- Выход: `outputBuffer.int16ChannelData![0]`, `Data(bytes:count: frameLength * MemoryLayout<Int16>.size)` → `handler(data)`. Данные идут БЕЗ WAV-заголовка, потоковая нарезка по буферам.

### 3.3 Валидация входного формата (`validatedPCMBufferFormat`)

- Разрешены `commonFormat`: `pcmFormatFloat32`, `pcmFormatFloat64`, `pcmFormatInt16`, `pcmFormatInt32`. Иначе `.invalidInputFormat("<context> is not PCM (commonFormat=…, settings=…)")`.
- `channelCount > 0`, иначе `.invalidInputFormat("<context> reported zero channels.")`.
- `sampleRate > 0`, иначе `.invalidInputFormat("<context> reported an invalid sample rate (…)")`.

Контексты строк: `"capture sample buffer"`, `"audio level sample buffer"`, `"realtime transcription sample buffer"`.

### 3.4 Распаковка CMSampleBuffer (`makePCMBuffer`)

- `AVAudioPCMBuffer(pcmFormat:frameCapacity: frameCount)`, `frameLength = frameCount`,
  затем `CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: mutableAudioBufferList)`; при `!= noErr` — `.failedToBeginFileRecording("Could not copy sample buffer data (OSStatus N)")`.
- `frameCount == 0` → ранний return (без записи, без счётчика).

---

## 4. Watchdog

- `startBufferWatchdog()` — запускается из `startRecording` (после `_recording = true`) и из обработчика `interruptionEnded`.
- Фиксирует `baselineCount = _bufferCount`, отменяет предыдущий таймер, создаёт `DispatchSource.makeTimerSource(queue: sessionQueue)`, `schedule(deadline: .now() + 2.0)`.
- В обработчике:
  1. `guard _recording` — если запись уже закончилась, ничего.
  2. `guard !isSessionInterrupted` — при прерывании watchdog «подвешен», лог `"watchdog suspended while capture session is interrupted"`, отказа НЕТ.
  3. Если `_bufferCount == baselineCount` — `.noAudioBuffersReceived` через `reportRecordingFailure` (лог `"watchdog: no new buffers after 2.0s — giving up"`).
  4. Иначе — инфолог `"watchdog: N new buffers after 2.0s — healthy"`.
- `cancelWatchdog()` — из `stopRecording`, `cancelRecording`, `reportRecordingFailure`, `handleSessionInterrupted`.

## 5. Готовность записи (`onRecordingReady`)

В `captureOutput`, после инкремента `_bufferCount` и подсчёта RMS:
- условие: `!readyFired && rms > 0` (первый НЕТИХИЙ буфер; абсолютно тихий вход может никогда не вызвать событие);
- `readyFired = true`, лог `"FIRST non-silent buffer at X.XXXms — recording ready"`, колбэк — на main queue.
- `readyFired` сбрасывается в `false` в начале `startRecording`.

Потребитель в `AppState`: скрывает оверлей «инициализация» и играет звук «Tink» (т.е. UI готовности запускается не по факту `startRunning`, а по первому реальному звуку).

## 6. Прерывания и ошибки сессии

`installSessionObservers` ставит три наблюдателя (объект — конкретная сессия, `queue: nil`):

1. `AVCaptureSession.runtimeErrorNotification`: ошибка из `userInfo[AVCaptureSessionErrorKey]`; заворачивается в `.failedToStartCaptureSession(N.localizedDescription)` (или `"Unknown runtime error"`) → `reportRecordingFailure`.
2. `AVCaptureSession.wasInterruptedNotification` → `handleSessionInterrupted`: если `_recording` — `isSessionInterrupted = true`, `cancelWatchdog()`, лог `"capture session interrupted — waiting for recovery"`. Запись НЕ останавливается — ждём восстановления.
3. `AVCaptureSession.interruptionEndedNotification` → `handleSessionInterruptionEnded`: если `_recording` — `isSessionInterrupted = false`, перезапуск watchdog, лог `"capture session interruption ended — restarting watchdog"`.

### 6.1 `reportRecordingFailure(_ error:completion:)` — единственный путь отказа

Атомарно на `sessionQueue` (первый вызов выигрывает — `guard !failureReported`):
1. `failureReported = true`, `cancelWatchdog()`, `_recording = false`.
2. `finishAudioFileLocked(discard: true)` → URL мусорного файла.
3. `teardownSessionLocked()`, сброс нормализатора, удаление temp-файла.
4. На main: `isRecording = false`, `audioLevel = 0`, `onRecordingFailure?(error)`, `completion?(nil)`.

В AppState `onRecordingFailure` → `handleRecordingFailure`: отмена таймера инициализации, отключение колбэков, `tearDownRealtimeService`, `audioRecorder.cleanup()`, `restoreAudioInterruptionIfNeeded()`, `isRecording = false`, `isTranscribing = false`, ошибка пользователю, `refreshAvailableMicrophonesIfNeeded()`.

## 7. Устройства

### 7.1 Список (`AudioDevice`)

```swift
struct AudioDevice: Identifiable { let id: String; let uid: String; let name: String }
// id == uid == device.uniqueID
```

- `captureDevices()`: при macOS ≥ 14 — типы `[.microphone, .external]`, иначе `[.builtInMicrophone, .externalUnknown]`; `AVCaptureDevice.DiscoverySession(deviceTypes:, mediaType: .audio, position: .unspecified).devices`.
- `availableInputDevices()`: `compactMap` — `uniqueID` и `localizedName` триммятся; пропуск пустых; **дедупликация по `uniqueID`** через `Set.insert`; сортировка `localizedCaseInsensitiveCompare(name) == .orderedAscending` (по имени, case-insensitive).

### 7.2 Выбор устройства при старте (`preferredCaptureDevice`)

- `deviceUID == nil`, пустой или `"default"` → `AVCaptureDevice.default(for: .audio)`, при отсутствии — первый из `captureDevices()`; если и это nil — `.missingInputDevice`. Лог `"<reason> — using system default device: <name>"`.
- Иначе поиск по `uniqueID`; найден → лог `"<reason> — keeping selected device: <name> [uid=…]"`.
- Не найден (отключён) → fallback на дефолт (как выше), лог `"<reason> — selected device unavailable [uid=…], falling back to system default: <name> [uid=…]"`.

### 7.3 Хранение выбора и подписки в AppState

- Ключ: `selected_microphone_id` (UserDefaults; значение — `uniqueID` или `"default"`).
- Список обновляется: при открытии меню, после записи (`needsMicrophoneRefreshAfterRecording`), и по уведомлениям:

```swift
NotificationCenter.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { … }
NotificationCenter.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { … }
```
обработчик: `guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio)` → `refreshAvailableMicrophones()`. Токены хранятся в `audioDeviceObservers`, снимаются в `removeAudioDeviceObservers()`.

---

## 8. `rmsLevel(for:)` — RMS входного буфера

Проход по всем буферам `UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)`; пропуск пустых (`mData == nil || mDataByteSize == 0`); выбор формулы по `buffer.format.commonFormat`:

| Формат | Нормализация сэмпла |
|---|---|
| `pcmFormatFloat32` | как есть (Double(sample)) |
| `pcmFormatFloat64` | как есть |
| `pcmFormatInt16` | `Double(sample) / 32768.0` |
| `pcmFormatInt32` | `Double(sample) / 2147483648.0` |
| прочее | буфер пропускается |

`totalSamples` — число обработанных сэмплов по всем буферам. Результат: `Float(sqrt(sumOfSquares / Double(totalSamples)))`; при `totalSamples == 0` → `0`.

## 9. `LiveAudioLevelNormalizer` — нормализатор индикатора

Чистая value-тип структура; состояние в AudioRecorder под `liveLevelNormalizerLock`; `reset()` при старте/стопе/отказе записи.

### 9.1 Все константы (точно)

```swift
static let minimumRMS: Float = 0.00001            // защита log10 от -inf
static let minSpanDB: Float = 18                  // минимальный динамический диапазон, дБ
static let peakHeadroomDB: Float = 8              // запас над peakCeiling для дисплея, дБ
static let speechGateMarginDB: Float = 3          // порог «активная речь» над noise floor, дБ
static let minimumVisibleActiveLevel: Float = 0.12// минимальный видимый уровень активной речи
static let noiseGateNormalizedThreshold: Float = 0.06 // шумовой гейт в норм. шкале
static let floorRiseWindowDB: Float = 4           // окно медленного подъёма floor, дБ
static let floorFallBlend: Float = 0.12           // скорость падения floor
static let floorRiseBlend: Float = 0.02           // скорость подъёма floor
static let peakAttackBlend: Float = 0.55          // быстрый подъём ceiling
static let peakReleaseBlend: Float = 0.04         // медленное опускание ceiling
static let displayAttackBlend: Float = 0.45       // рост индикатора
static let displayReleaseBlend: Float = 0.12      // спад индикатора
```

Начальное/сбросовое состояние: `noiseFloorDB = -55`, `peakCeilingDB = -37`, `displayLevel = 0`.

### 9.2 Алгоритм `normalizedLevel(forRMS:)` по шагам

1. `levelDB = 20 * log10f(max(rms, 0.00001))`.
2. `updateNoiseFloor(levelDB)`:
   - `ceilingLimitedLevel = min(levelDB, peakCeilingDB - 18)`;
   - если `ceilingLimitedLevel <= noiseFloorDB` → `noiseFloorDB = mix(noiseFloorDB, ceilingLimitedLevel, 0.12)` (падение);
   - иначе если `ceilingLimitedLevel <= noiseFloorDB + 4` → `mix(…, 0.02)` (медленный подъём);
   - иначе floor не меняется.
3. `updatePeakCeiling(levelDB)`:
   - `minimumCeiling = noiseFloorDB + 18`;
   - если `levelDB >= peakCeilingDB` → `peakCeilingDB = mix(peakCeilingDB, levelDB, 0.55)`;
   - иначе → `peakCeilingDB = mix(peakCeilingDB, max(levelDB, minimumCeiling), 0.04)`;
   - финально `peakCeilingDB = max(peakCeilingDB, minimumCeiling)`.
4. `displayCeilingDB = peakCeilingDB + 8`;
   `dynamicSpan = max(displayCeilingDB - noiseFloorDB, 18 + 8)`;
   `normalized = clamp((levelDB - noiseFloorDB) / dynamicSpan)` в 0…1.
5. `isActiveSpeech = levelDB >= noiseFloorDB + 3`.
6. Гейты:
   - если `normalized < 0.06 && levelDB <= noiseFloorDB + 3` → `normalized = 0`;
   - иначе если `isActiveSpeech` → `normalized = max(normalized, 0.12)`.
7. Сглаживание: `blend = normalized > displayLevel ? 0.45 : 0.12`;
   `displayLevel = displayLevel + (normalized - displayLevel) * blend`; вернуть `displayLevel`.

`mix(current, target, blend) = current + (target - current) * blend`; `clamp` — в `[0, 1]`.

AudioRecorder (`updateAudioLevel`): RMS считается из того же сырого буфера, `normalizedLevel(forRMS:)` под локом, результат публикуется в `audioLevel` на main queue; сырой RMS возвращается в `captureOutput` для логов и детекта готовности.

---

## 10. Публичный API AudioRecorder (жизненный цикл)

### 10.1 `startRecording(deviceUID: String? = nil) throws`

1. `recordingStartTime = CFAbsoluteTimeGetCurrent()`; `_bufferCount = 0`; `readyFired = false`; `failureReported = false`; сброс нормализатора.
2. Сформировать `outputURL` во временной папке.
3. `sessionQueue.sync { makeSession(deviceUID:outputURL:); _recording = true; startBufferWatchdog() }`.
4. При ошибке: сбросить `tempFileURL` (с учётом re-entrancy, п. 1.3) и пробросить ошибку.
5. На main: `isRecording = true`, `audioLevel = 0`.

Вызывается из AppState на `DispatchQueue.global(qos: .userInitiated)`; после успеха — `startContextCapture()` и подписка `$audioLevel` на оверлей.

### 10.2 `stopRecording(completion: @escaping (URL?) -> Void)`

Логируются `%.3fms` с момента старта и число буферов. На `sessionQueue`: `cancelWatchdog` → `teardownSessionLocked` → `finishAudioFileLocked(discard: false)` → `_recording = false` → сброс нормализатора; на main: `isRecording = false`, `audioLevel = 0`, `completion(outputURL)` (nil, если файл пуст/битый).

### 10.3 `cancelRecording()`

То же, но `discard: true`; temp-файл удаляется; completion нет.

### 10.4 `finishAudioFileLocked(discard:)`

`sampleBufferQueue.sync` (дренаж недописанных колбэков) → решение о сохранении; `defer`: `recordedFrameCount = 0`, `fileWriteError = nil`, `tempFileURL = nil` если не сохраняем.

### 10.5 `cleanup()`

Удалить `tempFileURL` с диска (учитывая re-entrancy, п. 1.3). AppState вызывает его после успешной загрузки транскрипции / отказа / отмены.

### 10.6 `captureOutput(_:didOutput:from:)`

Порядок: `guard _recording` → `appendSampleBufferToFile` (при ошибке: зафиксировать `fileWriteError`, лог, `reportRecordingFailure`, return) → `emitPCM16IfNeeded` → инкремент `_bufferCount` → `updateAudioLevel` (лог первых 40 буферов: `"buffer #N at X.XXXms, rms=…"`) → условный `onRecordingReady`.

---

## 11. Ошибки `AudioRecorderError` (тексты `errorDescription`)

| Кейс | Текст |
|---|---|
| `.invalidInputFormat(details)` | `Invalid input format: <details>` |
| `.missingInputDevice` | `No audio input device available.` |
| `.noAudioBuffersReceived` | `No audio buffers were received from the selected microphone.` |
| `.failedToCreateCaptureInput(details)` | `Could not open the selected microphone: <details>` |
| `.failedToStartCaptureSession(details)` | `Could not start the capture session: <details>` |
| `.failedToBeginFileRecording(details)` | `Could not begin recording audio: <details>` |

---

## 12. Чек-лист «что должно получиться в коде»

- [ ] `AVCaptureSession` + `AVCaptureAudioDataOutput`, делегат на отдельной serial-очереди; session-очередь — владелец всей сессии; `DispatchSpecificKey<UInt8>` для безопасного sync.
- [ ] Две целевые константы: файл Int16/16000/mono/interleaved; realtime Int16/24000 (`static realtimeSampleRate = 24_000`), из одного входного буфера.
- [ ] Временный WAV `<UUID>.wav` во временной папке; `AVAudioFile` создаётся на первом буфере; файл засчитывается только при `recordedFrameCount > 0` и отсутствии ошибки записи.
- [ ] `AVAudioConverter` кэшируется раздельно для файловой и realtime веток; пересоздаётся при смене `inputFormat`; выходная ёмкость `ceil(ratio*n)+32`; single-shot convert с `.haveData`/`.noDataNow`.
- [ ] Watchdog 2.0 с по росту `_bufferCount`; при прерывании сессии watchdog заморожен; по истечении — `noAudioBuffersReceived`.
- [ ] `wasInterrupted` → ждём; `interruptionEnded` → перезапуск watchdog; `runtimeError` → отказ. Отказ атомарный (single-shot), temp-файл удаляется, UI-колбэки на main.
- [ ] `onRecordingReady` — по первому буферу с `rms > 0`, один раз за запись, на main.
- [ ] RMS-формулы для Float32/Float64/Int16 (/32768)/Int32 (/2147483648); RMS по всем буферам AudioBufferList.
- [ ] `LiveAudioLevelNormalizer` со всеми 13 константами, floor/ceiling-адаптацией, гейтами 0.06/0.12/3дБ и атакой/релизом 0.45/0.12.
- [ ] Устройства: DiscoverySession с версионными типами, дедуп по `uniqueID`, сортировка по имени, `"default"` → `AVCaptureDevice.default(for: .audio)` → первый найденный; подписки на connected/disconnected (только `.audio`), обновление на main.
