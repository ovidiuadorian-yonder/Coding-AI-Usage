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

        let fiveHourReset = parseResetDate(fiveHour.resetsAt, using: formatter)
        let sevenDayReset = parseResetDate(sevenDay.resetsAt, using: formatter)

        return ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [
                UsageWindow(
                    id: "five_hour",
                    name: "5-Hour",
                    compactLabel: "5h",
                    utilization: fiveHour.utilization / 100.0,
                    resetTime: fiveHourReset
                ),
                UsageWindow(
                    id: "seven_day",
                    name: "Weekly",
                    compactLabel: "w",
                    utilization: sevenDay.utilization / 100.0,
                    resetTime: sevenDayReset
                )
            ],
            lastUpdated: Date(),
            error: nil,
            footerLines: []
        )
    }

    private func parseResetDate(_ rawValue: String?, using formatter: ISO8601DateFormatter) -> Date? {
        guard let rawValue else { return nil }
        if let date = formatter.date(from: rawValue) {
            return date
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: rawValue)
    }
}
