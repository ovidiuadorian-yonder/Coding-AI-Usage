import Foundation

struct CodexAuthFile: Codable {
    let authMode: String?
    let tokens: CodexTokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }
}

struct CodexTokens: Codable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

// Matches the actual response from https://chatgpt.com/backend-api/wham/usage
struct CodexUsageResponse: Codable {
    let rateLimit: CodexRateLimit?
    let rateLimitResetCredits: CodexResetCreditsCount?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }

    struct CodexResetCreditsCount: Codable {
        let availableCount: Int?

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
        }
    }

    struct CodexRateLimit: Codable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: CodexWindowData?
        let secondaryWindow: CodexWindowData?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct CodexWindowData: Codable {
        let usedPercent: Int
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Int? // Unix timestamp

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    func toServiceUsage(
        now: Date = Date(),
        resetCredits: CodexResetCreditsResponse? = nil
    ) -> ServiceUsage {
        var windows: [UsageWindow] = []

        if let primary = rateLimit?.primaryWindow {
            let utilization = Double(primary.usedPercent) / 100.0
            let resetTime =
                primary.resetAt.map { Date(timeIntervalSince1970: Double($0)) } ??
                primary.resetAfterSeconds.map { now.addingTimeInterval(Double($0)) }
            windows.append(UsageWindow(
                id: "five_hour",
                name: "5-Hour",
                compactLabel: "5h",
                utilization: utilization,
                resetTime: resetTime
            ))
        }

        if let secondary = rateLimit?.secondaryWindow {
            let utilization = Double(secondary.usedPercent) / 100.0
            let resetTime =
                secondary.resetAt.map { Date(timeIntervalSince1970: Double($0)) } ??
                secondary.resetAfterSeconds.map { now.addingTimeInterval(Double($0)) }
            windows.append(UsageWindow(
                id: "seven_day",
                name: "Weekly",
                compactLabel: "w",
                utilization: utilization,
                resetTime: resetTime
            ))
        }

        return ServiceUsage(
            id: "codex",
            displayName: "Codex",
            shortLabel: "CX",
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            footerLines: Self.resetCreditsFooterLines(
                resetCredits: resetCredits,
                fallbackAvailableCount: rateLimitResetCredits?.availableCount
            )
        )
    }

    /// Builds a single footer line of the form
    /// "Rate limit resets: <N> available (first expires <date>)".
    /// The detail endpoint provides per-credit expirations; when it is
    /// unavailable, fall back to the bare count from the usage response.
    static func resetCreditsFooterLines(
        resetCredits: CodexResetCreditsResponse?,
        fallbackAvailableCount: Int?
    ) -> [String] {
        if let resetCredits {
            let available = resetCredits.availableCredits
            guard !available.isEmpty else {
                return ["Rate limit resets: none available"]
            }

            var line = "Rate limit resets: \(available.count) available"
            if let firstExpiration = available.compactMap(\.expirationDate).min() {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                line += " (first expires \(formatter.string(from: firstExpiration)))"
            }
            return [line]
        }

        if let fallbackAvailableCount {
            return fallbackAvailableCount > 0
                ? ["Rate limit resets: \(fallbackAvailableCount) available"]
                : ["Rate limit resets: none available"]
        }

        return []
    }
}

// Matches the response from https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
struct CodexResetCreditsResponse: Codable {
    let credits: [CodexResetCredit]

    struct CodexResetCredit: Codable {
        let status: String?
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case status
            case expiresAt = "expires_at"
        }

        var expirationDate: Date? {
            expiresAt.flatMap(CodexResetCreditsResponse.parseTimestamp)
        }
    }

    var availableCredits: [CodexResetCredit] {
        credits.filter { $0.status == "available" }
    }

    /// The API sends timestamps with microsecond fractions (a fractional
    /// seconds component like ".780413"), which ISO8601DateFormatter rejects;
    /// sub-second precision is irrelevant here, so strip the fraction before
    /// parsing.
    static func parseTimestamp(_ raw: String) -> Date? {
        let normalized = raw.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        return ISO8601DateFormatter().date(from: normalized)
    }
}
