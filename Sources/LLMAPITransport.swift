import Foundation

enum LLMAPITransport {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = makeSession(timeout: request.timeoutInterval)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    static func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        let session = makeSession(timeout: request.timeoutInterval)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: bodyData)
    }

    // A fresh ephemeral session per request — no shared pools, so no poisoned
    // connection reuse between LLM calls.
    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let resolvedTimeout = timeout.isFinite && timeout > 0 ? timeout : 60
        configuration.timeoutIntervalForRequest = resolvedTimeout
        configuration.timeoutIntervalForResource = resolvedTimeout
        return URLSession(configuration: configuration)
    }
}
