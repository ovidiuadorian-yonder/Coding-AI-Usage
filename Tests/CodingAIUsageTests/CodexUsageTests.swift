import XCTest
@testable import CodingAIUsage

final class CodexUsageTests: XCTestCase {
    private static let usageJSON = """
    {
        "plan_type": "team",
        "rate_limit": {
            "allowed": false,
            "limit_reached": true,
            "primary_window": {
                "used_percent": 100,
                "limit_window_seconds": 18000,
                "reset_after_seconds": 12551,
                "reset_at": 1782992901
            },
            "secondary_window": {
                "used_percent": 74,
                "limit_window_seconds": 604800,
                "reset_after_seconds": 472245,
                "reset_at": 1783452596
            }
        },
        "rate_limit_reset_credits": {
            "available_count": 3
        }
    }
    """

    private static let resetCreditsJSON = """
    {
        "credits": [
            {
                "id": "RateLimitResetCredit_1",
                "status": "available",
                "granted_at": "2026-06-18T00:56:07.780413Z",
                "expires_at": "2026-07-18T00:56:07.780413Z",
                "title": "Full reset (Weekly + 5 hr)"
            },
            {
                "id": "RateLimitResetCredit_2",
                "status": "available",
                "granted_at": "2026-06-27T00:06:11.210000Z",
                "expires_at": "2026-07-27T00:06:11.210000Z",
                "title": "Full reset (Weekly + 5 hr)"
            },
            {
                "id": "RateLimitResetCredit_3",
                "status": "redeemed",
                "granted_at": "2026-05-01T00:00:00.000000Z",
                "expires_at": "2026-06-01T00:00:00.000000Z",
                "title": "Full reset (Weekly + 5 hr)"
            }
        ]
    }
    """

    private func expectedDateText(_ isoTimestamp: String) throws -> String {
        let date = try XCTUnwrap(CodexResetCreditsResponse.parseTimestamp(isoTimestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    func testParseTimestampHandlesMicrosecondFractions() {
        let date = CodexResetCreditsResponse.parseTimestamp("2026-07-18T00:56:07.780413Z")

        XCTAssertNotNil(date)
        XCTAssertEqual(
            date,
            ISO8601DateFormatter().date(from: "2026-07-18T00:56:07Z")
        )
    }

    func testFooterCountsOnlyAvailableCreditsAndUsesEarliestExpiration() throws {
        let resetCredits = try JSONDecoder().decode(
            CodexResetCreditsResponse.self,
            from: Data(Self.resetCreditsJSON.utf8)
        )

        let lines = CodexUsageResponse.resetCreditsFooterLines(
            resetCredits: resetCredits,
            fallbackAvailableCount: 99
        )

        // The redeemed credit must not count, and the redeemed credit's
        // earlier expiration must not win "first expires".
        let expectedDate = try expectedDateText("2026-07-18T00:56:07.780413Z")
        XCTAssertEqual(lines, ["Rate limit resets: 2 available (first expires \(expectedDate))"])
    }

    func testFooterFallsBackToUsageCountWhenDetailEndpointUnavailable() {
        let lines = CodexUsageResponse.resetCreditsFooterLines(
            resetCredits: nil,
            fallbackAvailableCount: 3
        )

        XCTAssertEqual(lines, ["Rate limit resets: 3 available"])
    }

    func testFooterShowsNoneAvailableWhenAllCreditsAreSpent() throws {
        let resetCredits = try JSONDecoder().decode(
            CodexResetCreditsResponse.self,
            from: Data("""
            {"credits": [{"id": "x", "status": "redeemed", "expires_at": "2026-06-01T00:00:00Z"}]}
            """.utf8)
        )

        let lines = CodexUsageResponse.resetCreditsFooterLines(
            resetCredits: resetCredits,
            fallbackAvailableCount: nil
        )

        XCTAssertEqual(lines, ["Rate limit resets: none available"])
    }

    func testFooterAbsentWhenApiOmitsResetInfo() {
        let lines = CodexUsageResponse.resetCreditsFooterLines(
            resetCredits: nil,
            fallbackAvailableCount: nil
        )

        XCTAssertEqual(lines, [])
    }

    // MARK: - Service integration

    private func makeAuthFile() throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let authPath = tempDir.appendingPathComponent("auth.json")
        try #"{"auth_mode":"chatgpt","tokens":{"access_token":"test-token"}}"#
            .write(to: authPath, atomically: true, encoding: .utf8)
        return authPath.path
    }

    func testFetchUsageAttachesResetCreditsFooter() async throws {
        let authPath = try makeAuthFile()

        let service = CodexUsageService(
            authFilePath: authPath,
            networkClient: { request in
                let url = try XCTUnwrap(request.url)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")

                let body: String
                switch url.absoluteString {
                case "https://chatgpt.com/backend-api/wham/usage":
                    body = Self.usageJSON
                case "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits":
                    body = Self.resetCreditsJSON
                default:
                    XCTFail("unexpected request to \(url)")
                    body = "{}"
                }

                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (Data(body.utf8), response)
            }
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.windows.map(\.id), ["five_hour", "seven_day"])
        let expectedDate = try expectedDateText("2026-07-18T00:56:07.780413Z")
        XCTAssertEqual(usage.footerLines, ["Rate limit resets: 2 available (first expires \(expectedDate))"])
    }

    func testFetchUsageSurvivesResetCreditsEndpointFailure() async throws {
        let authPath = try makeAuthFile()

        let service = CodexUsageService(
            authFilePath: authPath,
            networkClient: { request in
                let url = try XCTUnwrap(request.url)
                if url.absoluteString == "https://chatgpt.com/backend-api/wham/usage" {
                    let response = HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!
                    return (Data(Self.usageJSON.utf8), response)
                }

                let response = HTTPURLResponse(
                    url: url, statusCode: 500, httpVersion: nil, headerFields: nil
                )!
                return (Data(), response)
            }
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.windows.count, 2)
        // Falls back to the count embedded in the usage response.
        XCTAssertEqual(usage.footerLines, ["Rate limit resets: 3 available"])
    }
}
