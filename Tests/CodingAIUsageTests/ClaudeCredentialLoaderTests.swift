import XCTest
@testable import CodingAIUsage

final class ClaudeCredentialLoaderTests: XCTestCase {
    private func payload(accessToken: String, expiresAt: Int? = nil) -> Data {
        let expiry = expiresAt.map { ",\"expiresAt\":\($0)" } ?? ""
        return Data("""
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"r"\(expiry)}}
        """.utf8)
    }

    func testLoadsCredentialsFromDotfilePath() throws {
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            readFile: { $0.hasSuffix(".claude/.credentials.json") ? self.payload(accessToken: "file-token") : nil }
        )

        XCTAssertEqual(try loader.loadCredentials()?.accessToken, "file-token")
    }

    func testFallsBackToNonDotfilePath() throws {
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            readFile: { $0.hasSuffix(".claude/credentials.json") ? self.payload(accessToken: "alt-token") : nil }
        )

        XCTAssertEqual(try loader.loadCredentials()?.accessToken, "alt-token")
    }

    func testReturnsNilWhenNoCredentialFileExists() throws {
        // The expected state on macOS: Claude Code keeps credentials in the Keychain, which this
        // loader deliberately never reads. The caller falls back to the CLI.
        let loader = ClaudeCredentialLoader(homeDirectory: "/home/test", readFile: { _ in nil })

        XCTAssertNil(try loader.loadCredentials())
        XCTAssertFalse(loader.hasCredentialFile())
    }

    func testMalformedPayloadIsIgnored() throws {
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            readFile: { _ in Data(#"{"notTheRightShape":true}"#.utf8) }
        )

        XCTAssertNil(try loader.loadCredentials())
    }

    func testCredentialCacheExpiresAfterTTL() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var reads = 0
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            now: { now },
            cacheTTL: 300,
            readFile: { _ in
                reads += 1
                return self.payload(accessToken: "token-\(reads)")
            }
        )

        XCTAssertEqual(try loader.loadCredentials()?.accessToken, "token-1")
        now = now.addingTimeInterval(299)
        XCTAssertEqual(try loader.loadCredentials()?.accessToken, "token-1", "still inside the TTL")
        now = now.addingTimeInterval(2)
        XCTAssertEqual(try loader.loadCredentials()?.accessToken, "token-2", "TTL elapsed, re-read")
    }

    func testForceRefreshBypassesTheCache() throws {
        var reads = 0
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            readFile: { _ in
                reads += 1
                return self.payload(accessToken: "token-\(reads)")
            }
        )

        XCTAssertEqual(try loader.loadCredentials()?.accessToken, "token-1")
        XCTAssertEqual(try loader.loadCredentials(forceRefresh: true)?.accessToken, "token-2")
    }

    func testInvalidateCacheClearsCachedCredentials() throws {
        var invalidations = 0
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            readFile: { _ in self.payload(accessToken: "file-token") },
            onInvalidate: { invalidations += 1 }
        )

        _ = try loader.loadCredentials()
        XCTAssertEqual(loader.cacheState.cachedAccessToken, "file-token")

        loader.invalidateCache()

        XCTAssertNil(loader.cacheState.cachedAccessToken)
        XCTAssertEqual(invalidations, 1)
    }

    // MARK: - Expiry

    func testTokenPastItsExpiryIsExpired() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            now: { now },
            readFile: { _ in self.payload(accessToken: "t", expiresAt: 999_000_000) }
        )

        let credentials = try XCTUnwrap(loader.loadCredentials())
        XCTAssertTrue(loader.isExpired(credentials))
    }

    func testTokenExpiringInsideTheSkewIsExpired() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            now: { now },
            readFile: { _ in self.payload(accessToken: "t", expiresAt: 1_000_030_000) } // +30s
        )

        let credentials = try XCTUnwrap(loader.loadCredentials())
        XCTAssertTrue(loader.isExpired(credentials), "must not start a request with a token about to lapse")
    }

    func testTokenComfortablyInTheFutureIsNotExpired() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            now: { now },
            readFile: { _ in self.payload(accessToken: "t", expiresAt: 1_003_600_000) } // +1h
        )

        let credentials = try XCTUnwrap(loader.loadCredentials())
        XCTAssertFalse(loader.isExpired(credentials))
    }

    func testMissingExpiryIsTreatedAsUsable() throws {
        // The app cannot refresh, so inferring expiry from a missing field would discard a working
        // token. A 401 covers that case instead.
        let loader = ClaudeCredentialLoader(
            homeDirectory: "/home/test",
            readFile: { _ in self.payload(accessToken: "t") }
        )

        let credentials = try XCTUnwrap(loader.loadCredentials())
        XCTAssertNil(credentials.expiresAt)
        XCTAssertFalse(loader.isExpired(credentials))
    }
}
