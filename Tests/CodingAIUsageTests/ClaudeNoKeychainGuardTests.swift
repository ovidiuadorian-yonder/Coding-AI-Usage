import XCTest
@testable import CodingAIUsage

/// Guards the two invariants of `2026-09-07-claude-cli-primary-design.md`.
///
/// Both symptoms this design addresses came from borrowing Claude Code's own credential: the CLI's
/// `security add-generic-password -U` write resets the item's ACL (password prompts), and
/// refreshing a grant the CLI also rotates rate-limits the token endpoint (429s). These tests fail
/// if either capability comes back.
final class ClaudeNoKeychainGuardTests: XCTestCase {

    private static let usageJSON = #"{"five_hour":{"utilization":20,"resets_at":"2026-04-03T18:00:00.000Z"},"seven_day":{"utilization":45,"resets_at":"2026-04-08T18:00:00.000Z"}}"#

    private static let cliOutput = """
    Current session: 12% used · resets Sep 7 at 1:10pm (Europe/Bucharest)
    Current week (all models): 85% used · resets Sep 9 at 5am (Europe/Bucharest)
    Current week (Fable): 3% used · resets Sep 9 at 5am (Europe/Bucharest)
    """

    /// The Claude sources must contain no Keychain API reference at all. Enforced by construction
    /// once `KeychainService` is deleted; asserted here so a reintroduction is caught in review.
    func testClaudeSourcesReferenceNoKeychainAPI() throws {
        let sources = [
            "CodingAIUsage/Services/ClaudeUsageService.swift",
            "CodingAIUsage/Services/ClaudeCredentialLoader.swift",
            "CodingAIUsage/Services/ClaudeCLIUsageParser.swift"
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CodingAIUsageTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root

        for relative in sources {
            let url = root.appendingPathComponent(relative)
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "kSecClass", "import Security"] {
                XCTAssertFalse(text.contains(forbidden), "\(relative) reintroduced \(forbidden)")
            }
        }
    }

    /// No request may reach platform.claude.com. A refresh there is what produced the 429s.
    func testNoRequestReachesTheTokenEndpoint() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-guard-\(UUID().uuidString)", isDirectory: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Deliberately expired, the state that previously triggered a refresh.
        try #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"r","expiresAt":0}}"#
            .write(to: filePath, atomically: true, encoding: .utf8)

        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: tempDir.path),
            networkClient: { request in
                let host = request.url?.host ?? ""
                XCTAssertNotEqual(host, "platform.claude.com", "the token endpoint must be unreachable")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(Self.usageJSON.utf8), response)
            },
            cliExecutor: { _, _ in .init(exitCode: 0, output: Self.cliOutput) },
            claudeBinaryLocator: { "/usr/local/bin/claude" }
        )

        let usage = try await service.fetchUsage()

        // An expired file token falls through to the CLI instead of being refreshed.
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.primaryWindow?.remainingPercent, 88)
    }

    func testValidFileTokenUsesTheAPIAndDoesNotSpawnTheCLI() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-guard-\(UUID().uuidString)", isDirectory: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expiry = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        try "{\"claudeAiOauth\":{\"accessToken\":\"good\",\"refreshToken\":\"r\",\"expiresAt\":\(expiry)}}"
            .write(to: filePath, atomically: true, encoding: .utf8)

        let service = ClaudeUsageService(
            credentialLoader: ClaudeCredentialLoader(homeDirectory: tempDir.path),
            networkClient: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(Self.usageJSON.utf8), response)
            },
            cliExecutor: { _, _ in
                XCTFail("the CLI must not be spawned when a valid file token exists")
                return .init(exitCode: 1, output: "")
            },
            claudeBinaryLocator: { "/usr/local/bin/claude" }
        )

        let usage = try await service.fetchUsage()
        XCTAssertEqual(usage.primaryWindow?.remainingPercent, 80)
    }

    /// Regression fixture of the CLI output as of v2.1.258 — the reset moved onto the same line
    /// after a `·`, lowercase, with `at` between date and time.
    func testCurrentCLIOutputFormatParses() throws {
        let usage = try ClaudeCLIUsageParser().parse(Self.cliOutput)

        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.primaryWindow?.remainingPercent, 88)
        XCTAssertEqual(usage.secondaryWindow?.remainingPercent, 15)
        XCTAssertNotNil(usage.primaryWindow?.resetTime)
        XCTAssertNotNil(usage.secondaryWindow?.resetTime)
    }
}
