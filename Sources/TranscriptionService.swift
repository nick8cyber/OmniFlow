import Foundation
import os

private let transcriptionLog = OSLog(subsystem: "com.nick8cyber.omniflow", category: "Transcription")

/// Result of an onboarding-style API key validation: distinguishes a key the
/// provider rejected from a provider that could not be reached at all.
enum ValidateOutcome: Equatable {
    case valid
    case invalidKey
    case unavailable(String)
}

enum TranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let message):
            return "Invalid provider URL: \(message)"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .submissionFailed(let message):
            return "Submission failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .transcriptionTimedOut(let seconds):
            return "Transcription timed out after \(Int(seconds))s"
        case .pollFailed(let message):
            return "Polling failed: \(message)"
        case .audioPreparationFailed(let message):
            return "Audio preparation failed: \(message)"
        }
    }
}

class TranscriptionService {
    private let apiKey: String
    private let baseURL: String
    private let transcriptionModel: String
    private let language: String?
    private let customVocabulary: String

    init(apiKey: String,
         baseURL: String = "https://api.groq.com/openai/v1",
         transcriptionModel: String = "whisper-large-v3",
         language: String? = nil,
         customVocabulary: String = "") throws {
        self.apiKey = apiKey
        var model = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            model = "whisper-large-v3"
        }
        self.transcriptionModel = model
        var resolvedBaseURL = baseURL
        if GeminiTranscription.handlesModel(model) {
            // Gemini does not speak the OpenAI /audio/transcriptions protocol — swap
            // the (typically Groq) host without making the user edit settings.
            resolvedBaseURL = GeminiTranscription.resolvedBaseURL(from: baseURL)
        }
        self.baseURL = try Self.normalizedBaseURL(from: resolvedBaseURL)
        if let language = language {
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            self.language = trimmed.isEmpty ? nil : trimmed
        } else {
            self.language = nil
        }
        self.customVocabulary = customVocabulary
    }

    private var transcriptionTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "transcription_timeout_seconds")
        return override > 0 ? override : 20
    }

    func transcribe(fileURL: URL) async throws -> String {
        let timeoutSeconds = transcriptionTimeoutSeconds
        let race = TranscriptionTimeoutRaceState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.setContinuation(continuation)
                let uploadTask = Task<Void, Never> {
                    do {
                        let transcript = try await self.transcribeAudio(fileURL: fileURL)
                        race.finish(.success(transcript))
                    } catch {
                        if let urlError = error as? URLError, urlError.code == .timedOut {
                            race.finish(.failure(TranscriptionError.transcriptionTimedOut(timeoutSeconds)))
                        } else {
                            race.finish(.failure(error))
                        }
                    }
                }
                let timerTask = Task<Void, Never> {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    race.finish(.failure(TranscriptionError.transcriptionTimedOut(timeoutSeconds)))
                }
                race.register([uploadTask, timerTask])
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    static func responseFormat(forModel model: String) -> String {
        let modelsSupportingVerboseJSON: Set<String> = [
            "whisper-1",
            "whisper-large-v3",
            "whisper-large-v3-turbo"
        ]
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return modelsSupportingVerboseJSON.contains(normalized) ? "verbose_json" : "json"
    }

    static func validateAPIKey(_ key: String,
                               baseURL: String = "https://api.groq.com/openai/v1") async -> ValidateOutcome {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return .invalidKey }
        guard let normalized = try? normalizedBaseURL(from: baseURL),
              var url = URL(string: normalized) else {
            return .unavailable("Provider URL is malformed.")
        }
        url.appendPathComponent("models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        let response: URLResponse
        do {
            (_, response) = try await LLMAPITransport.data(for: request)
        } catch {
            return .unavailable(Self.unreachableMessage(from: error))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .unavailable("Provider did not return an HTTP response.")
        }
        return validateOutcome(forHTTPStatus: httpResponse.statusCode,
                               host: httpResponse.url?.host)
    }

    /// Pure HTTP status mapping for key validation, kept out of the network
    /// path so tests can pin the contract (401/403 = bad key, everything else
    /// = provider unavailable).
    static func validateOutcome(forHTTPStatus status: Int, host: String?) -> ValidateOutcome {
        switch status {
        case 200:
            return .valid
        case 401, 403:
            return .invalidKey
        default:
            return .unavailable(friendlyHTTPMessage(status: status, host: host))
        }
    }

    static func unreachableMessage(from error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "The provider did not respond in time."
        }
        return "Could not reach the provider — check your internet connection."
    }

    static func friendlyHTTPMessage(status: Int, host: String?) -> String {
        let provider = host ?? "the provider"
        switch status {
        case 401:
            return "Invalid API key for \(provider). Open Settings to fix it."
        case 403:
            return "Key lacks permission for this endpoint at \(provider) (HTTP 403). Check the key's scopes."
        case 404:
            return "Endpoint not found at \(provider) (HTTP 404). Base URL is likely wrong for this provider."
        case 413:
            return "Audio file too large for \(provider) (HTTP 413). Try a shorter recording."
        case 400:
            return "Provider rejected the request (HTTP 400). Check your model name and Base URL in Settings."
        case 429:
            return "Rate limit reached at \(provider) (HTTP 429). Wait a moment and try again."
        case 500..<600:
            return "Provider error at \(provider) (HTTP \(status)). Try again in a moment."
        default:
            return "Request failed at \(provider) (HTTP \(status))."
        }
    }

    // MARK: - Base URL normalization

    private static func normalizedBaseURL(from value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.invalidBaseURL("Provider URL is empty.")
        }
        guard let components = URLComponents(string: trimmed) else {
            throw TranscriptionError.invalidBaseURL("Provider URL is malformed.")
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TranscriptionError.invalidBaseURL("Provider URL must use http or https.")
        }
        guard let host = components.host, !host.isEmpty else {
            throw TranscriptionError.invalidBaseURL("Provider URL must include a host.")
        }
        var path = components.path
        if path == "/" {
            path = ""
        } else {
            path = path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        }
        var normalized = components
        normalized.path = path
        return normalized.url?.absoluteString ?? trimmed
    }

    // MARK: - Batch routing

    private func transcribeAudio(fileURL: URL) async throws -> String {
        if GeminiTranscription.handlesModel(transcriptionModel) {
            return try await transcribeWithGemini(fileURL: fileURL)
        }
        return try await transcribeAudioWithURLSession(fileURL: fileURL)
    }

    // MARK: - OpenAI/Groq multipart

    private func transcribeAudioWithURLSession(fileURL: URL) async throws -> String {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            throw TranscriptionError.audioPreparationFailed(error.localizedDescription)
        }
        guard let endpoint = URL(string: baseURL) else {
            throw TranscriptionError.submissionFailed("Provider URL is malformed.")
        }
        var url = endpoint
        url.appendPathComponent("audio")
        url.appendPathComponent("transcriptions")

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = transcriptionTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let body = makeMultipartBody(boundary: boundary,
                                     audioData: audioData,
                                     fileName: fileURL.lastPathComponent,
                                     audioContentType: audioContentType(for: fileURL.lastPathComponent))
        let (data, response) = try await LLMAPITransport.upload(for: request, from: body)
        return try processBatchResponse(data: data, response: response)
    }

    private func makeMultipartBody(boundary: String,
                                   audioData: Data,
                                   fileName: String,
                                   audioContentType: String) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        func field(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field(name: "model", value: transcriptionModel)
        field(name: "response_format", value: Self.responseFormat(forModel: transcriptionModel))
        if let language = language, !language.isEmpty {
            field(name: "language", value: language)
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(audioContentType)\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func audioContentType(for fileName: String) -> String {
        let pathExtension = (fileName as NSString).pathExtension.lowercased()
        switch pathExtension {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        default:
            return "audio/mp4"
        }
    }

    private func processBatchResponse(data: Data, response: URLResponse) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed("No response from server")
        }
        if httpResponse.statusCode != 200 {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            os_log(.error, log: transcriptionLog,
                   "transcription request failed: HTTP %{public}d body %{private}@",
                   httpResponse.statusCode, bodyString)
            throw TranscriptionError.submissionFailed(
                Self.friendlyHTTPMessage(status: httpResponse.statusCode,
                                         host: httpResponse.url?.host))
        }
        do {
            return try TranscriptionResponseParser.parse(data)
        } catch TranscriptionResponseParsingError.invalidResponse {
            throw TranscriptionError.pollFailed("Invalid response")
        }
    }

    // MARK: - Gemini batch (Interactions API)

    private func transcribeWithGemini(fileURL: URL) async throws -> String {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            throw TranscriptionError.audioPreparationFailed(error.localizedDescription)
        }
        guard let base = URL(string: baseURL) else {
            throw TranscriptionError.submissionFailed("Provider URL is malformed.")
        }
        let endpoint = GeminiTranscription.endpoint(baseURL: base)
        let body: Data
        do {
            body = try GeminiTranscription.requestBody(
                model: transcriptionModel,
                audioData: audioData,
                mimeType: audioContentType(for: fileURL.lastPathComponent),
                customVocabulary: customVocabulary)
        } catch {
            throw TranscriptionError.audioPreparationFailed(error.localizedDescription)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = transcriptionTimeoutSeconds
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await LLMAPITransport.upload(for: request, from: body)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed("No response from server")
        }
        if httpResponse.statusCode != 200 {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            os_log(.error, log: transcriptionLog,
                   "gemini transcription request failed: HTTP %{public}d body %{private}@",
                   httpResponse.statusCode, bodyString)
            throw TranscriptionError.submissionFailed(
                GeminiTranscription.failureMessage(
                    fromResponse: data,
                    fallback: Self.friendlyHTTPMessage(status: httpResponse.statusCode,
                                                       host: httpResponse.url?.host)))
        }
        return try GeminiTranscription.transcript(fromResponse: data)
    }
}

// Coordinates the transcription upload against the timeout timer: whichever
// finishes first resumes the continuation exactly once; the loser is cancelled.
private final class TranscriptionTimeoutRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var tasks: [Task<Void, Never>] = []

    func setContinuation(_ value: CheckedContinuation<String, Error>) {
        lock.lock()
        if let result = pendingResult {
            lock.unlock()
            value.resume(with: result)
            return
        }
        continuation = value
        lock.unlock()
    }

    func register(_ newTasks: [Task<Void, Never>]) {
        lock.lock()
        if finished {
            lock.unlock()
            newTasks.forEach { $0.cancel() }
            return
        }
        tasks.append(contentsOf: newTasks)
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        let target: CheckedContinuation<String, Error>?
        let tasksToCancel: [Task<Void, Never>]
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        target = continuation
        continuation = nil
        if target == nil {
            pendingResult = result
        }
        tasksToCancel = tasks
        tasks = []
        lock.unlock()
        tasksToCancel.forEach { $0.cancel() }
        target?.resume(with: result)
    }

    private var finished = false
}
