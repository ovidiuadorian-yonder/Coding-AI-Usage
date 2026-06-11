import Foundation

struct ClaudeCLIUsageParser {
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

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
        if let isoDate = parseISOResetDate(from: line) {
            return isoDate
        }
        return parseHumanResetDate(from: line)
    }

    private func parseISOResetDate(from line: String) -> Date? {
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

    // Parses "Resets 9:40pm (Europe/Madrid)" or "Resets Nov 13, 2pm (America/New_York)".
    // No date token => the next occurrence of that local time (today if still future, else tomorrow).
    private func parseHumanResetDate(from line: String) -> Date? {
        guard let clock = parseClockTime(in: line) else { return nil }

        let timeZone = firstCaptureGroup(#"\(([A-Za-z]+(?:[/_\-][A-Za-z_]+)+)\)"#, in: line)
            .flatMap { TimeZone(identifier: $0) } ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let nowDate = now()
        var components = calendar.dateComponents([.year, .month, .day], from: nowDate)
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = 0

        let monthDay = parseMonthDay(in: line)
        if let monthDay {
            components.month = monthDay.month
            components.day = monthDay.day
        }

        guard var candidate = calendar.date(from: components) else { return nil }

        if monthDay == nil {
            if candidate <= nowDate {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
        } else if candidate < nowDate {
            // A dated reset already past this year resolves to next year.
            components.year = (components.year ?? 0) + 1
            candidate = calendar.date(from: components) ?? candidate
        }

        return candidate
    }

    private func parseClockTime(in line: String) -> (hour: Int, minute: Int)? {
        let pattern = #"([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let hourRange = Range(match.range(at: 1), in: line),
              var hour = Int(line[hourRange]),
              let meridiemRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        var minute = 0
        if let minuteRange = Range(match.range(at: 2), in: line), let parsed = Int(line[minuteRange]) {
            minute = parsed
        }

        let meridiem = line[meridiemRange].lowercased()
        if meridiem == "pm" && hour != 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }

        return (hour, minute)
    }

    private func parseMonthDay(in line: String) -> (month: Int, day: Int)? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        let pattern = #"([A-Za-z]{3})[a-z]*\s+([0-9]{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: fullRange) {
            guard let monthRange = Range(match.range(at: 1), in: line),
                  let dayRange = Range(match.range(at: 2), in: line),
                  let monthIndex = months.firstIndex(of: line[monthRange].lowercased()),
                  let day = Int(line[dayRange]) else {
                continue
            }
            return (month: monthIndex + 1, day: day)
        }
        return nil
    }

    private func firstCaptureGroup(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }
}
