import XCTest
import CommonCrypto
import SQLite3
@testable import CodingAIUsage

final class WindsurfUsageTests: XCTestCase {

    func testManualRefreshPrefersLiveSnapshotOverCachedSnapshot() {
        let cached = WindsurfPageSnapshot(
            dailyUsagePercent: 1,
            weeklyUsagePercent: 19,
            dailyResetTime: nil,
            weeklyResetTime: nil,
            extraUsageBalance: "$1371.44",
            planEndDate: nil
        )
        let live = WindsurfPageSnapshot(
            dailyUsagePercent: 2,
            weeklyUsagePercent: 20,
            dailyResetTime: nil,
            weeklyResetTime: nil,
            extraUsageBalance: "$1371.44",
            planEndDate: nil
        )

        let selected = WindsurfSnapshotResolver.resolve(
            cached: cached,
            live: live,
            preferLive: true
        )

        XCTAssertEqual(selected?.dailyUsagePercent, 2)
        XCTAssertEqual(selected?.weeklyUsagePercent, 20)
    }

    func testAutomaticRefreshKeepsCachedSnapshotBeforeLiveSnapshot() {
        let cached = WindsurfPageSnapshot(
            dailyUsagePercent: 1,
            weeklyUsagePercent: 19,
            dailyResetTime: nil,
            weeklyResetTime: nil,
            extraUsageBalance: "$1371.44",
            planEndDate: nil
        )
        let live = WindsurfPageSnapshot(
            dailyUsagePercent: 2,
            weeklyUsagePercent: 20,
            dailyResetTime: nil,
            weeklyResetTime: nil,
            extraUsageBalance: "$1371.44",
            planEndDate: nil
        )

        let selected = WindsurfSnapshotResolver.resolve(
            cached: cached,
            live: live,
            preferLive: false
        )

        XCTAssertEqual(selected?.dailyUsagePercent, 1)
        XCTAssertEqual(selected?.weeklyUsagePercent, 19)
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
          "gracePeriodStatus": 1
        }
        """

        let planInfo = try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: Data(json.utf8))

        XCTAssertEqual(planInfo.planName, "Teams")
        XCTAssertEqual(planInfo.usage.flexCredits, 1_000_000)
        XCTAssertEqual(planInfo.usage.remainingFlexCredits, 709_975)
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

        XCTAssertEqual(usage.shortLabel, "W")
        XCTAssertEqual(usage.primaryWindow?.compactLabel, "d")
        XCTAssertEqual(usage.secondaryWindow?.compactLabel, "w")
        XCTAssertEqual(usage.primaryWindow?.remainingPercent, 99)
        XCTAssertEqual(usage.secondaryWindow?.remainingPercent, 81)
        XCTAssertTrue(usage.footerLines.contains("$1371.44"))
    }

    func testUsagePageParserExtractsQuotaAndBalanceFromText() throws {
        let pageText = """
        Plan
        Quota resets daily/weekly
        Plan ends in 25 days (Mar 22, - Apr 22, 2026)
        Daily quota usage:
        1%
        Resets Mar 29, 11:00 AM GMT+3
        Weekly quota usage:
        19%
        Resets Mar 29, 11:00 AM GMT+3
        Extra usage balance:
        $1371.44
        """

        let parser = WindsurfUsagePageParser(now: Date(timeIntervalSince1970: 1_774_600_000))
        let snapshot = try parser.parse(pageText: pageText)

        XCTAssertEqual(snapshot.dailyUsagePercent, 1)
        XCTAssertEqual(snapshot.weeklyUsagePercent, 19)
        XCTAssertEqual(snapshot.extraUsageBalance, "$1371.44")
        XCTAssertNotNil(snapshot.dailyResetTime)
        XCTAssertNotNil(snapshot.weeklyResetTime)
        XCTAssertNotNil(snapshot.planEndDate)
    }

    func testUsagePageParserRollsResetIntoNextYearWhenNeeded() throws {
        let pageText = """
        Daily quota usage:
        1%
        Resets Jan 1, 1:00 AM GMT+3
        Weekly quota usage:
        19%
        Resets Jan 1, 1:00 AM GMT+3
        Extra usage balance:
        $1371.44
        """

        let now = iso8601Date("2025-12-31T22:00:00Z")
        let parser = WindsurfUsagePageParser(now: now)
        let snapshot = try parser.parse(pageText: pageText)

        XCTAssertEqual(
            iso8601String(try XCTUnwrap(snapshot.dailyResetTime)),
            "2025-12-31T22:00:00Z"
        )
        XCTAssertEqual(
            iso8601String(try XCTUnwrap(snapshot.weeklyResetTime)),
            "2025-12-31T22:00:00Z"
        )
    }

    func testUsagePageParserKeepsWeeklyResetWhenExtraBalanceSectionIsMissing() throws {
        let pageText = """
        Daily quota usage:
        1%
        Resets Mar 29, 11:00 AM GMT+3
        Weekly quota usage:
        19%
        Resets Mar 30, 9:30 AM GMT+3
        """

        let parser = WindsurfUsagePageParser(now: Date(timeIntervalSince1970: 1_774_600_000))
        let snapshot = try parser.parse(pageText: pageText)

        XCTAssertEqual(
            iso8601String(try XCTUnwrap(snapshot.weeklyResetTime)),
            "2026-03-30T06:30:00Z"
        )
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

        let usage = try await WindsurfUsageService(stateDBPath: dbURL.path).fetchUsage()

        XCTAssertEqual(iso8601String(try XCTUnwrap(usage.primaryWindow?.resetTime)), "2026-03-29T08:00:00Z")
        XCTAssertEqual(iso8601String(try XCTUnwrap(usage.secondaryWindow?.resetTime)), "2026-03-30T09:15:00Z")
    }

    func testUnavailableWindsurfUsageDoesNotExposeStaleFooterLines() {
        let usage = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [],
            lastUpdated: .distantPast,
            error: "Windsurf: daily/weekly quota unavailable",
            footerLines: []
        )

        XCTAssertEqual(usage.footerLines, [])
    }

    func testChromiumCookieCryptoDecryptsVersion24CookiePayload() throws {
        let hostKey = ".windsurf.com"
        let plaintextValue = "session-token"
        let encryptedValue = try chromiumEncryptedCookieValue(
            hostKey: hostKey,
            value: plaintextValue,
            safeStorageKey: "test-safe-storage-key"
        )

        let decrypted = try XCTUnwrap(
            WindsurfChromiumCookieCrypto.decryptCookieValue(
                encryptedValue,
                hostKey: hostKey,
                safeStorageKey: "test-safe-storage-key"
            )
        )

        XCTAssertEqual(decrypted, plaintextValue)
    }
}

private func protoVarintField(_ number: Int, _ value: UInt64) -> [UInt8] {
    encodeVarint(UInt64(number << 3)) + encodeVarint(value)
}

private func protoMessageField(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
    encodeVarint(UInt64((number << 3) | 2)) + encodeVarint(UInt64(payload.count)) + payload
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

private func iso8601Date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func iso8601String(_ value: Date) -> String {
    ISO8601DateFormatter().string(from: value)
}

private func chromiumEncryptedCookieValue(hostKey: String, value: String, safeStorageKey: String) throws -> Data {
    let digest = sha256(Data(hostKey.utf8))
    let plaintext = digest + Data(value.utf8)
    let key = try chromiumCookieKey(from: safeStorageKey)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    let encrypted = try aes128CBCEncrypt(plaintext, key: key, iv: iv)
    return Data("v10".utf8) + encrypted
}

private func chromiumCookieKey(from safeStorageKey: String) throws -> Data {
    let password = Data(safeStorageKey.utf8)
    let salt = Data("saltysalt".utf8)
    var derived = Data(count: kCCKeySizeAES128)
    let derivedCount = derived.count

    let status = derived.withUnsafeMutableBytes { derivedBytes in
        password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                    derivedCount
                )
            }
        }
    }

    guard status == kCCSuccess else {
        throw NSError(domain: "WindsurfUsageTests", code: Int(status))
    }

    return derived
}

private func aes128CBCEncrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
    var cryptData = Data(count: plaintext.count + kCCBlockSizeAES128)
    var outLength = 0
    let cryptDataCount = cryptData.count

    let status = cryptData.withUnsafeMutableBytes { cryptBytes in
        plaintext.withUnsafeBytes { plaintextBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        plaintextBytes.baseAddress,
                        plaintext.count,
                        cryptBytes.baseAddress,
                        cryptDataCount,
                        &outLength
                    )
                }
            }
        }
    }

    guard status == kCCSuccess else {
        throw NSError(domain: "WindsurfUsageTests", code: Int(status))
    }

    cryptData.removeSubrange(outLength..<cryptData.count)
    return cryptData
}

private func sha256(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { bytes in
        _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
    }
    return Data(digest)
}

private func createWindsurfStateDatabase(at url: URL, entries: [(String, String)]) throws {
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
