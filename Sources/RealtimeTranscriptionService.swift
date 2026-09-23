import Foundation
import os

enum RealtimeTranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case notConnected
    case serverError(code: String, message: String)
    case closedBeforeFinal

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "Cannot derive a WebSocket URL from \(url)"
        case .notConnected:
            return "Realtime transcription socket is not connected"
        case .serverError(let code, let message):
            return "Realtime server error [\(code)]: \(message)"
        case .closedBeforeFinal:
            return "Realtime socket closed before emitting the final transcript"
        }
    }
}

final class RealtimeTranscriptionService: RealtimeTranscriptBackend {
    struct Configuration {
        let baseURL: String
        let apiKey: String
        let model: String
        let language: String?
    }

    var onPartialUpdate: ((String) -> Void)?

    private let config: Configuration
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var commitSent = false
    private var commitEventCount: Int?
    private var serverEventCount = 0
    private var partialText = ""
    private var finalText = ""
    private var postCommitCompleted = false
    private var lastItemId: String?
    private var terminalError: Error?
    private var closed = false
    private var finalContinuation: CheckedContinuation<String, Error>?

    private static let realtimeLog = OSLog(subsystem: "com.nick8cyber.omniflow",
                                           category: "RealtimeTranscription")

    init(config: Configuration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    static func deriveWebSocketURL(baseURL: String,
                                   model: String,
                                   language: String?) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }
        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            return nil
        }
        var path = components.path
        if path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        if path.hasSuffix("/v1") {
            path += "/realtime"
        } else {
            path += "/v1/realtime"
        }
        components.path = path
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name.lowercased() == "intent" }) {
            queryItems.append(URLQueryItem(name: "intent", value: "transcription"))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    func start() throws {
        guard let url = Self.deriveWebSocketURL(baseURL: config.baseURL,
                                                model: config.model,
                                                language: config.language) else {
            throw RealtimeTranscriptionError.invalidBaseURL(config.baseURL)
        }
        var request = URLRequest(url: url)
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let webSocketTask = session.webSocketTask(with: request)
        lock.lock()
        task = webSocketTask
        lock.unlock()
        webSocketTask.resume()
        let receive = Task<Void, Never> { [weak self] in
            await self?.receiveLoop()
        }
        lock.lock()
        receiveTask = receive
        lock.unlock()
        sendSessionUpdate(over: webSocketTask)
    }

    private func sendSessionUpdate(over webSocketTask: URLSessionWebSocketTask) {
        var transcription: [String: Any] = [:]
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            transcription["model"] = model
        }
        if let language = config.language, !language.isEmpty {
            transcription["language"] = language
        }
        // turn_detection is always null: the server never commits on its own.
        let message: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
        send(message, over: webSocketTask)
    }

    func appendPCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        let currentTask = activeTask()
        guard let currentTask = currentTask else { return }
        send(["type": "input_audio_buffer.append",
              "audio": data.base64EncodedString()],
             over: currentTask)
    }

    func commitAndAwaitFinal() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var outcome: Result<String, Error>?
            var sendTarget: URLSessionWebSocketTask?
            var closeTarget: URLSessionWebSocketTask?
            lock.lock()
            if task == nil {
                outcome = .failure(RealtimeTranscriptionError.notConnected)
            } else {
                if !commitSent {
                    commitSent = true
                    commitEventCount = serverEventCount
                    postCommitCompleted = false
                    sendTarget = task
                }
                if let terminalError = terminalError {
                    outcome = .failure(terminalError)
                } else if closed {
                    outcome = .failure(RealtimeTranscriptionError.closedBeforeFinal)
                } else if let ready = readyCommittedTranscriptLocked() {
                    closed = true
                    closeTarget = task
                    outcome = .success(ready)
                } else {
                    finalContinuation = continuation
                }
            }
            lock.unlock()

            if let outcome = outcome {
                closeTarget?.cancel(with: .normalClosure, reason: nil)
                continuation.resume(with: outcome)
                return
            }
            if let sendTarget = sendTarget {
                send(["type": "input_audio_buffer.commit"], over: sendTarget)
            }
        }
    }

    func cancel() {
        var closeTask: URLSessionWebSocketTask?
        var pendingContinuation: CheckedContinuation<String, Error>?
        var receive: Task<Void, Never>?
        lock.lock()
        closeTask = task
        task = nil
        closed = true
        pendingContinuation = finalContinuation
        finalContinuation = nil
        receive = receiveTask
        lock.unlock()
        receive?.cancel()
        closeTask?.cancel(with: .normalClosure, reason: nil)
        pendingContinuation?.resume(throwing: CancellationError())
    }

    // MARK: - Receive loop

    private func receiveLoop() async {
        while true {
            let currentTask = activeTask()
            guard let currentTask = currentTask else { return }
            do {
                let message = try await currentTask.receive()
                switch message {
                case .string(let text):
                    handleServerEvent(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleServerEvent(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                finishWithClose()
                return
            }
        }
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }

        lock.lock()
        serverEventCount += 1
        lock.unlock()

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            let itemId = object["item_id"] as? String
            let delta = object["delta"] as? String
            var snapshot: String?
            lock.lock()
            if let itemId = itemId {
                lastItemId = itemId
            }
            if let delta = delta, !delta.isEmpty {
                partialText += delta
            }
            snapshot = finalText + partialText
            lock.unlock()
            if let snapshot = snapshot {
                emitPartial(snapshot)
            }
            resumeIfReadyAfterCommit()
        case "conversation.item.input_audio_transcription.completed":
            let itemId = object["item_id"] as? String
            let transcript = object["transcript"] as? String
            lock.lock()
            if let itemId = itemId {
                lastItemId = itemId
            }
            if let commitCount = commitEventCount, serverEventCount > commitCount {
                postCommitCompleted = true
            }
            lock.unlock()
            if let transcript = transcript {
                commitSegment(transcript)
            } else {
                resumeIfReadyAfterCommit()
            }
        case "input_audio_buffer.committed":
            let itemId = object["item_id"] as? String
            lock.lock()
            if let itemId = itemId {
                lastItemId = itemId
            }
            lock.unlock()
            resumeIfReadyAfterCommit()
        case "error":
            let nested = object["error"] as? [String: Any]
            let rawCode = nested?["code"]
            let code: String
            if let stringCode = rawCode as? String {
                code = stringCode
            } else if let numberCode = rawCode as? NSNumber {
                code = numberCode.stringValue
            } else {
                code = "unknown"
            }
            let message = nested?["message"] as? String ?? "unknown realtime error"
            os_log(.error, log: Self.realtimeLog,
                   "realtime server error %{private}@ / %{private}@", code, message)
            var pendingContinuation: CheckedContinuation<String, Error>?
            var failure: RealtimeTranscriptionError?
            lock.lock()
            let serverFailure = RealtimeTranscriptionError.serverError(code: code, message: message)
            terminalError = serverFailure
            closed = true
            if let stored = finalContinuation {
                finalContinuation = nil
                pendingContinuation = stored
                failure = serverFailure
            }
            lock.unlock()
            if let pendingContinuation = pendingContinuation, let failure = failure {
                pendingContinuation.resume(throwing: failure)
            }
        default:
            resumeIfReadyAfterCommit()
        }
    }

    private func commitSegment(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshot: String?
        lock.lock()
        if !trimmed.isEmpty {
            if !finalText.isEmpty {
                finalText += " "
            }
            finalText += trimmed
        }
        partialText = ""
        snapshot = finalText + partialText
        lock.unlock()
        if let snapshot = snapshot {
            emitPartial(snapshot)
        }
        resumeIfReadyAfterCommit()
    }

    private func resumeIfReadyAfterCommit() {
        var pendingContinuation: CheckedContinuation<String, Error>?
        var finalTranscript: String?
        var closeTask: URLSessionWebSocketTask?
        lock.lock()
        if finalContinuation != nil, let ready = readyCommittedTranscriptLocked() {
            pendingContinuation = finalContinuation
            finalContinuation = nil
            closed = true
            closeTask = task
            finalTranscript = ready
        }
        lock.unlock()
        if let pendingContinuation = pendingContinuation, let finalTranscript = finalTranscript {
            closeTask?.cancel(with: .normalClosure, reason: nil)
            pendingContinuation.resume(returning: finalTranscript)
        }
    }

    private func finishWithClose() {
        var pendingContinuation: CheckedContinuation<String, Error>?
        var outcome: Result<String, Error>?
        lock.lock()
        closed = true
        if let stored = finalContinuation {
            finalContinuation = nil
            pendingContinuation = stored
            if postCommitCompleted {
                outcome = .success(finalText)
            } else {
                outcome = .failure(RealtimeTranscriptionError.closedBeforeFinal)
            }
        }
        lock.unlock()
        if let pendingContinuation = pendingContinuation, let outcome = outcome {
            pendingContinuation.resume(with: outcome)
        }
    }

    // MARK: - Helpers

    private func readyCommittedTranscriptLocked() -> String? {
        guard commitSent, partialText.isEmpty, postCommitCompleted else { return nil }
        return finalText
    }

    private func activeTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func emitPartial(_ snapshot: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onPartialUpdate?(snapshot)
        }
    }

    private func send(_ payload: [String: Any], over webSocketTask: URLSessionWebSocketTask) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            os_log(.info, log: Self.realtimeLog, "dropped non-serializable realtime payload")
            return
        }
        webSocketTask.send(.string(text)) { error in
            if let error = error {
                os_log(.info, log: Self.realtimeLog,
                       "realtime send failed: %{private}@", error.localizedDescription)
            }
        }
    }
}
