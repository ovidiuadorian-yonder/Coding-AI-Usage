import Foundation

struct WindsurfCachedPlanInfo: Codable {
    let planName: String
    let startTimestamp: Int64
    let endTimestamp: Int64
    let usage: Usage
    let hasBillingWritePermissions: Bool?
    let gracePeriodStatus: Int?
    let billingStrategy: String?
    let quotaUsage: QuotaUsage?
    let hideDailyQuota: Bool?
    let hideWeeklyQuota: Bool?

    struct Usage: Codable {
        let duration: Int?
        let messages: Int?
        let flowActions: Int?
        let flexCredits: Int?
        let usedMessages: Int?
        let usedFlowActions: Int?
        let usedFlexCredits: Int?
        let remainingMessages: Int?
        let remainingFlowActions: Int?
        let remainingFlexCredits: Int?
    }

    struct QuotaUsage: Codable {
        let dailyRemainingPercent: Int
        let weeklyRemainingPercent: Int
        let overageBalanceMicros: Int64?
        let dailyResetAtUnix: Int64?
        let weeklyResetAtUnix: Int64?
    }

    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startTimestamp) / 1000.0)
    }

    var endDate: Date {
        Date(timeIntervalSince1970: TimeInterval(endTimestamp) / 1000.0)
    }

    var quotaSnapshot: WindsurfPageSnapshot? {
        guard let quotaUsage, billingStrategy == "quota" else {
            return nil
        }

        return WindsurfPageSnapshot(
            dailyUsagePercent: max(0, min(100, 100 - quotaUsage.dailyRemainingPercent)),
            weeklyUsagePercent: max(0, min(100, 100 - quotaUsage.weeklyRemainingPercent)),
            dailyResetTime: quotaUsage.dailyResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            weeklyResetTime: quotaUsage.weeklyResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            extraUsageBalance: quotaUsage.overageBalanceMicros.map { Self.formatCurrency(micros: $0) },
            planEndDate: endDate
        )
    }

    private static func formatCurrency(micros: Int64) -> String {
        let dollars = Double(micros) / 1_000_000.0
        return String(format: "$%.2f", dollars)
    }
}

struct WindsurfAuthStatus: Codable {
    let apiKey: String
    let allowedCommandModelConfigsProtoBinaryBase64: [String]
    let userStatusProtoBinaryBase64: String
}

struct WindsurfPageSnapshot: Equatable {
    let dailyUsagePercent: Int
    let weeklyUsagePercent: Int
    let dailyResetTime: Date?
    let weeklyResetTime: Date?
    let extraUsageBalance: String?
    let planEndDate: Date?

    var footerLines: [String] {
        var footerLines: [String] = []

        if let planEndDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            footerLines.append("Plan ends \(formatter.string(from: planEndDate))")
        }

        if let extraUsageBalance {
            footerLines.append(extraUsageBalance)
        }

        return footerLines
    }

    func toServiceUsage(lastUpdated: Date) -> ServiceUsage {
        return ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [
                UsageWindow(
                    id: "daily",
                    name: "Daily",
                    compactLabel: "d",
                    utilization: Double(dailyUsagePercent) / 100.0,
                    resetTime: dailyResetTime
                ),
                UsageWindow(
                    id: "weekly",
                    name: "Weekly",
                    compactLabel: "w",
                    utilization: Double(weeklyUsagePercent) / 100.0,
                    resetTime: weeklyResetTime
                )
            ],
            lastUpdated: lastUpdated,
            error: nil,
            footerLines: footerLines
        )
    }
}

struct WindsurfUsagePageParser {
    let now: Date

    func parse(pageText: String) throws -> WindsurfPageSnapshot {
        let dailyUsagePercent = try extractPercent(label: "Daily quota usage", from: pageText)
        let weeklyUsagePercent = try extractPercent(label: "Weekly quota usage", from: pageText)
        let extraUsageBalance = extractBalance(from: pageText)
        let dailyResetTime = extractResetTime(sectionLabel: "Daily quota usage", nextLabel: "Weekly quota usage", from: pageText)
        let weeklyResetTime = extractResetTime(sectionLabel: "Weekly quota usage", nextLabel: nil, from: pageText)
        let planEndDate = extractPlanEndDate(from: pageText)

        return WindsurfPageSnapshot(
            dailyUsagePercent: dailyUsagePercent,
            weeklyUsagePercent: weeklyUsagePercent,
            dailyResetTime: dailyResetTime,
            weeklyResetTime: weeklyResetTime,
            extraUsageBalance: extraUsageBalance,
            planEndDate: planEndDate
        )
    }

    private func extractPercent(label: String, from text: String) throws -> Int {
        let pattern = "\(NSRegularExpression.escapedPattern(for: label))\\s*:?\\s*(\\d{1,3})%"
        guard let value = firstMatch(pattern: pattern, in: text, group: 1), let percent = Int(value) else {
            throw UsageError.invalidResponse
        }
        return percent
    }

    private func extractBalance(from text: String) -> String? {
        firstMatch(
            pattern: "Extra usage balance\\s*:?\\s*(\\$[0-9,]+(?:\\.[0-9]{2})?)",
            in: text,
            group: 1
        )
    }

    private func extractResetTime(sectionLabel: String, nextLabel: String?, from text: String) -> Date? {
        let pattern: String
        if let nextLabel {
            pattern = "\(NSRegularExpression.escapedPattern(for: sectionLabel))(?s)(.*?)\(NSRegularExpression.escapedPattern(for: nextLabel))"
        } else {
            pattern = "\(NSRegularExpression.escapedPattern(for: sectionLabel))(?s)(.*)"
        }
        guard let section = firstMatch(pattern: pattern, in: text, group: 1) else {
            return nil
        }
        guard let rawReset = firstMatch(pattern: "Resets\\s+([A-Za-z]{3}\\s+\\d{1,2},\\s+\\d{1,2}:\\d{2}\\s+[AP]M\\s+GMT[+-]\\d{1,2})", in: section, group: 1) else {
            return nil
        }
        return parseResetDate(rawReset)
    }

    private func extractPlanEndDate(from text: String) -> Date? {
        guard let rawDate = firstMatch(pattern: "Plan ends in .*?([A-Za-z]{3}\\s+\\d{1,2},\\s+\\d{4})", in: text, group: 1) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.date(from: rawDate)
    }

    private func parseResetDate(_ rawValue: String) -> Date? {
        let pattern = "([A-Za-z]{3})\\s+(\\d{1,2}),\\s+(\\d{1,2}):(\\d{2})\\s+([AP]M)\\s+GMT([+-]\\d{1,2})"
        guard
            let monthString = firstMatch(pattern: pattern, in: rawValue, group: 1),
            let dayString = firstMatch(pattern: pattern, in: rawValue, group: 2),
            let hourString = firstMatch(pattern: pattern, in: rawValue, group: 3),
            let minuteString = firstMatch(pattern: pattern, in: rawValue, group: 4),
            let meridiem = firstMatch(pattern: pattern, in: rawValue, group: 5),
            let offsetString = firstMatch(pattern: pattern, in: rawValue, group: 6),
            let day = Int(dayString),
            let hour = Int(hourString),
            let minute = Int(minuteString),
            let offsetHours = Int(offsetString)
        else {
            return nil
        }

        let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6, "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
        guard let month = months[monthString] else {
            return nil
        }

        var components = DateComponents()
        let calendar = Calendar(identifier: .gregorian)
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)
        components.year = calendar.component(.year, from: now)
        components.month = month
        components.day = day
        components.minute = minute
        components.hour = normalizedHour(hour, meridiem: meridiem)

        guard var resetDate = components.date else {
            return nil
        }

        if resetDate < now {
            components.year = (components.year ?? calendar.component(.year, from: now)) + 1
            guard let nextYearDate = components.date else {
                return nil
            }
            resetDate = nextYearDate
        }

        return resetDate
    }

    private func normalizedHour(_ hour: Int, meridiem: String) -> Int {
        switch (hour, meridiem) {
        case (12, "AM"): return 0
        case (12, "PM"): return 12
        case (_, "PM"): return hour + 12
        default: return hour
        }
    }

    private func firstMatch(pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            let captureRange = Range(match.range(at: group), in: text)
        else {
            return nil
        }

        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WindsurfUserStatusProtoParser {
    func parse(base64Encoded value: String) -> WindsurfPageSnapshot? {
        guard let data = Data(base64Encoded: value) else {
            return nil
        }
        return parse(data: data)
    }

    func parse(data: Data) -> WindsurfPageSnapshot? {
        guard let fields = try? WindsurfProtobufParser.parseFields(from: data) else {
            return nil
        }
        return findSnapshot(in: fields)
    }

    private func findSnapshot(in fields: [WindsurfProtobufField]) -> WindsurfPageSnapshot? {
        if
            let dailyRemaining = varintField(14, in: fields),
            let weeklyRemaining = varintField(15, in: fields),
            let extraUsageMicros = varintField(16, in: fields),
            let dailyResetTimestamp = varintField(17, in: fields),
            let weeklyResetTimestamp = varintField(18, in: fields)
        {
            return WindsurfPageSnapshot(
                dailyUsagePercent: max(0, min(100, 100 - Int(dailyRemaining))),
                weeklyUsagePercent: max(0, min(100, 100 - Int(weeklyRemaining))),
                dailyResetTime: Date(timeIntervalSince1970: TimeInterval(dailyResetTimestamp)),
                weeklyResetTime: Date(timeIntervalSince1970: TimeInterval(weeklyResetTimestamp)),
                extraUsageBalance: formatCurrency(micros: extraUsageMicros),
                planEndDate: timestampField(3, in: fields)
            )
        }

        for field in fields {
            guard case .lengthDelimited(let nestedData) = field.value else {
                continue
            }
            guard let nestedFields = try? WindsurfProtobufParser.parseFields(from: nestedData) else {
                continue
            }
            if let snapshot = findSnapshot(in: nestedFields) {
                return snapshot
            }
        }

        return nil
    }

    private func varintField(_ fieldNumber: Int, in fields: [WindsurfProtobufField]) -> UInt64? {
        for field in fields where field.number == fieldNumber {
            if case .varint(let value) = field.value {
                return value
            }
        }
        return nil
    }

    private func timestampField(_ fieldNumber: Int, in fields: [WindsurfProtobufField]) -> Date? {
        for field in fields where field.number == fieldNumber {
            guard case .lengthDelimited(let nestedData) = field.value else {
                continue
            }
            guard let nestedFields = try? WindsurfProtobufParser.parseFields(from: nestedData) else {
                continue
            }
            guard let timestamp = varintField(1, in: nestedFields) else {
                continue
            }
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        return nil
    }

    private func formatCurrency(micros: UInt64) -> String {
        let dollars = Double(micros) / 1_000_000.0
        return String(format: "$%.2f", dollars)
    }
}

enum WindsurfSnapshotResolver {
    static func resolve(
        cached: WindsurfPageSnapshot?,
        live: WindsurfPageSnapshot?,
        preferLive: Bool
    ) -> WindsurfPageSnapshot? {
        if preferLive {
            return live ?? cached
        }
        return live ?? cached
    }
}

enum WindsurfQuotaDiagnostics {
    static func shouldHideSuspiciousLocalQuota(
        snapshot: WindsurfPageSnapshot,
        hasLikelyLiveAuthCookies: Bool
    ) -> Bool {
        guard !hasLikelyLiveAuthCookies else {
            return false
        }

        // Windsurf's local persisted quota state can report 100/100 while the live app UI shows usage.
        // If we have no viable authenticated web session for a live refresh, prefer surfacing uncertainty
        // instead of showing a confidently wrong "100% remaining / Healthy" state.
        return snapshot.dailyUsagePercent == 0 && snapshot.weeklyUsagePercent == 0
    }
}

private struct WindsurfProtobufField {
    let number: Int
    let value: Value

    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case lengthDelimited(Data)
        case fixed32(UInt32)
    }
}

private struct WindsurfProtobufParser {
    let data: Data
    private var cursor: Data.Index

    init(data: Data) {
        self.data = data
        self.cursor = data.startIndex
    }

    static func parseFields(from data: Data) throws -> [WindsurfProtobufField] {
        var parser = WindsurfProtobufParser(data: data)
        return try parser.parseFields()
    }

    mutating func parseFields() throws -> [WindsurfProtobufField] {
        var fields: [WindsurfProtobufField] = []

        while cursor < data.endIndex {
            let key = try readVarint()
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x07)

            let value: WindsurfProtobufField.Value
            switch wireType {
            case 0:
                value = .varint(try readVarint())
            case 1:
                value = .fixed64(try readFixed64())
            case 2:
                let length = Int(try readVarint())
                value = .lengthDelimited(try readData(length: length))
            case 5:
                value = .fixed32(try readFixed32())
            default:
                throw UsageError.invalidResponse
            }

            fields.append(WindsurfProtobufField(number: fieldNumber, value: value))
        }

        return fields
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while cursor < data.endIndex {
            let byte = data[cursor]
            cursor = data.index(after: cursor)

            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }

            shift += 7
            if shift > 63 {
                break
            }
        }

        throw UsageError.invalidResponse
    }

    private mutating func readFixed32() throws -> UInt32 {
        let bytes = try readData(length: 4)
        return bytes.enumerated().reduce(0) { partialResult, entry in
            partialResult | (UInt32(entry.element) << (UInt32(entry.offset) * 8))
        }
    }

    private mutating func readFixed64() throws -> UInt64 {
        let bytes = try readData(length: 8)
        return bytes.enumerated().reduce(0) { partialResult, entry in
            partialResult | (UInt64(entry.element) << (UInt64(entry.offset) * 8))
        }
    }

    private mutating func readData(length: Int) throws -> Data {
        guard length >= 0 else {
            throw UsageError.invalidResponse
        }

        let end = cursor + length
        guard end <= data.endIndex else {
            throw UsageError.invalidResponse
        }

        let chunk = data[cursor..<end]
        cursor = end
        return Data(chunk)
    }
}
