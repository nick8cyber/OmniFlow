import Foundation
import os

final class GeminiLiveTranscriptionService: RealtimeTranscriptBackend {
    struct Configuration {
        let baseURL: String
        let apiKey: String
        let model: String
        let customVocabulary: String
        let sampleRate: Int
    }

    var onPartialUpdate: ((String) -> Void)?

    private let config: Configuration
    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "com.nick8cyber.omniflow.gemini-live-transcription")
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let accumulator = LiveTranscriptAccumulator()
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var streamEnded = false
    private var closed = false
    private var setupCompleted = false
    private var terminalError: Error?
    private var lastInterimAt = CFAbsoluteTimeGetCurrent()
    private var streamEndedAt = CFAbsoluteTimeGetCurrent()

    private static let liveLog = OSLog(subsystem: "com.nick8cyber.omniflow",
                                       category: "GeminiLiveTranscription")
    // Adaptive finish, ported from the Windows build (verified 2026-10-26):
    // transcribe-live models keep refining the tail for up to ~3.2 s AFTER the
    // audio stops, and pure silence never triggers the server's VAD at all —
    // so the wait is bounded by quiet time, a post-stop minimum and a hard cap
    // instead of waiting for a turnComplete that may never arrive.
    private static let finishMinWait: TimeInterval = 0.8
    private static let finishSettle: TimeInterval = 1.0
    private static let finishTimeout: TimeInterval = 6.0
    private static let finishPollInterval: TimeInterval = 0.08

    init(config: Configuration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func start() throws {
        guard let url = GeminiLiveTranscription.socketURL(baseURL: config.baseURL) else {
            throw RealtimeTranscriptionError.invalidBaseURL(config.baseURL)
        }
        var request = URLRequest(url: url)
        // The key travels in a header so it never lands in the URL or logs.
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        let webSocketTask = session.webSocketTask(with: request)
        stateQueue.sync {
            socket = webSocketTask
        }
        webSocketTask.resume()
        let setup = try GeminiLiveTranscription.setupMessage(model: config.model,
                                                             customVocabulary: config.customVocabulary)
        webSocketTask.send(.string(setup)) { error in
            if let error = error {
                os_log(.error, log: Self.liveLog,
                       "failed to send Gemini live setup: %{private}@", error.localizedDescription)
            }
        }
        let receive = Task<Void, Never> { [weak self] in
            await self?.receiveLoop()
        }
        stateQueue.sync {
            receiveTask = receive
        }
    }

    func appendPCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        let (task, isClosed) = stateQueue.sync { () -> (URLSessionWebSocketTask?, Bool) in
            (socket, closed)
        }
        guard let task = task, !isClosed else { return }
        guard let message = try? GeminiLiveTranscription.audioMessage(pcm16: data,
                                                                      sampleRate: config.sampleRate) else {
            return
        }
        task.send(.string(message)) { error in
            if let error = error {
                os_log(.info, log: Self.liveLog,
                       "failed to send audio chunk: %{private}@", error.localizedDescription)
            }
        }
    }

    func commitAndAwaitFinal() async throws -> String {
        // Built up front: the frame is a constant literal, so failure is
        // practically unreachable — but if it ever happens the continuation
        // must be pulled back out of the state before resuming, or a late
        // turnComplete would resume it a second time.
        let streamEndMessage = try? GeminiLiveTranscription.audioStreamEndMessage()
        return try await withCheckedThrowingContinuation { continuation in
            let state = stateQueue.sync { () -> (task: URLSessionWebSocketTask?,
                                                 outcome: Result<String, Error>?) in
                if socket == nil || closed {
                    return (nil, .failure(RealtimeTranscriptionError.notConnected))
                }
                if let terminalError = terminalError {
                    return (nil, .failure(terminalError))
                }
                if streamEnded {
                    return (nil, .success(accumulator.finalText()))
                }
                streamEnded = true
                streamEndedAt = CFAbsoluteTimeGetCurrent()
                finalContinuation = continuation
                return (socket, nil)
            }
            if let outcome = state.outcome {
                continuation.resume(with: outcome)
                return
            }
            scheduleAdaptiveFinishCheck()
            guard let message = streamEndMessage else {
                let pending = stateQueue.sync { () -> CheckedContinuation<String, Error>? in
                    let stored = finalContinuation
                    finalContinuation = nil
                    closed = true
                    return stored
                }
                pending?.resume(throwing: RealtimeTranscriptionError.closedBeforeFinal)
                return
            }
            state.task?.send(.string(message)) { error in
                if let error = error {
                    os_log(.info, log: Self.liveLog,
                           "failed to send audio stream end: %{private}@", error.localizedDescription)
                }
            }
        }
    }

    /// Adaptive finish wait (see `finishMinWait`/`finishSettle`/`finishTimeout`).
    /// Resumes with everything accumulated so far — empty on pure silence — so
    /// the pipeline lands in the normal "Nothing to transcribe" path instead of
    /// leaving the overlay spinner up forever. Runs on stateQueue.
    private func scheduleAdaptiveFinishCheck() {
        stateQueue.asyncAfter(deadline: .now() + Self.finishPollInterval) { [weak self] in
            guard let self, let pending = self.finalContinuation else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let sinceStop = now - self.streamEndedAt
            let sinceLast = now - self.lastInterimAt
            let timedOut = sinceStop >= Self.finishTimeout
            guard timedOut || (sinceStop >= Self.finishMinWait && sinceLast >= Self.finishSettle) else {
                self.scheduleAdaptiveFinishCheck()
                return
            }
            self.finalContinuation = nil
            self.closed = true
            if timedOut {
                os_log(.info, log: Self.liveLog,
                       "live finish timed out after %.0fs; returning %{public}d transcript characters",
                       Self.finishTimeout, Int32(self.accumulator.finalText().count))
            }
            pending.resume(returning: self.accumulator.finalText())
        }
    }

    func cancel() {
        let (task, pendingContinuation, receive) = stateQueue.sync { () -> (URLSessionWebSocketTask?,
                                                                             CheckedContinuation<String, Error>?,
                                                                             Task<Void, Never>?) in
            closed = true
            let task = socket
            socket = nil
            let continuation = finalContinuation
            finalContinuation = nil
            return (task, continuation, receiveTask)
        }
        receive?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        pendingContinuation?.resume(throwing: CancellationError())
    }

    // MARK: - Receive loop

    private func receiveLoop() async {
        while true {
            let (task, isClosed) = stateQueue.sync { () -> (URLSessionWebSocketTask?, Bool) in
                (socket, closed)
            }
            guard let task = task, !isClosed else { return }
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleFrame(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                handleReceiveFailure(error)
                return
            }
        }
    }

    private func handleFrame(_ text: String) {
        let frame = GeminiLiveTranscription.parseServerFrame(text)
        if frame.isSetupComplete {
            stateQueue.sync {
                setupCompleted = true
                // Arm the settle timer from setup: with pure silence no interim
                // ever arrives, and the adaptive finish must still fire.
                lastInterimAt = CFAbsoluteTimeGetCurrent()
            }
            return
        }
        if let errorMessage = frame.errorMessage {
            os_log(.error, log: Self.liveLog, "gemini live error: %{private}@", errorMessage)
            var pendingContinuation: CheckedContinuation<String, Error>?
            var failure: RealtimeTranscriptionError?
            stateQueue.sync {
                let serverFailure = RealtimeTranscriptionError.serverError(code: "live",
                                                                           message: errorMessage)
                if let stored = finalContinuation {
                    finalContinuation = nil
                    closed = true
                    pendingContinuation = stored
                    failure = serverFailure
                } else {
                    terminalError = serverFailure
                }
            }
            if let pendingContinuation = pendingContinuation, let failure = failure {
                pendingContinuation.resume(throwing: failure)
            }
            return
        }
        if frame.activityStartsSegment || frame.activityEndsSegment || frame.interimTranscript != nil || frame.transcript != nil {
            let snapshot = stateQueue.sync { () -> String in
                let now = CFAbsoluteTimeGetCurrent()
                lastInterimAt = now
                if frame.activityStartsSegment {
                    accumulator.startSegment()
                }
                if frame.activityEndsSegment {
                    accumulator.endSegment()
                }
                if let interim = frame.interimTranscript {
                    accumulator.feedInterim(interim)
                }
                if let delta = frame.transcript {
                    accumulator.feedDelta(delta)
                }
                return accumulator.current()
            }
            DispatchQueue.main.async { [weak self] in
                self?.onPartialUpdate?(snapshot)
            }
        }
        if frame.isComplete {
            var pendingContinuation: CheckedContinuation<String, Error>?
            var outcome: Result<String, Error>?
            stateQueue.sync {
                // turnComplete is the server's final word even when nothing was
                // recognized: an empty transcript ends the session normally
                // instead of triggering a redundant batch round-trip.
                if let stored = finalContinuation {
                    finalContinuation = nil
                    closed = true
                    pendingContinuation = stored
                    outcome = .success(accumulator.finalText())
                } else {
                    closed = true
                }
            }
            if let pendingContinuation = pendingContinuation, let outcome = outcome {
                pendingContinuation.resume(with: outcome)
            }
        }
    }

    private func handleReceiveFailure(_ error: Error) {
        var pendingContinuation: CheckedContinuation<String, Error>?
        var failure: Error?
        stateQueue.sync {
            guard !closed else { return }
            let described: Error
            if setupCompleted {
                described = error
            } else {
                // The Live API rejects bad credentials on the HTTP upgrade itself —
                // the socket never connects and no error frame arrives.
                described = RealtimeTranscriptionError.serverError(
                    code: "live",
                    message: "Could not connect to Gemini live transcription. Check the transcription API key.")
            }
            closed = true
            if let stored = finalContinuation {
                finalContinuation = nil
                pendingContinuation = stored
                failure = described
            } else {
                terminalError = described
            }
        }
        if let pendingContinuation = pendingContinuation, let failure = failure {
            pendingContinuation.resume(throwing: failure)
        }
    }

    private func closeSocket(_ closeCode: URLSessionWebSocketTask.CloseCode) {
        let task = stateQueue.sync { () -> URLSessionWebSocketTask? in
            let task = socket
            socket = nil
            closed = true
            return task
        }
        task?.cancel(with: closeCode, reason: nil)
    }
}
