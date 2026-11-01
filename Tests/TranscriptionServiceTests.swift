import Foundation

// Covers the key-validation contract of Sources/TranscriptionService.swift:
// a rejected key (401/403) must be distinguishable from an unreachable
// provider (network error, timeout, 429, 5xx) — no network access needed.
enum TranscriptionServiceTests {
    static func run() {
        runAndWait {
            await testBlankKeyIsReportedAsInvalidWithoutNetwork()
            await testRetryLoopRepeatsTransientFailuresOnSameProvider()
        }
        testValidateOutcomeMapsHTTPStatuses()
        testUnreachableMessageDistinguishesTimeout()
        testRetryPolicyClassifiesErrors()
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

// MARK: - Retry policy (Windows parity)

extension TranscriptionServiceTests {
    private static func testRetryPolicyClassifiesErrors() {
        expect(TranscriptionService.isRetryableTranscriptionError(TranscriptionError.emptyTranscript),
               "empty output is transient and retryable")
        expect(TranscriptionService.isRetryableTranscriptionError(TranscriptionError.transcriptionTimedOut(20)),
               "timeouts are retryable")
        expect(TranscriptionService.isRetryableTranscriptionError(TranscriptionError.pollFailed("bad json")),
               "malformed responses are retryable")
        expect(TranscriptionService.isRetryableTranscriptionError(TranscriptionError.uploadFailed("dropped")),
               "upload transport failures are retryable")
        expect(TranscriptionService.isRetryableTranscriptionError(TranscriptionError.httpStatus(503, "server error")),
               "5xx is retryable")
        expect(TranscriptionService.isRetryableTranscriptionError(URLError(.networkConnectionLost)),
               "raw network errors are retryable")

        expect(!TranscriptionService.isRetryableTranscriptionError(TranscriptionError.httpStatus(429, "rate limit")),
               "429 fails fast — the fallback chain owns rate limits")
        expect(!TranscriptionService.isRetryableTranscriptionError(TranscriptionError.httpStatus(401, "bad key")),
               "4xx client errors fail fast")
        expect(!TranscriptionService.isRetryableTranscriptionError(TranscriptionError.invalidBaseURL("bad")),
               "malformed URLs are never retried")
        expect(!TranscriptionService.isRetryableTranscriptionError(TranscriptionError.audioPreparationFailed("missing")),
               "local audio failures are never retried")
        expect(!TranscriptionService.isRetryableTranscriptionError(CancellationError()),
               "cancellations are never retried")
    }

    private static func testRetryLoopRepeatsTransientFailuresOnSameProvider() async {
        var calls = 0
        let text = try? await TranscriptionService.transcribeWithRetries {
            calls += 1
            if calls < 3 {
                throw TranscriptionError.httpStatus(503, "Provider error")
            }
            return "готово"
        }
        expectEqual(calls, 3, "transient failures repeat on the same provider")
        expectEqual(text, "готово", "the retry that succeeds is returned")

        calls = 0
        do {
            _ = try await TranscriptionService.transcribeWithRetries {
                calls += 1
                throw TranscriptionError.httpStatus(401, "Invalid API key")
            }
            expect(false, "a deterministic failure must throw")
        } catch {
            expectEqual(calls, 1, "4xx fails fast without burning quota")
        }

        calls = 0
        do {
            _ = try await TranscriptionService.transcribeWithRetries {
                calls += 1
                return ""
            }
            expect(false, "exhausted empty output must throw")
        } catch {
            expectEqual(calls, TranscriptionService.transcriptionAttempts,
                        "empty output repeats before throwing emptyTranscript")
        }

        calls = 0
        let ok = try? await TranscriptionService.transcribeWithRetries {
            calls += 1
            return "ok"
        }
        expectEqual(calls, 1, "a first-try success does not retry")
        expectEqual(ok, "ok", "a first-try success is returned as-is")
    }
}
