import XCTest
import CommonCrypto
import SQLite3
@testable import CodingAIUsage

final class WindsurfUsageTests: XCTestCase {
    func testCodexUsageResponseFallsBackToRelativeResetWhenAbsoluteResetIsMissing() {
        let response = CodexUsageResponse(
            rateLimit: .init(
                allowed: true,
                limitReached: false,
                primaryWindow: .init(
                    usedPercent: 25,
                    limitWindowSeconds: 18_000,
                    resetAfterSeconds: 90,
                    resetAt: nil
                ),
                secondaryWindow: nil
            ),
            rateLimitResetCredits: nil
        )

        let before = Date()
        let usage = response.toServiceUsage()
        let after = Date()

        let resetTime = try? XCTUnwrap(usage.primaryWindow?.resetTime)
        XCTAssertNotNil(resetTime)
        if let resetTime {
            XCTAssertGreaterThanOrEqual(resetTime, before.addingTimeInterval(89))
            XCTAssertLessThanOrEqual(resetTime, after.addingTimeInterval(91))
        }
    }

    func testUserStatusProtoParserExtractsQuotaAndBalanceFromNestedMessage() throws {
        let quotaMessage =
            protoMessageField(2, protoVarintField(1, 1_774_182_339)) +
            protoMessageField(3, protoVarintField(1, 1_776_860_739)) +
            protoVarintField(14, 99) +
            protoVarintField(15, 81) +
            protoVarintField(16, 1_371_438_587) +
            protoVarintField(17, 1_774_771_200) +
            protoVarintField(18, 1_774_771_200)
        let root = Data(protoMessageField(9, quotaMessage))

        let snapshot = try XCTUnwrap(WindsurfUserStatusProtoParser().parse(data: root))

        XCTAssertEqual(snapshot.dailyUsagePercent, 1)
        XCTAssertEqual(snapshot.weeklyUsagePercent, 19)
        XCTAssertEqual(snapshot.extraUsageBalance, "$1371.44")
        XCTAssertEqual(try XCTUnwrap(snapshot.dailyResetTime).timeIntervalSince1970, 1_774_771_200, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.weeklyResetTime).timeIntervalSince1970, 1_774_771_200, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.planEndDate).timeIntervalSince1970, 1_776_860_739, accuracy: 1)
    }

    func testUserStatusProtoParserDefaultsAbsentQuotaFieldsToZero() throws {
        // Protobuf omits zero-valued varints from the wire format.
        // When weekly remaining (field 15) is 0%, it's absent. The parser
        // must treat missing fields 14/15 as 0 rather than failing.
        let quotaMessage =
            protoVarintField(14, 43) +
            // field 15 intentionally absent (weekly remaining = 0)
            protoVarintField(16, 927_067_916) +
            protoVarintField(17, 1_776_240_000) +
            protoVarintField(18, 1_776_585_600)
        let root = Data(protoMessageField(9, quotaMessage))

        let snapshot = try XCTUnwrap(WindsurfUserStatusProtoParser().parse(data: root))

        XCTAssertEqual(snapshot.dailyUsagePercent, 57)
        XCTAssertEqual(snapshot.weeklyUsagePercent, 100)
        XCTAssertEqual(snapshot.extraUsageBalance, "$927.07")
    }

    func testCachedPlanInfoDecodesFlexCreditFields() throws {
        let json = """
        {
          "planName": "Teams",
          "startTimestamp": 1771661699000,
          "endTimestamp": 1774080899000,
          "usage": {
            "duration": 3,
            "messages": 50000,
            "flowActions": 120000,
            "flexCredits": 1000000,
            "usedMessages": 50000,
            "usedFlowActions": 0,
            "usedFlexCredits": 290025,
            "remainingMessages": 0,
            "remainingFlowActions": 120000,
            "remainingFlexCredits": 709975
          },
          "hasBillingWritePermissions": false,
          "gracePeriodStatus": 1,
          "billingStrategy": "quota",
          "quotaUsage": {
            "dailyRemainingPercent": 90,
            "weeklyRemainingPercent": 95,
            "overageBalanceMicros": 1052160000,
            "dailyResetAtUnix": 1775635200,
            "weeklyResetAtUnix": 1775980800
          },
          "hideDailyQuota": false,
          "hideWeeklyQuota": false
        }
        """

        let planInfo = try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: Data(json.utf8))

        XCTAssertEqual(planInfo.planName, "Teams")
        XCTAssertEqual(planInfo.usage.flexCredits, 1_000_000)
        XCTAssertEqual(planInfo.usage.remainingFlexCredits, 709_975)
        XCTAssertEqual(planInfo.quotaSnapshot?.dailyUsagePercent, 10)
        XCTAssertEqual(planInfo.quotaSnapshot?.weeklyUsagePercent, 5)
        XCTAssertEqual(planInfo.quotaSnapshot?.extraUsageBalance, "$1052.16")
    }

    func testAuthStatusDecodesAPIKey() throws {
        let json = """
        {
          "apiKey": "sk-ws-01-example",
          "allowedCommandModelConfigsProtoBinaryBase64": [],
          "userStatusProtoBinaryBase64": "abc"
        }
        """

        let authStatus = try JSONDecoder().decode(WindsurfAuthStatus.self, from: Data(json.utf8))

        XCTAssertEqual(authStatus.apiKey, "sk-ws-01-example")
    }

    func testWindsurfPageSnapshotBuildsServiceUsageWithCompactLabels() {
        let snapshot = WindsurfPageSnapshot(
            dailyUsagePercent: 1,
            weeklyUsagePercent: 19,
            dailyResetTime: Date(timeIntervalSince1970: 1_774_694_800),
            weeklyResetTime: Date(timeIntervalSince1970: 1_774_694_800),
            extraUsageBalance: "$1371.44",
            planEndDate: Date(timeIntervalSince1970: 1_777_148_800)
        )

        let usage = snapshot.toServiceUsage(lastUpdated: Date(timeIntervalSince1970: 1_774_600_000))

        // Part D: the user-facing label follows the rebrand while the persisted id does not,
        // so a cached snapshot written by an earlier build still loads.
        XCTAssertEqual(usage.shortLabel, "D")
        XCTAssertEqual(usage.displayName, "Devin")
        XCTAssertEqual(usage.id, "windsurf")
        XCTAssertEqual(usage.primaryWindow?.compactLabel, "d")
        XCTAssertEqual(usage.secondaryWindow?.compactLabel, "w")
        XCTAssertEqual(usage.primaryWindow?.remainingPercent, 99)
        XCTAssertEqual(usage.secondaryWindow?.remainingPercent, 81)
        XCTAssertTrue(usage.footerLines.contains("$1371.44"))
    }

    func testWindsurfPageSnapshotConvertsUsagePercentToRemainingPercent() {
        let snapshot = WindsurfPageSnapshot(
            dailyUsagePercent: 10,
            weeklyUsagePercent: 5,
            dailyResetTime: nil,
            weeklyResetTime: nil,
            extraUsageBalance: "$1052.16",
            planEndDate: nil
        )

        let usage = snapshot.toServiceUsage(lastUpdated: .distantPast)

        XCTAssertEqual(usage.primaryWindow?.remainingPercent, 90)
        XCTAssertEqual(usage.secondaryWindow?.remainingPercent, 95)
    }

    func testFetchUsageParsesResetTimesFromCachedJSONSnapshot() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dbURL = tempDirectory
            .appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        try createWindsurfStateDatabase(
            at: dbURL,
            entries: [
                (
                    "windsurfAuthStatus",
                    #"{"apiKey":"sk-ws-test","allowedCommandModelConfigsProtoBinaryBase64":[],"userStatusProtoBinaryBase64":""}"#
                ),
                (
                    "codeium.windsurf",
                    #"{"windsurf.state.cachedUsageSnapshot":{"dailyUsagePercent":12,"weeklyUsagePercent":34,"dailyResetTime":"2026-03-29T08:00:00Z","weeklyResetTime":"2026-03-30T09:15:00Z","extraUsageBalance":"$12.34"}}"#
                )
            ]
        )

        let service = WindsurfUsageService(
            stateDBLocator: { dbURL.path },
            now: { Date(timeIntervalSince1970: 1_774_771_200) } // 2026-03-29T08:00:00Z
        )
        let usage = try await service.fetchUsage()

        XCTAssertEqual(iso8601String(try XCTUnwrap(usage.primaryWindow?.resetTime)), "2026-03-29T08:00:00Z")
        XCTAssertEqual(iso8601String(try XCTUnwrap(usage.secondaryWindow?.resetTime)), "2026-03-30T09:15:00Z")
    }

    func testUnavailableWindsurfUsageDoesNotExposeStaleFooterLines() {
        let usage = ServiceUsage(
            id: WindsurfUsageService.serviceID,
            displayName: WindsurfUsageService.displayName,
            shortLabel: WindsurfUsageService.shortLabel,
            windows: [],
            lastUpdated: .distantPast,
            error: "Windsurf: daily/weekly quota unavailable",
            footerLines: []
        )

        XCTAssertEqual(usage.footerLines, [])
    }

}

private func protoVarintField(_ number: Int, _ value: UInt64) -> [UInt8] {
    encodeVarint(UInt64(number << 3)) + encodeVarint(value)
}

private func protoMessageField(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
    encodeVarint(UInt64((number << 3) | 2)) + encodeVarint(UInt64(payload.count)) + payload
}


private func iso8601Date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func iso8601String(_ value: Date) -> String {
    ISO8601DateFormatter().string(from: value)
}

// Shared across the Windsurf/Devin test files; deliberately not `private`.
func createWindsurfStateDatabase(at url: URL, entries: [(String, String)]) throws {
    let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw NSError(domain: "WindsurfUsageTests", code: 1)
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "WindsurfUsageTests", code: 2)
    }

    let statementText = "INSERT INTO ItemTable (key, value) VALUES (?, ?)"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, statementText, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "WindsurfUsageTests", code: 3)
    }
    defer { sqlite3_finalize(statement) }

    for (key, value) in entries {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, (value as NSString).utf8String, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "WindsurfUsageTests", code: 4)
        }
    }
}

private func encodeVarint(_ value: UInt64) -> [UInt8] {
    var remaining = value
    var bytes: [UInt8] = []

    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 {
            byte |= 0x80
        }
        bytes.append(byte)
    } while remaining != 0

    return bytes
}
