import AVFoundation
import Combine
import CoreMedia
import Foundation
import os

private let audioRecorderLog = OSLog(subsystem: "com.nick8cyber.omniflow", category: "Recording")

struct AudioDevice: Identifiable {
    let id: String
    let uid: String
    let name: String

    static func availableInputDevices() -> [AudioDevice] {
        var seen = Set<String>()
        var devices: [AudioDevice] = []
        for device in captureDevices() {
            let uid = device.uniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, !name.isEmpty, seen.insert(uid).inserted else { continue }
            devices.append(AudioDevice(id: uid, uid: uid, name: name))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func captureDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
                                                       mediaType: .audio,
                                                       position: .unspecified)
        return session.devices
    }
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice
    case noAudioBuffersReceived
    case failedToCreateCaptureInput(String)
    case failedToStartCaptureSession(String)
    case failedToBeginFileRecording(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        case .noAudioBuffersReceived:
            return "No audio buffers were received from the selected microphone."
        case .failedToCreateCaptureInput(let details):
            return "Could not open the selected microphone: \(details)"
        case .failedToStartCaptureSession(let details):
            return "Could not start the capture session: \(details)"
        case .failedToBeginFileRecording(let details):
            return "Could not begin recording audio: \(details)"
        }
    }
}

/// Thread-synchronized wrapper for non-Sendable converter values.
final class LockedConverterCache {
    private let lock = NSLock()
    private var converter: AVAudioConverter?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        converter = nil
    }

    func get(matching sourceFormat: AVAudioFormat, target: AVAudioFormat) -> AVAudioConverter? {
        lock.lock()
        defer { lock.unlock() }
        if let converter, converter.inputFormat == sourceFormat {
            return converter
        }
        let created = AVAudioConverter(from: sourceFormat, to: target)
        converter = created
        return created
    }
}

final class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let realtimeSampleRate = 24_000
    static let watchdogTimeout: TimeInterval = 2.0
    static let sampleRateLogLimit = 40

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0

    var onRecordingReady: (() -> Void)?
    var onRecordingFailure: ((Error) -> Void)?
    var onPCM16Samples: ((Data) -> Void)?

    private static let sessionQueueKey = DispatchSpecificKey<UInt8>()

    private var captureSession: AVCaptureSession?
    private var currentInput: AVCaptureDeviceInput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var sessionObservers: [NSObjectProtocol] = []
    private var tempFileURL: URL?
    private var recordingStartTime: CFAbsoluteTime = 0
    private let bufferCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let fileWriteErrorLock = OSAllocatedUnfairLock<Void>(initialState: ())
    private var fileWriteError: Error?
    private var watchdogTimer: DispatchSourceTimer?
    private let sessionQueue = DispatchQueue(label: "com.nick8cyber.omniflow.capture.session")
    private let sampleBufferQueue = DispatchQueue(label: "com.nick8cyber.omniflow.capture.samples")
    private var activeAudioFile: AVAudioFile?
    private var activeAudioFormat: AVAudioFormat?
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var loggedCaptureFormat = false
    private var isSessionInterrupted = false
    private var readyFired = false
    private var failureReported = false
    private let recordingFlagLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let liveLevelNormalizerLock = OSAllocatedUnfairLock<LiveAudioLevelNormalizer>(
        initialState: LiveAudioLevelNormalizer())
    private let recordingConverterCache = LockedConverterCache()
    private let pcm16ConverterCache = LockedConverterCache()

    private let recordingTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let pcm16TargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioRecorder.realtimeSampleRate),
        channels: 1, interleaved: true)!

    override init() {
        super.init()
        sessionQueue.setSpecific(key: Self.sessionQueueKey, value: 1)
    }

    // MARK: - Lifecycle

    func startRecording(deviceUID: String? = nil) throws {
        recordingStartTime = CFAbsoluteTimeGetCurrent()
        bufferCountLock.withLock { $0 = 0 }
        readyFired = false
        failureReported = false
        liveLevelNormalizerLock.withLock { $0.reset() }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try sessionQueue.sync {
                try makeSession(deviceUID: deviceUID, outputURL: outputURL)
                setRecordingFlag(true)
                startBufferWatchdog()
            }
        } catch {
            if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
                tempFileURL = nil
            } else {
                sessionQueue.sync { self.tempFileURL = nil }
            }
            throw error
        }
        DispatchQueue.main.async {
            self.isRecording = true
            self.audioLevel = 0
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
        let bufferCount = bufferCountLock.withLock { $0 }
        os_log(.debug, log: audioRecorderLog,
               "stopRecording after %.3fms, buffers=%{public}d",
               elapsedMilliseconds, Int32(bufferCount))
        sessionQueue.async {
            self.cancelWatchdog()
            self.teardownSessionLocked()
            let outputURL = self.finishAudioFileLocked(discard: false)
            self.setRecordingFlag(false)
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0
                completion(outputURL)
            }
        }
    }

    func cancelRecording() {
        sessionQueue.async {
            self.cancelWatchdog()
            self.teardownSessionLocked()
            _ = self.finishAudioFileLocked(discard: true)
            self.setRecordingFlag(false)
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0
            }
        }
    }

    func cleanup() {
        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            removeTempFileLocked()
        } else {
            sessionQueue.sync { self.removeTempFileLocked() }
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cancelWatchdog()
            teardownSessionLocked()
        } else {
            sessionQueue.sync {
                self.cancelWatchdog()
                self.teardownSessionLocked()
            }
        }
    }

    // MARK: - Session assembly

    private func makeSession(deviceUID: String?, outputURL: URL) throws {
        teardownSessionLocked()
        let device = try preferredCaptureDevice(for: deviceUID, reason: "startRecording")
        let session = AVCaptureSession()
        let dataOutput = AVCaptureAudioDataOutput()
        dataOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: recordingTargetFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        dataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioRecorderError.failedToCreateCaptureInput(error.localizedDescription)
        }

        var needsCommitConfiguration = false
        session.beginConfiguration()
        needsCommitConfiguration = true
        defer {
            if needsCommitConfiguration {
                session.commitConfiguration()
            }
        }

        guard session.canAddInput(input) else {
            throw AudioRecorderError.failedToCreateCaptureInput(
                "Session rejected device input for \(device.localizedName)")
        }
        session.addInput(input)

        guard session.canAddOutput(dataOutput) else {
            throw AudioRecorderError.failedToStartCaptureSession("Session rejected audio data output")
        }
        session.addOutput(dataOutput)

        session.commitConfiguration()
        needsCommitConfiguration = false

        captureSession = session
        currentInput = input
        audioDataOutput = dataOutput
        isSessionInterrupted = false
        activeAudioFile = nil
        activeAudioFormat = nil
        recordingConverterCache.reset()
        pcm16ConverterCache.reset()
        recordedFrameCount = 0
        loggedCaptureFormat = false
        fileWriteErrorLock.withLock { self.fileWriteError = nil }

        installSessionObservers(for: session)

        session.startRunning()
        guard session.isRunning else {
            throw AudioRecorderError.failedToStartCaptureSession(
                "Session failed to enter running state.")
        }
        tempFileURL = outputURL
    }

    private func installSessionObservers(for session: AVCaptureSession) {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil) { [weak self] notification in
                guard let self else { return }
                let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                    .localizedDescription ?? "Unknown runtime error"
                self.sessionQueue.async {
                    self.reportRecordingFailure(
                        AudioRecorderError.failedToStartCaptureSession(message))
                }
            })
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil) { [weak self] _ in
                self?.handleSessionInterrupted()
            })
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil) { [weak self] _ in
                self?.handleSessionInterruptionEnded()
            })
    }

    private func handleSessionInterrupted() {
        sessionQueue.async {
            guard self.recordingFlag() else { return }
            self.isSessionInterrupted = true
            self.cancelWatchdog()
            os_log(.debug, log: audioRecorderLog,
                   "capture session interrupted — waiting for recovery")
        }
    }

    private func handleSessionInterruptionEnded() {
        sessionQueue.async {
            guard self.recordingFlag() else { return }
            self.isSessionInterrupted = false
            self.startBufferWatchdog()
            os_log(.debug, log: audioRecorderLog,
                   "capture session interruption ended — restarting watchdog")
        }
    }

    private func teardownSessionLocked() {
        cancelWatchdog()
        let center = NotificationCenter.default
        sessionObservers.forEach { center.removeObserver($0) }
        sessionObservers.removeAll()
        audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureSession?.stopRunning()
        captureSession = nil
        currentInput = nil
        audioDataOutput = nil
    }

    // MARK: - Failure path

    private func reportRecordingFailure(_ error: Error, completion: (() -> Void)? = nil) {
        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            reportRecordingFailureLocked(error, completion: completion)
        } else {
            sessionQueue.async {
                self.reportRecordingFailureLocked(error, completion: completion)
            }
        }
    }

    private func reportRecordingFailureLocked(_ error: Error, completion: (() -> Void)?) {
        guard !failureReported else {
            completion.map { DispatchQueue.main.async(execute: $0) }
            return
        }
        failureReported = true
        cancelWatchdog()
        setRecordingFlag(false)
        let junkURL = finishAudioFileLocked(discard: true)
        teardownSessionLocked()
        liveLevelNormalizerLock.withLock { $0.reset() }
        if let junkURL {
            try? FileManager.default.removeItem(at: junkURL)
        }
        tempFileURL = nil
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0
            self.onRecordingFailure?(error)
            completion.map { $0() }
        }
    }

    // MARK: - Watchdog

    private func startBufferWatchdog() {
        let baselineCount = bufferCountLock.withLock { $0 }
        cancelWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.watchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.recordingFlag() else { return }
            guard !self.isSessionInterrupted else {
                os_log(.debug, log: audioRecorderLog,
                       "watchdog suspended while capture session is interrupted")
                return
            }
            let count = self.bufferCountLock.withLock { $0 }
            if count == baselineCount {
                os_log(.error, log: audioRecorderLog,
                       "watchdog: no new buffers after %.1fs — giving up",
                       Self.watchdogTimeout)
                self.reportRecordingFailure(AudioRecorderError.noAudioBuffersReceived)
            } else {
                os_log(.debug, log: audioRecorderLog,
                       "watchdog: %{public}d new buffers after %.1fs — healthy",
                       Int32(count - baselineCount), Self.watchdogTimeout)
            }
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func cancelWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // MARK: - Device selection

    private func preferredCaptureDevice(for deviceUID: String?, reason: String) throws -> AVCaptureDevice {
        let devices = AudioDevice.captureDevices()
        let trimmedUID = deviceUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uid = trimmedUID, !uid.isEmpty, uid != "default" {
            if let device = AVCaptureDevice(uniqueID: uid) {
                os_log(.debug, log: audioRecorderLog,
                       "%{public}@ — keeping selected device: %{public}@ [uid=%{public}@]",
                       reason, device.localizedName, device.uniqueID)
                return device
            }
            if let fallback = defaultCaptureDevice(from: devices) {
                os_log(.error, log: audioRecorderLog,
                       "%{public}@ — selected device unavailable [uid=%{public}@], falling back to system default: %{public}@ [uid=%{public}@]",
                       reason, uid, fallback.localizedName, fallback.uniqueID)
                return fallback
            }
            throw AudioRecorderError.missingInputDevice
        }
        guard let device = defaultCaptureDevice(from: devices) else {
            throw AudioRecorderError.missingInputDevice
        }
        os_log(.debug, log: audioRecorderLog,
               "%{public}@ — using system default device: %{public}@",
               reason, device.localizedName)
        return device
    }

    private func defaultCaptureDevice(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio) ?? devices.first
    }

    // MARK: - Capture callback

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard recordingFlag() else { return }
        let pcmBuffer: AVAudioPCMBuffer
        do {
            guard let decoded = try makePCMBuffer(sampleBuffer) else { return }
            pcmBuffer = decoded
        } catch {
            fileWriteErrorLock.withLock {
                if self.fileWriteError == nil {
                    self.fileWriteError = error
                }
            }
            os_log(.error, log: audioRecorderLog,
                   "failed to decode audio buffer: %{public}@",
                   error.localizedDescription)
            reportRecordingFailure(error)
            return
        }
        if !loggedCaptureFormat {
            loggedCaptureFormat = true
            os_log(.debug, log: audioRecorderLog,
                   "capture format: %{public}@",
                   String(describing: pcmBuffer.format.settings))
        }
        do {
            try appendSampleBufferToFile(pcmBuffer)
        } catch {
            fileWriteErrorLock.withLock {
                if self.fileWriteError == nil {
                    self.fileWriteError = error
                }
            }
            os_log(.error, log: audioRecorderLog,
                   "failed to append audio buffer: %{public}@",
                   error.localizedDescription)
            reportRecordingFailure(error)
            return
        }
        emitPCM16IfNeeded(pcmBuffer)
        bufferCountLock.withLock { $0 += 1 }
        let rms = updateAudioLevel(pcmBuffer)
        let bufferNumber = bufferCountLock.withLock { $0 }
        if bufferNumber <= Self.sampleRateLogLimit {
            os_log(.debug, log: audioRecorderLog,
                   "buffer #%{public}d at %.3fms, rms=%{public}f",
                   Int32(bufferNumber), (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000, rms)
        }
        if !readyFired && rms > 0 {
            readyFired = true
            os_log(.debug, log: audioRecorderLog,
                   "FIRST non-silent buffer at %.3fms — recording ready",
                   (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000)
            DispatchQueue.main.async {
                self.onRecordingReady?()
            }
        }
    }

    // MARK: - File branch (16 kHz Int16 WAV)

    private func pcmFileSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: recordingTargetFormat.sampleRate,
            AVNumberOfChannelsKey: recordingTargetFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private func appendSampleBufferToFile(_ pcmBuffer: AVAudioPCMBuffer) throws {
        let sourceFormat = try validatedPCMBufferFormat(pcmBuffer.format,
                                                        context: "capture sample buffer")
        let targetFormat = activeAudioFormat ?? recordingTargetFormat
        if activeAudioFile == nil {
            guard let url = tempFileURL else {
                throw AudioRecorderError.failedToBeginFileRecording("Recording file URL is missing.")
            }
            let file = try AVAudioFile(forWriting: url,
                                       settings: pcmFileSettings(),
                                       commonFormat: .pcmFormatInt16,
                                       interleaved: true)
            activeAudioFile = file
            activeAudioFormat = recordingTargetFormat
        }
        guard activeAudioFile != nil else {
            throw AudioRecorderError.failedToBeginFileRecording("Recording file is not open.")
        }
        let outputBuffer: AVAudioPCMBuffer
        if sourceFormat == recordingTargetFormat {
            outputBuffer = pcmBuffer
        } else {
            guard let converter = recordingConverterCache.get(matching: sourceFormat,
                                                              target: targetFormat) else {
                throw AudioRecorderError.failedToBeginFileRecording(
                    "Could not create recording converter.")
            }
            outputBuffer = try convertRecordingBuffer(from: pcmBuffer,
                                                      using: converter,
                                                      to: targetFormat)
        }
        try activeAudioFile?.write(from: outputBuffer)
        recordedFrameCount += AVAudioFramePosition(outputBuffer.frameLength)
    }

    @discardableResult
    private func finishAudioFileLocked(discard: Bool) -> URL? {
        sampleBufferQueue.sync {}
        activeAudioFile = nil
        activeAudioFormat = nil
        let frames = recordedFrameCount
        let writeError = fileWriteErrorLock.withLock { self.fileWriteError }
        let keptURL: URL?
        if !discard, frames > 0, writeError == nil, let url = tempFileURL {
            keptURL = url
        } else if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            keptURL = nil
        } else {
            keptURL = nil
        }
        recordedFrameCount = 0
        fileWriteErrorLock.withLock { self.fileWriteError = nil }
        tempFileURL = nil
        return keptURL
    }

    private func removeTempFileLocked() {
        guard let url = tempFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        tempFileURL = nil
    }

    // MARK: - Realtime branch (24 kHz Int16 stream)

    private func emitPCM16IfNeeded(_ pcmBuffer: AVAudioPCMBuffer) {
        guard onPCM16Samples != nil else { return }
        guard let sourceFormat = try? validatedPCMBufferFormat(
                pcmBuffer.format,
                context: "realtime transcription sample buffer"),
              let converter = pcm16ConverterCache.get(matching: sourceFormat,
                                                      target: pcm16TargetFormat),
              let outputBuffer = try? convertRecordingBuffer(from: pcmBuffer,
                                                             using: converter,
                                                             to: pcm16TargetFormat),
              let int16ChannelData = outputBuffer.int16ChannelData else { return }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }
        let data = Data(bytes: int16ChannelData[0], count: byteCount)
        onPCM16Samples?(data)
    }

    // MARK: - Conversion

    private func validatedPCMBufferFormat(_ format: AVAudioFormat,
                                          context: String) throws -> AVAudioFormat {
        switch format.commonFormat {
        case .pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32:
            break
        default:
            throw AudioRecorderError.invalidInputFormat(
                "\(context) is not PCM (commonFormat=\(format.commonFormat.rawValue), settings=\(String(describing: format.settings)))")
        }
        guard format.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat("\(context) reported zero channels.")
        }
        guard format.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) reported an invalid sample rate (\(format.sampleRate)).")
        }
        return format
    }

    private func convertRecordingBuffer(from buffer: AVAudioPCMBuffer,
                                        using converter: AVAudioConverter,
                                        to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let sourceRate = buffer.format.sampleRate
        let targetRate = targetFormat.sampleRate
        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetRate / sourceRate) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: max(capacity, 1)) else {
            throw AudioRecorderError.failedToBeginFileRecording(
                "Could not allocate conversion buffer.")
        }
        var inputSubmitted = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if inputSubmitted {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputSubmitted = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw AudioRecorderError.failedToBeginFileRecording(
                "Audio conversion failed: \(conversionError.localizedDescription)")
        }
        guard status != .error, outputBuffer.frameLength > 0 else {
            throw AudioRecorderError.failedToBeginFileRecording(
                "Audio conversion produced no data.")
        }
        return outputBuffer
    }

    private func makePCMBuffer(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioRecorderError.failedToBeginFileRecording(
                "Could not read sample buffer format.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                               frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw AudioRecorderError.failedToBeginFileRecording(
                "Could not allocate sample buffer.")
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList)
        guard status == noErr else {
            throw AudioRecorderError.failedToBeginFileRecording(
                "Could not copy sample buffer data (OSStatus \(status)).")
        }
        return pcmBuffer
    }

    // MARK: - Level

    @discardableResult
    private func updateAudioLevel(_ pcmBuffer: AVAudioPCMBuffer) -> Float {
        guard (try? validatedPCMBufferFormat(pcmBuffer.format,
                                             context: "audio level sample buffer")) != nil else {
            return 0
        }
        let rms = rmsLevel(for: pcmBuffer)
        let level = liveLevelNormalizerLock.withLock { $0.normalizedLevel(forRMS: rms) }
        DispatchQueue.main.async {
            self.audioLevel = level
        }
        return rms
    }

    private func rmsLevel(for buffer: AVAudioPCMBuffer) -> Float {
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var sumOfSquares: Double = 0
        var totalSamples = 0
        let commonFormat = buffer.format.commonFormat
        for audioBuffer in bufferList {
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
            let byteSize = Int(audioBuffer.mDataByteSize)
            switch commonFormat {
            case .pcmFormatFloat32:
                let count = byteSize / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let sample = Double(samples[index])
                    sumOfSquares += sample * sample
                }
                totalSamples += count
            case .pcmFormatFloat64:
                let count = byteSize / MemoryLayout<Double>.size
                let samples = data.assumingMemoryBound(to: Double.self)
                for index in 0..<count {
                    let sample = samples[index]
                    sumOfSquares += sample * sample
                }
                totalSamples += count
            case .pcmFormatInt16:
                let count = byteSize / MemoryLayout<Int16>.size
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let sample = Double(samples[index]) / 32768.0
                    sumOfSquares += sample * sample
                }
                totalSamples += count
            case .pcmFormatInt32:
                let count = byteSize / MemoryLayout<Int32>.size
                let samples = data.assumingMemoryBound(to: Int32.self)
                for index in 0..<count {
                    let sample = Double(samples[index]) / 2147483648.0
                    sumOfSquares += sample * sample
                }
                totalSamples += count
            default:
                continue
            }
        }
        guard totalSamples > 0 else { return 0 }
        return Float(sqrt(sumOfSquares / Double(totalSamples)))
    }

    // MARK: - Flags

    private func recordingFlag() -> Bool {
        recordingFlagLock.withLock { $0 }
    }

    private func setRecordingFlag(_ value: Bool) {
        recordingFlagLock.withLock { $0 = value }
    }
}
