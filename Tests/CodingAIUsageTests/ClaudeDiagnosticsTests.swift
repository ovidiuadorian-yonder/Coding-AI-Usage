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
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home),
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
            credentialLoader: ClaudeCredentialLoader(homeDirectory: home),
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

}
