import Foundation

enum LLMCooldownManagerTests {
    static func run() {
        testDailyQuotaTakesPriority()
        testRetryAndTokenDurations()
        testMalformedDurationsUseSafeFallback()
        testPersistenceKeyIsStable()
        runAndWait {
            await testEffectivePrimaryReturnsNilWhenBothModelsCoolDown()
            await testCooldownSkipReturnsRawTranscriptFlaggedAsSkipped()
        }
    }

    private static let groqChatCompletionsURL =
        URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    private static func rateLimitResponse(_ headerFields: [String: String]) -> HTTPURLResponse {
        let response = HTTPURLResponse(url: groqChatCompletionsURL,
                                       statusCode: 429,
                                       httpVersion: nil,
                                       headerFields: headerFields)
        expect(response != nil, "failed to build synthetic 429 response")
        return response!
    }

    // MARK: - 1

    private static func testDailyQuotaTakesPriority() {
        let daily = LLMCooldownManager.rateLimitCooldown(from: rateLimitResponse([
            "x-ratelimit-remaining-requests": "0",
            "x-ratelimit-reset-requests": "2m59.56s",
            "retry-after": "2"
        ]))
        expectApproximatelyEqual(daily.seconds, 179.56)
        expectEqual(daily.isDaily, true)

        let notDaily = LLMCooldownManager.rateLimitCooldown(from: rateLimitResponse([
            "x-ratelimit-remaining-requests": "1",
            "x-ratelimit-reset-requests": "2m59.56s",
            "retry-after": "7.66"
        ]))
        expectApproximatelyEqual(notDaily.seconds, 7.66)
        expectEqual(notDaily.isDaily, false)
    }

    // MARK: - 2

    private static func testRetryAndTokenDurations() {
        let milliseconds = LLMCooldownManager.rateLimitCooldown(from: rateLimitResponse([
            "retry-after": "120ms"
        ]))
        expectApproximatelyEqual(milliseconds.seconds, 0.12)

        let compound = LLMCooldownManager.rateLimitCooldown(from: rateLimitResponse([
            "retry-after": "1h2m3.5s"
        ]))
        expectApproximatelyEqual(compound.seconds, 3723.5)

        let tokens = LLMCooldownManager.rateLimitCooldown(from: rateLimitResponse([
            "x-ratelimit-reset-tokens": "8.25s"
        ]))
        expectApproximatelyEqual(tokens.seconds, 8.25)
        expectEqual(tokens.isDaily, false, "token reset cooldown is not daily")
    }

    // MARK: - 3

    private static func testMalformedDurationsUseSafeFallback() {
        for malformed in ["-3", "nan", "inf", "1d", "1h30", ""] {
            let fallback = LLMCooldownManager.rateLimitCooldown(from: rateLimitResponse([
                "retry-after": malformed
            ]))
            expectApproximatelyEqual(fallback.seconds, 60)
            expectEqual(fallback.isDaily, false,
                        "malformed duration \(malformed) must not be daily")
        }
    }

    // MARK: - 4

    private static func testPersistenceKeyIsStable() {
        expectEqual(LLMCooldownManager.udKey(for: "openai/gpt-oss-20b"),
                    "llm_cooldown_expiry_openai/gpt-oss-20b",
                    "cooldown persistence key format is stable for SettingsView")
    }

    // MARK: - 5 (circuit breaker)

    private static func testEffectivePrimaryReturnsNilWhenBothModelsCoolDown() async {
        let manager = LLMCooldownManager()
        await manager.setCooldown("suite.cb.primary", retryAfterSeconds: 300)
        await manager.setCooldown("suite.cb.fallback", retryAfterSeconds: 300)
        let effective = await manager.effectivePrimary("suite.cb.primary",
                                                       fallback: "suite.cb.fallback")
        expect(effective == nil,
               "circuit breaker must return nil when primary and fallback are both cooling down")
        let recovered = await manager.effectivePrimary("suite.cb.primary", fallback: "suite.cb.other")
        expectEqual(recovered, "suite.cb.other",
                    "a model outside the cooldown must remain usable")
    }

    // MARK: - 6 (cooldown skip is not a success)

    private static func testCooldownSkipReturnsRawTranscriptFlaggedAsSkipped() async {
        await LLMCooldownManager.shared.setCooldown("suite.skip.primary", retryAfterSeconds: 300)
        await LLMCooldownManager.shared.setCooldown("suite.skip.fallback", retryAfterSeconds: 300)
        let service = PostProcessingService(apiKey: "test-key",
                                            baseURL: "https://api.groq.com/openai/v1",
                                            preferredModel: "suite.skip.primary",
                                            preferredFallbackModel: "suite.skip.fallback",
                                            instructionExecutionGuardEnabled: false)
        let context = AppContext(appName: nil,
                                 bundleIdentifier: nil,
                                 windowTitle: nil,
                                 selectedText: nil,
                                 currentActivity: "cooldown suite",
                                 contextSystemPrompt: nil,
                                 contextPrompt: nil,
                                 screenshotDataURL: nil,
                                 screenshotMimeType: nil,
                                 screenshotError: nil)
        do {
            let result = try await service.postProcess(transcript: "emm so like cooldown test",
                                                       context: context,
                                                       customVocabulary: "")
            expectEqual(result.transcript, "emm so like cooldown test",
                        "cooldown skip must return the raw transcript untouched")
            expectEqual(result.skippedCooldown, true,
                        "cooldown skip must be flagged so the pipeline never reports success")
            expectEqual(result.prompt, "", "cooldown skip must not carry a prompt")
        } catch {
            fatalError("\(#file):\(#line): postProcess unexpectedly threw \(error)")
        }
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
