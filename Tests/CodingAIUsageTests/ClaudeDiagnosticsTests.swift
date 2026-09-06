import XCTest
@testable import CodingAIUsage

/// Temporary instrumentation coverage.
///
/// These tests exist to prove the 429 endpoint-attribution logging works before it is relied on
/// to diagnose a live symptom. They are expected to be deleted alongside the token-endpoint log
/// points when the refresh path is removed (Part C of
/// `docs/superpowers/specs/2026-09-06-claude-readonly-credentials-design.md`).
final class ClaudeDiagnosticsTests: XCTestCase {

    /// Thread-safe collector for the `@Sendable` diagnostic closure, which the actor may invoke
    /// from an arbitrary executor.
    private final class DiagnosticSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func record(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }

        func line(containing needle: String) -> String? {
            lines.first { $0.contains(needle) }
        }
    }

    private func makeCredentialsDirectory(
        accessToken: String,
        refreshToken: String,
        expiresAt: Int
    ) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-diag-\(UUID().uuidString)", isDirectory: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(
            at: filePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"\(refreshToken)","expiresAt":\(expiresAt)}}
        """.write(to: filePath, atomically: true, encoding: .utf8)
        return tempDir.path
    }

    private static let usageJSON = #"{"five_hour":{"utilization":20,"resets_at":"2026-04-03T18:00:00.000Z"},"seven_day":{"utilization":45,"resets_at":"2026-04-08T18:00:00.000Z"}}"#

    // MARK: - Endpoint attribution

    func testUsageEndpointRateLimitIsLoggedAsUsageEndpoint() async throws {
        // A valid (non-expired) token goes straight to the usage endpoint, so a 429 here can only
        // be attributed to api.anthropic.com.
        let home = try makeCredentialsDirectory(
            accessToken: "valid-token",
            refreshToken: "refresh-token",
            expiresAt: Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        )
        let spy = DiagnosticSpy()
        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home, keychainService: .empty),
            networkClient: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "90"]
                )!
                return (Data(), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil },
            diagnostic: { spy.record($0) }
        )

        _ = try? await service.fetchUsage()

        let line = try XCTUnwrap(spy.line(containing: "endpoint=usage"), "expected a usage-endpoint diagnostic, got \(spy.lines)")
        XCTAssertTrue(line.contains("status=429"), line)
        XCTAssertTrue(line.contains("retry-after=90"), line)
        XCTAssertFalse(line.contains("endpoint=token"), line)
    }

    func testTokenEndpointRateLimitIsLoggedAsTokenEndpoint() async throws {
        // An expired token forces a refresh first, so a 429 here is attributable to
        // platform.claude.com and must be distinguishable from the usage-endpoint case above.
        let home = try makeCredentialsDirectory(
            accessToken: "stale-token",
            refreshToken: "refresh-token",
            expiresAt: 0
        )
        let spy = DiagnosticSpy()
        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home, keychainService: .empty),
            networkClient: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "240"]
                )!
                return (Data(), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil },
            diagnostic: { spy.record($0) }
        )

        _ = try? await service.fetchUsage()

        let line = try XCTUnwrap(spy.line(containing: "endpoint=token"), "expected a token-endpoint diagnostic, got \(spy.lines)")
        XCTAssertTrue(line.contains("status=429"), line)
        XCTAssertTrue(line.contains("retry-after=240"), line)
    }

    func testTokenEndpointInvalidGrantIsLoggedWithErrorCode() async throws {
        // invalid_grant is the signature of the concurrent-client conflict (CodexBar #1161).
        let home = try makeCredentialsDirectory(
            accessToken: "stale-token",
            refreshToken: "consumed-refresh",
            expiresAt: 0
        )
        let spy = DiagnosticSpy()
        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home, keychainService: .empty),
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"error":"invalid_grant"}"#.utf8), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil },
            diagnostic: { spy.record($0) }
        )

        _ = try? await service.fetchUsage()

        let line = try XCTUnwrap(spy.line(containing: "endpoint=token"), "expected a token-endpoint diagnostic, got \(spy.lines)")
        XCTAssertTrue(line.contains("status=400"), line)
        XCTAssertTrue(line.contains("error=invalid_grant"), line)
    }

    func testMissingRetryAfterIsLoggedAsAbsent() async throws {
        // Sources disagree on whether Retry-After is sent at all, so its absence must be recorded
        // explicitly rather than omitted from the line.
        let home = try makeCredentialsDirectory(
            accessToken: "valid-token",
            refreshToken: "refresh-token",
            expiresAt: Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        )
        let spy = DiagnosticSpy()
        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home, keychainService: .empty),
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil },
            diagnostic: { spy.record($0) }
        )

        _ = try? await service.fetchUsage()

        let line = try XCTUnwrap(spy.line(containing: "endpoint=usage"))
        XCTAssertTrue(line.contains("retry-after=absent"), line)
    }

    func testServerSuppliedErrorCodeCannotForgeAnExtraLogLine() async throws {
        // The line is logged .public and is parsed by eye and by grep, so a newline in a
        // server-supplied value must not be able to fabricate a second, plausible-looking record.
        let home = try makeCredentialsDirectory(
            accessToken: "stale-token",
            refreshToken: "consumed-refresh",
            expiresAt: 0
        )
        let spy = DiagnosticSpy()
        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home, keychainService: .empty),
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"error":"bad\nendpoint=usage status=429 retry-after=absent"}"#.utf8), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil },
            diagnostic: { spy.record($0) }
        )

        _ = try? await service.fetchUsage()

        // The neutralized text may still appear *inside* the error field — that is fine and is the
        // point. What must not happen is a second record, or a record that a line-oriented reader
        // would attribute to the usage endpoint. So assert on record boundaries, not on substrings.
        XCTAssertEqual(spy.lines.count, 1, "expected exactly one record, got \(spy.lines)")
        let line = try XCTUnwrap(spy.lines.first)
        XCTAssertFalse(line.contains("\n"), "record must stay a single line: \(line)")
        XCTAssertTrue(line.hasPrefix("endpoint=token "), line)
        XCTAssertFalse(
            spy.lines.contains { $0.hasPrefix("endpoint=usage") },
            "forged usage-endpoint record: \(spy.lines)"
        )
    }

    func testOverlongErrorCodeIsTruncated() throws {
        let long = String(repeating: "x", count: 500)
        let field = DiagnosticLog.field(long)
        XCTAssertTrue(field.hasSuffix("<truncated>"), field)
        XCTAssertLessThan(field.count, 100)
    }

    func testFingerprintIsEightHexCharacters() throws {
        let fingerprint = DiagnosticLog.fingerprint("some-token")
        XCTAssertEqual(fingerprint.count, 8, fingerprint)
        XCTAssertTrue(fingerprint.allSatisfy { $0.isHexDigit }, fingerprint)
        XCTAssertEqual(DiagnosticLog.fingerprint("some-token"), fingerprint, "must be stable")
        XCTAssertNotEqual(DiagnosticLog.fingerprint("other-token"), fingerprint)
        XCTAssertEqual(DiagnosticLog.fingerprint(nil), "none")
    }

    // MARK: - Rotation probe

    func testRotatedRefreshTokenIsReportedAsChanged() async throws {
        // Settles the open question: if the endpoint returns a different refresh_token than the one
        // presented, rotation is happening and the CLI's stored copy is being superseded.
        let home = try makeCredentialsDirectory(
            accessToken: "stale-token",
            refreshToken: "original-refresh",
            expiresAt: 0
        )
        let spy = DiagnosticSpy()
        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home, keychainService: .empty),
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token" {
                    return (Data(#"{"access_token":"fresh","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8), response)
                }
                return (Data(Self.usageJSON.utf8), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil },
            diagnostic: { spy.record($0) }
        )

        _ = try await service.fetchUsage()

        let line = try XCTUnwrap(spy.line(containing: "refresh-token-changed"), "expected a rotation diagnostic, got \(spy.lines)")
        XCTAssertTrue(line.contains("refresh-token-changed=true"), line)
    }

    func testUnchangedRefreshTokenIsReportedAsUnchanged() async throws {
        let home = try makeCredentialsDirectory(
            accessToken: "stale-token",
            refreshToken: "original-refresh",
            expiresAt: 0
        )
        let spy = DiagnosticSpy()
        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home, keychainService: .empty),
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token" {
                    return (Data(#"{"access_token":"fresh","refresh_token":"original-refresh","expires_in":3600}"#.utf8), response)
                }
                return (Data(Self.usageJSON.utf8), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil },
            diagnostic: { spy.record($0) }
        )

        _ = try await service.fetchUsage()

        let line = try XCTUnwrap(spy.line(containing: "refresh-token-changed"))
        XCTAssertTrue(line.contains("refresh-token-changed=false"), line)
    }

    func testDiagnosticsNeverContainRawTokenMaterial() async throws {
        // The log is written to the unified log store at .notice and marked .public, so it must
        // never carry token material — only fingerprints.
        // Deliberately distinctive values: a naive check for something like "fresh" would be a
        // false positive against the literal "refresh-token-changed" in the log line itself.
        let home = try makeCredentialsDirectory(
            accessToken: "ACCESSSECRETAAA",
            refreshToken: "STOREDSECRETBBB",
            expiresAt: 0
        )
        let spy = DiagnosticSpy()
        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home, keychainService: .empty),
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token" {
                    return (Data(#"{"access_token":"NEWACCESSCCC","refresh_token":"ROTATEDSECRETDDD","expires_in":3600}"#.utf8), response)
                }
                return (Data(Self.usageJSON.utf8), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil },
            diagnostic: { spy.record($0) }
        )

        _ = try await service.fetchUsage()

        let joined = spy.lines.joined(separator: "\n")
        for secret in ["ACCESSSECRETAAA", "STOREDSECRETBBB", "NEWACCESSCCC", "ROTATEDSECRETDDD"] {
            XCTAssertFalse(joined.contains(secret), "diagnostic leaked \(secret): \(joined)")
        }
    }
}
