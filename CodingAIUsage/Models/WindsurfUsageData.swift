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
            id: WindsurfUsageService.serviceID,
            displayName: WindsurfUsageService.displayName,
            shortLabel: WindsurfUsageService.shortLabel,
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
        // Fields 16-18 are required anchors; fields 14-15 default to 0 when absent
        // (protobuf omits zero-valued varints from the wire format).
        if
            let extraUsageMicros = varintField(16, in: fields),
            let dailyResetTimestamp = varintField(17, in: fields),
            let weeklyResetTimestamp = varintField(18, in: fields)
        {
            let dailyRemaining = varintField(14, in: fields) ?? 0
            let weeklyRemaining = varintField(15, in: fields) ?? 0

            guard dailyRemaining <= 100, weeklyRemaining <= 100 else {
                return nil
            }

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
