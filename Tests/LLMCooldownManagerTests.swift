import Foundation

enum LLMCooldownManagerTests {
    static func run() {
        testDailyQuotaTakesPriority()
        testRetryAndTokenDurations()
        testMalformedDurationsUseSafeFallback()
        testPersistenceKeyIsStable()
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
}
