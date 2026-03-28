import Foundation

struct ClaudeUsageResponse: Codable {
    let fiveHour: WindowData
    let sevenDay: WindowData

    struct WindowData: Codable {
        let utilization: Double    // 0-100 percentage USED
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    func toServiceUsage() -> ServiceUsage {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fiveHourReset = fiveHour.resetsAt.flatMap { formatter.date(from: $0) }
        let sevenDayReset = sevenDay.resetsAt.flatMap { formatter.date(from: $0) }

        return ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [
                UsageWindow(
                    id: "five_hour",
                    name: "5-Hour",
                    utilization: fiveHour.utilization / 100.0,
                    resetTime: fiveHourReset
                ),
                UsageWindow(
                    id: "seven_day",
                    name: "Weekly",
                    utilization: sevenDay.utilization / 100.0,
                    resetTime: sevenDayReset
                )
            ],
            lastUpdated: Date(),
            error: nil
        )
    }
}
