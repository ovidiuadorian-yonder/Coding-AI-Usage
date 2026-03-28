import Foundation

struct ClaudeUsageResponse: Codable {
    let fiveHour: WindowData
    let sevenDay: WindowData

    struct WindowData: Codable {
        let utilization: Double
        let resetAt: String

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetAt = "reset_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    func toServiceUsage() -> ServiceUsage {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fiveHourReset = formatter.date(from: fiveHour.resetAt)
        let sevenDayReset = formatter.date(from: sevenDay.resetAt)

        return ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [
                UsageWindow(
                    id: "five_hour",
                    name: "5-Hour",
                    utilization: fiveHour.utilization,
                    resetTime: fiveHourReset
                ),
                UsageWindow(
                    id: "seven_day",
                    name: "Weekly",
                    utilization: sevenDay.utilization,
                    resetTime: sevenDayReset
                )
            ],
            lastUpdated: Date(),
            error: nil
        )
    }
}
