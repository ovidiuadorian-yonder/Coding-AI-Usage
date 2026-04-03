import Foundation

struct ClaudeCLIUsageParser {
    func parse(_ output: String) throws -> ServiceUsage {
        let clean = normalized(output)
        if let error = detectError(in: clean) {
            throw error
        }

        guard let fiveHourRemaining = extractPercent(labelSubstring: "Current session", text: clean) else {
            throw UsageError.networkError("Claude Code: unexpected CLI usage output")
        }

        let weeklyRemaining = extractPercent(labelSubstring: "Current week", text: clean)
        let fiveHourReset = extractResetDate(labelSubstring: "Current session", text: clean)
        let weeklyReset = extractResetDate(labelSubstring: "Current week", text: clean)

        var windows = [
            UsageWindow(
                id: "five_hour",
                name: "5-Hour",
                compactLabel: "5h",
                utilization: Double(100 - fiveHourRemaining) / 100.0,
                resetTime: fiveHourReset
            )
        ]

        if let weeklyRemaining {
            windows.append(
                UsageWindow(
                    id: "seven_day",
                    name: "Weekly",
                    compactLabel: "w",
                    utilization: Double(100 - weeklyRemaining) / 100.0,
                    resetTime: weeklyReset
                )
            )
        }

        return ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: windows,
            lastUpdated: Date(),
            error: nil
        )
    }

    private func normalized(_ output: String) -> String {
        let ansiPattern = #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#
        let withoutANSI = output.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )
        return withoutANSI.replacingOccurrences(of: "\r", with: "\n")
    }

    private func detectError(in text: String) -> UsageError? {
        let lowercased = text.lowercased()

        if lowercased.contains("ready to code here") || lowercased.contains("press enter to continue") {
            return .networkError("Claude Code: CLI needs folder trust confirmation")
        }

        if lowercased.contains("claude login")
            || lowercased.contains("authentication required")
            || lowercased.contains("not logged in")
        {
            return .noCredentials("Claude Code: not logged in")
        }

        if lowercased.contains("session expired") {
            return .authExpired("Claude Code: session expired - please re-login in Claude Code")
        }

        return nil
    }

    private func extractPercent(labelSubstring: String, text: String) -> Int? {
        let lines = text.components(separatedBy: .newlines)
        let label = labelSubstring.lowercased()

        for (index, line) in lines.enumerated() where line.lowercased().contains(label) {
            for candidate in lines.dropFirst(index).prefix(12) {
                if let percent = percentFromLine(candidate) {
                    return percent
                }
            }
        }

        return nil
    }

    private func percentFromLine(_ line: String) -> Int? {
        let pattern = #"([0-9]{1,3})\s*%\s*(used|left)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: line),
              let kindRange = Range(match.range(at: 2), in: line),
              let value = Int(line[valueRange]) else {
            return nil
        }

        let kind = line[kindRange].lowercased()
        return kind.contains("used") ? max(0, 100 - value) : value
    }

    private func extractResetDate(labelSubstring: String, text: String) -> Date? {
        let lines = text.components(separatedBy: .newlines)
        let label = labelSubstring.lowercased()

        for (index, line) in lines.enumerated() where line.lowercased().contains(label) {
            for candidate in lines.dropFirst(index).prefix(12) {
                guard candidate.lowercased().contains("reset") else { continue }
                if let date = parseResetDate(from: candidate) {
                    return date
                }
            }
        }

        return nil
    }

    private func parseResetDate(from line: String) -> Date? {
        let pattern = #"(20[0-9]{2}-[0-9]{2}-[0-9]{2}T[^ ]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }

        let dateString = String(line[range])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}
