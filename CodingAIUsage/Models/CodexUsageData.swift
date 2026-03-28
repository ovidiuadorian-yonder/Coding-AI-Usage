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

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
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

    func toServiceUsage() -> ServiceUsage {
        var windows: [UsageWindow] = []

        if let primary = rateLimit?.primaryWindow {
            let utilization = Double(primary.usedPercent) / 100.0
            let resetTime = primary.resetAt.map { Date(timeIntervalSince1970: Double($0)) }
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
            let resetTime = secondary.resetAt.map { Date(timeIntervalSince1970: Double($0)) }
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
            footerLines: []
        )
    }
}
