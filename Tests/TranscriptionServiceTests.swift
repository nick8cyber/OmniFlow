import Foundation

// Covers the key-validation contract of Sources/TranscriptionService.swift:
// a rejected key (401/403) must be distinguishable from an unreachable
// provider (network error, timeout, 429, 5xx) — no network access needed.
enum TranscriptionServiceTests {
    static func run() {
        runAndWait {
            await testBlankKeyIsReportedAsInvalidWithoutNetwork()
        }
        testValidateOutcomeMapsHTTPStatuses()
        testUnreachableMessageDistinguishesTimeout()
    }

    // MARK: - 1

    private static func testBlankKeyIsReportedAsInvalidWithoutNetwork() async {
        let outcome = await TranscriptionService.validateAPIKey("   ",
                                                                baseURL: "https://api.groq.com/openai/v1")
        expectEqual(outcome, .invalidKey,
                    "blank key must be reported as invalidKey before any request is made")
    }

    // MARK: - 2

    private static func testValidateOutcomeMapsHTTPStatuses() {
        expectEqual(TranscriptionService.validateOutcome(forHTTPStatus: 200, host: "api.groq.com"),
                    .valid,
                    "HTTP 200 validates the key")

        expectEqual(TranscriptionService.validateOutcome(forHTTPStatus: 401, host: "api.groq.com"),
                    .invalidKey,
                    "HTTP 401 must be reported as invalidKey")
        expectEqual(TranscriptionService.validateOutcome(forHTTPStatus: 403, host: "api.groq.com"),
                    .invalidKey,
                    "HTTP 403 must be reported as invalidKey")

        for status in [429, 500, 503] {
            let outcome = TranscriptionService.validateOutcome(forHTTPStatus: status, host: nil)
            guard case .unavailable = outcome else {
                fatalError("\(#file):\(#line): HTTP \(status) must be reported as unavailable, got \(outcome)")
            }
        }

        let rateLimited = TranscriptionService.validateOutcome(forHTTPStatus: 429, host: "api.groq.com")
        guard case .unavailable(let detail) = rateLimited else {
            fatalError("\(#file):\(#line): expected unavailable outcome, got \(rateLimited)")
        }
        expect(detail.contains("429"),
               "unavailable detail should carry the friendly HTTP message (got: \(detail))")
    }

    // MARK: - 3

    private static func testUnreachableMessageDistinguishesTimeout() {
        let timeout = TranscriptionService.unreachableMessage(from: URLError(.timedOut))
        expect(timeout.contains("did not respond"),
               "timeout must produce a timeout-specific message (got: \(timeout))")

        let transport = TranscriptionService.unreachableMessage(from: URLError(.cannotFindHost))
        expect(transport.contains("Could not reach the provider"),
               "transport failures must produce the generic unreachable message (got: \(transport))")
    }

    // MARK: - Helpers

    private static func runAndWait(_ body: @escaping () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            semaphore.signal()
        }
        semaphore.wait()
    }
}
