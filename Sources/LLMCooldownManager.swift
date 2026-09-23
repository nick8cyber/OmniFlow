import Foundation

actor LLMCooldownManager {
    static let shared = LLMCooldownManager()

    private var cooldowns: [String: Date] = [:]
    private let dailyLimitThreshold: TimeInterval = 3600
    private static let defaultReprobeCooldownSeconds: TimeInterval = 60

    func isInCooldown(_ model: String) -> Bool {
        let now = Date()
        if let expiry = cooldowns[model] {
            if expiry > now { return true }
            cooldowns.removeValue(forKey: model)
        }
        let key = Self.udKey(for: model)
        let storedExpiry = UserDefaults.standard.double(forKey: key)
        guard storedExpiry > 0 else { return false }
        let expiry = Date(timeIntervalSince1970: storedExpiry)
        if expiry > now { return true }
        UserDefaults.standard.removeObject(forKey: key)
        return false
    }

    func setCooldown(_ model: String, retryAfterSeconds: TimeInterval, persist: Bool = false) {
        let expiry = Date().addingTimeInterval(retryAfterSeconds)
        if persist || retryAfterSeconds >= dailyLimitThreshold {
            UserDefaults.standard.set(expiry.timeIntervalSince1970,
                                      forKey: Self.udKey(for: model))
        } else {
            cooldowns[model] = expiry
        }
    }

    func effectivePrimary(_ primary: String, fallback: String?) -> String? {
        if !isInCooldown(primary) { return primary }
        if let fallback = fallback, !isInCooldown(fallback) { return fallback }
        return nil
    }

    // Shared key format so SettingsView can read expiry dates synchronously,
    // without hopping through the actor.
    nonisolated static func udKey(for model: String) -> String {
        "llm_cooldown_expiry_\(model)"
    }

    nonisolated static func rateLimitCooldown(from httpResponse: HTTPURLResponse) -> (seconds: TimeInterval, isDaily: Bool) {
        // 1. Exhausted daily request quota (RPD) wins over retry-after: Groq sends
        //    both, and the short retry-after would hide a daily window that must be
        //    persisted.
        if let remainingRaw = httpResponse.value(forHTTPHeaderField: "x-ratelimit-remaining-requests"),
           let remaining = normalizedDouble(remainingRaw),
           remaining <= 0,
           let resetRequestsRaw = httpResponse.value(forHTTPHeaderField: "x-ratelimit-reset-requests"),
           let resetRequests = parseGroqDuration(resetRequestsRaw) {
            return (resetRequests, true)
        }
        // 2. Authoritative 429 wait (delta-seconds).
        if let retryAfterRaw = httpResponse.value(forHTTPHeaderField: "retry-after"),
           let retryAfter = parseGroqDuration(retryAfterRaw) {
            return (retryAfter, false)
        }
        // 3. Per-minute token reset, e.g. "7.66s".
        if let resetTokensRaw = httpResponse.value(forHTTPHeaderField: "x-ratelimit-reset-tokens"),
           let resetTokens = parseGroqDuration(resetTokensRaw) {
            return (resetTokens, false)
        }
        // 4. Short in-memory re-probe cooldown.
        return (defaultReprobeCooldownSeconds, false)
    }

    private nonisolated static func normalizedDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private nonisolated static func parseGroqDuration(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let bare = Double(trimmed) {
            guard bare.isFinite, bare >= 0 else { return nil }
            return bare
        }
        var total: TimeInterval = 0
        var numberBuffer = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character.isNumber || character == "." {
                numberBuffer.append(character)
                index = trimmed.index(after: index)
                continue
            }
            var unit = ""
            while index < trimmed.endIndex, trimmed[index].isLetter {
                unit.append(trimmed[index])
                index = trimmed.index(after: index)
            }
            guard let value = Double(numberBuffer), value.isFinite, value >= 0 else { return nil }
            switch unit {
            case "h":
                total += value * 3600
            case "m":
                total += value * 60
            case "s":
                total += value
            case "ms":
                total += value / 1000
            default:
                return nil
            }
            numberBuffer = ""
        }
        // Trailing number without a unit (e.g. "1h30") is malformed.
        guard numberBuffer.isEmpty else { return nil }
        guard total.isFinite, total >= 0 else { return nil }
        return total
    }
}
