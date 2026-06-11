import Foundation

struct ClaudeUsageResponse: Decodable {
    let fiveHour: WindowData?
    let sevenDay: WindowData?
    let sevenDayOpus: WindowData?
    let sevenDaySonnet: WindowData?

    struct WindowData: Decodable {
        let utilization: Double    // 0-100 percentage USED
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Tolerate a present-but-null or missing utilization (e.g. an empty window object).
            utilization = (try? container.decodeIfPresent(Double.self, forKey: .utilization)) ?? 0
            resetsAt = (try? container.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    func toServiceUsage() -> ServiceUsage {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var windows: [UsageWindow] = []
        if let fiveHour {
            windows.append(
                UsageWindow(
                    id: "five_hour",
                    name: "5-Hour",
                    compactLabel: "5h",
                    utilization: fiveHour.utilization / 100.0,
                    resetTime: parseResetDate(fiveHour.resetsAt, using: formatter)
                )
            )
        }
        if let sevenDay {
            windows.append(
                UsageWindow(
                    id: "seven_day",
                    name: "Weekly",
                    compactLabel: "w",
                    utilization: sevenDay.utilization / 100.0,
                    resetTime: parseResetDate(sevenDay.resetsAt, using: formatter)
                )
            )
        }

        // Opus/Sonnet weekly windows are shown as footer text only, so they never affect the
        // compact menu-bar (primary/secondary windows) or the badge color (worstLevel).
        var footerLines: [String] = []
        if let sevenDayOpus {
            footerLines.append("Weekly (Opus): \(remainingPercent(sevenDayOpus))% remaining")
        }
        if let sevenDaySonnet {
            footerLines.append("Weekly (Sonnet): \(remainingPercent(sevenDaySonnet))% remaining")
        }

        return ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            footerLines: footerLines
        )
    }

    private func remainingPercent(_ window: WindowData) -> Int {
        max(0, Int((100.0 - window.utilization).rounded()))
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
