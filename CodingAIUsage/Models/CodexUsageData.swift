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

// Codex usage response structure (best-effort, may vary)
struct CodexUsageResponse: Codable {
    let fiveHour: CodexWindowData?
    let sevenDay: CodexWindowData?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct CodexWindowData: Codable {
        let utilization: Double?
        let resetAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetAt = "reset_at"
        }
    }

    func toServiceUsage() -> ServiceUsage {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var windows: [UsageWindow] = []

        if let fh = fiveHour, let util = fh.utilization {
            windows.append(UsageWindow(
                id: "five_hour",
                name: "5-Hour",
                utilization: util,
                resetTime: fh.resetAt.flatMap { formatter.date(from: $0) }
            ))
        }

        if let sd = sevenDay, let util = sd.utilization {
            windows.append(UsageWindow(
                id: "seven_day",
                name: "Weekly",
                utilization: util,
                resetTime: sd.resetAt.flatMap { formatter.date(from: $0) }
            ))
        }

        return ServiceUsage(
            id: "codex",
            displayName: "Codex",
            shortLabel: "CX",
            windows: windows,
            lastUpdated: Date(),
            error: nil
        )
    }
}
