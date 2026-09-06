import SQLite3
import XCTest
@testable import CodingAIUsage

/// Covers the Windsurf → Devin migration:
/// `docs/superpowers/specs/2026-09-06-windsurf-devin-migration-design.md`.
final class WindsurfDevinMigrationTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    private func makeStateDB(_ client: String, modified: Date) throws -> URL {
        let url = home
            .appendingPathComponent("Library/Application Support/\(client)/User/globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func locate() -> String? {
        WindsurfUsageService.defaultStateDBLocator(homeDirectory: home.path)
    }

    // MARK: - Part A: client discovery

    func testPrefersDevinWhenItIsNewer() throws {
        try makeStateDB("Windsurf", modified: Date(timeIntervalSince1970: 1_000_000))
        try makeStateDB("Devin", modified: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(locate()?.contains("/Devin/"), true, locate() ?? "nil")
    }

    func testPrefersWindsurfWhenItIsNewer() throws {
        // A user who has not migrated, or who rolled back, must keep working.
        try makeStateDB("Devin", modified: Date(timeIntervalSince1970: 1_000_000))
        try makeStateDB("Windsurf", modified: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(locate()?.contains("/Windsurf/"), true, locate() ?? "nil")
    }

    func testResolvesDevinWhenOnlyDevinExists() throws {
        try makeStateDB("Devin", modified: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(locate()?.contains("/Devin/"), true, locate() ?? "nil")
    }

    func testResolvesWindsurfWhenOnlyWindsurfExists() throws {
        try makeStateDB("Windsurf", modified: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(locate()?.contains("/Windsurf/"), true, locate() ?? "nil")
    }

    func testResolvesNothingWhenNeitherExists() {
        XCTAssertNil(locate())
    }

    func testTieResolvesToDevin() throws {
        let same = Date(timeIntervalSince1970: 1_500_000)
        try makeStateDB("Windsurf", modified: same)
        try makeStateDB("Devin", modified: same)
        XCTAssertEqual(locate()?.contains("/Devin/"), true, locate() ?? "nil")
    }

    func testNoCredentialsWhenNoClientIsInstalled() async {
        let service = WindsurfUsageService(stateDBLocator: { nil })
        do {
            _ = try await service.fetchUsage()
            XCTFail("expected .noCredentials when no state database is present")
        } catch let error as UsageError {
            guard case .noCredentials = error else {
                return XCTFail("expected .noCredentials, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Part B: freshness gate

    /// 2026-09-06T21:06:00Z — the instant the live data below was captured.
    private static let now = Date(timeIntervalSince1970: 1_788_735_960)

    private func usage(planEndUnixMillis: Int64?, dailyReset: Int64, weeklyReset: Int64) async throws -> ServiceUsage {
        let dbURL = try makeStateDB("Devin", modified: Self.now)
        let planEnd = planEndUnixMillis.map { "\"endTimestamp\":\($0)," } ?? ""
        let planInfo = """
        {"planName":"Teams","startTimestamp":0,\(planEnd)"usage":{},"billingStrategy":"quota",\
        "quotaUsage":{"dailyRemainingPercent":61,"weeklyRemainingPercent":30,\
        "dailyResetAtUnix":\(dailyReset),"weeklyResetAtUnix":\(weeklyReset)}}
        """
        try createWindsurfStateDB(at: dbURL, entries: [
            ("windsurfAuthStatus",
             #"{"apiKey":"sk-ws-test","allowedCommandModelConfigsProtoBinaryBase64":[],"userStatusProtoBinaryBase64":""}"#),
            ("windsurf.settings.cachedPlanInfo", planInfo)
        ])
        let service = WindsurfUsageService(stateDBLocator: { dbURL.path }, now: { Self.now })
        return try await service.fetchUsage()
    }

    func testSourceWithEndedBillingPeriodIsDiscarded() async throws {
        // The real fossil: period ended 2026-05-28, still parsing cleanly, reporting 61%/30%.
        let result = try await usage(
            planEndUnixMillis: 1_779_956_099_000,
            dailyReset: 1_779_868_800,
            weeklyReset: 1_780_214_400
        )
        XCTAssertTrue(result.windows.isEmpty, "stale source must not contribute windows")
        XCTAssertNotNil(result.error)
    }

    func testSourceWithOpenBillingPeriodAndElapsedResetsIsRetained() async throws {
        // The live Devin proto's actual state, and the case the original rule got wrong: both
        // resets are already past while the billing period is still open. It must be kept.
        let result = try await usage(
            planEndUnixMillis: 1_790_662_499_000, // 2026-09-28
            dailyReset: 1_788_508_800,            // 2026-09-04, elapsed
            weeklyReset: 1_788_681_600            // 2026-09-06, elapsed
        )
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.primaryWindow?.remainingPercent, 61)
    }

    func testSourceWithoutBillingPeriodEndIsRetained() async throws {
        // The gate demotes sources proven stale; it does not demand proof of freshness.
        //
        // Only the proto can reach this state: `WindsurfCachedPlanInfo.endTimestamp` is
        // non-optional, so a plan-info blob without it fails to decode entirely rather than
        // arriving unjudgeable. This builds a proto carrying quota and resets but no plan end.
        let proto = protoMessage([
            protoVarint(14, 61),                 // daily remaining %
            protoVarint(15, 30),                 // weekly remaining %
            protoVarint(16, 1_851_150_000),      // extra usage micros
            protoVarint(17, 1_788_508_800),      // daily reset, elapsed
            protoVarint(18, 1_788_681_600)       // weekly reset, elapsed
        ])
        let dbURL = try makeStateDB("Devin", modified: Self.now)
        try createWindsurfStateDB(at: dbURL, entries: [
            ("windsurfAuthStatus",
             "{\"apiKey\":\"sk-ws-test\",\"allowedCommandModelConfigsProtoBinaryBase64\":[],"
             + "\"userStatusProtoBinaryBase64\":\"\(Data(proto).base64EncodedString())\"}")
        ])

        let service = WindsurfUsageService(stateDBLocator: { dbURL.path }, now: { Self.now })
        let result = try await service.fetchUsage()

        XCTAssertEqual(result.windows.count, 2)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.primaryWindow?.remainingPercent, 61)
    }

    // MARK: - Part D: identity

    func testDisplayNameIsDevinWhileServiceIDStaysWindsurf() {
        XCTAssertEqual(WindsurfUsageService.displayName, "Devin")
        XCTAssertEqual(WindsurfUsageService.shortLabel, "D")
        XCTAssertEqual(WindsurfUsageService.serviceID, "windsurf",
                       "renaming this would discard cached snapshots and reset showWindsurf")
    }
}

private func createWindsurfStateDB(at url: URL, entries: [(String, String)]) throws {
    try? FileManager.default.removeItem(at: url)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        throw UsageError.invalidResponse
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil) == SQLITE_OK else {
        throw UsageError.invalidResponse
    }
    for (key, value) in entries {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
            throw UsageError.invalidResponse
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UsageError.invalidResponse
        }
    }
}

private func protoVarint(_ number: Int, _ value: UInt64) -> [UInt8] {
    encodeVarint(UInt64(number << 3)) + encodeVarint(value)
}

private func protoMessage(_ parts: [[UInt8]]) -> [UInt8] {
    parts.flatMap { $0 }
}

private func encodeVarint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value != 0
    return bytes
}
