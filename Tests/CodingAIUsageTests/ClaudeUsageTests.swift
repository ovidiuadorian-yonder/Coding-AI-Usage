import XCTest
@testable import CodingAIUsage

private final class URLRequestRecorder: @unchecked Sendable {
    var urls: [String] = []
}

private final class CallCounter: @unchecked Sendable {
    var value = 0
}

final class ClaudeUsageTests: XCTestCase {
    @MainActor
    func testClaudeCheckInstalledFindsUserLocalBinaryWithoutPATH() async throws {
        let localClaudePath = NSHomeDirectory() + "/.local/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: localClaudePath) else {
            throw XCTSkip("This machine does not install claude under ~/.local/bin")
        }

        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let installed = await ClaudeUsageService().checkInstalled()

        XCTAssertTrue(installed)
    }

    func testClaudeReauthCommandStartsLoginFlow() {
        XCTAssertEqual(
            ClaudeAuthLauncher.reauthCommand,
            "/bin/zsh -lc 'claude auth login --claudeai'"
        )
    }

    func testClaudeCLIUsageParserBuildsServiceUsageFromQuotaOutput() throws {
        let output = """
        Current session
        25% used
        Resets at 2026-04-03T18:00:00Z

        Current week (all models)
        40% left
        Resets at 2026-04-08T18:00:00Z
        """

        let usage = try ClaudeCLIUsageParser().parse(output)

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 75)
        XCTAssertEqual(usage.weeklyWindow?.remainingPercent, 40)
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertNotNil(usage.fiveHourWindow?.resetTime)
        XCTAssertNotNil(usage.weeklyWindow?.resetTime)
    }

    func testClaudeUsageResponseParsesResetDatesWithoutFractionalSeconds() throws {
        let data = Data(#"{"five_hour":{"utilization":20,"resets_at":"2026-04-03T18:00:00Z"},"seven_day":{"utilization":45,"resets_at":"2026-04-08T18:00:00Z"}}"#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = response.toServiceUsage()

        XCTAssertNotNil(usage.fiveHourWindow?.resetTime)
        XCTAssertNotNil(usage.weeklyWindow?.resetTime)
    }

    func testClaudeUsageResponseParsesMixedResetDateFormatsIndependently() throws {
        let data = Data(#"{"five_hour":{"utilization":20,"resets_at":"2026-04-03T18:00:00Z"},"seven_day":{"utilization":45,"resets_at":"2026-04-08T18:00:00.000Z"}}"#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = response.toServiceUsage()

        XCTAssertNotNil(usage.fiveHourWindow?.resetTime)
        XCTAssertNotNil(usage.weeklyWindow?.resetTime)
    }

    func testClaudeCLIUsageParserTreatsLoginPromptAsNotLoggedIn() {
        let output = "Authentication required. Please run claude login."

        XCTAssertThrowsError(try ClaudeCLIUsageParser().parse(output)) { error in
            XCTAssertEqual(
                error as? UsageError,
                .noCredentials("Claude Code: not logged in")
            )
        }
    }

    func testClaudeCLIUsageParserTreatsTrustPromptAsRecoverableError() {
        let output = """
        Ready to code here?
        Press Enter to continue
        """

        XCTAssertThrowsError(try ClaudeCLIUsageParser().parse(output)) { error in
            XCTAssertEqual(
                error as? UsageError,
                .networkError("Claude Code: CLI needs folder trust confirmation")
            )
        }
    }

    func testClaudeUsageServicePrefersCLIWhenCredentialFileIsUnavailable() async throws {
        let loader = ClaudeCredentialLoader(
            homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
            keychainService: KeychainService()
        )

        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { _ in
                XCTFail("API should not be called when CLI succeeds")
                throw UsageError.invalidResponse
            },
            cliExecutor: { _, _ in
                .init(
                    exitCode: 0,
                    output: """
                    Current session
                    20% used
                    Current week (all models)
                    60% left
                    """
                )
            },
            claudeBinaryLocator: { "/stub/claude" }
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 80)
        XCTAssertEqual(usage.weeklyWindow?.remainingPercent, 60)
    }

    func testClaudeUsageServiceRefreshesExpiredFileTokenBeforeFetchingUsage() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-api-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-token","expiresAt":0}}
        """.write(to: filePath, atomically: true, encoding: .utf8)

        let requestRecorder = URLRequestRecorder()
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, keychainService: .empty)
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                requestRecorder.urls.append(request.url?.absoluteString ?? "")

                if request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    let data = Data(#"{"access_token":"fresh-token","refresh_token":"fresh-refresh","expires_in":3600}"#.utf8)
                    return (data, response)
                }

                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = Data(#"{"five_hour":{"utilization":20,"resets_at":"2026-04-03T18:00:00.000Z"},"seven_day":{"utilization":45,"resets_at":"2026-04-08T18:00:00.000Z"}}"#.utf8)
                return (data, response)
            },
            cliExecutor: { _, _ in
                XCTFail("CLI should not be used when file credentials exist")
                return .init(exitCode: 1, output: "")
            },
            claudeBinaryLocator: { nil }
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 80)
        XCTAssertEqual(requestRecorder.urls, [
            "https://platform.claude.com/v1/oauth/token",
            "https://api.anthropic.com/api/oauth/usage"
        ])
    }

    func testClaudeUsageServiceReloadsCredentialsAfter401AndRetriesOnce() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-api-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"stale-token","expiresAt":9999999999999}}"#
            .write(to: filePath, atomically: true, encoding: .utf8)

        let usageCalls = CallCounter()
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, keychainService: .empty)
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                usageCalls.value += 1

                if usageCalls.value == 1 {
                    try #"{"claudeAiOauth":{"accessToken":"fresh-token","expiresAt":9999999999999}}"#
                        .write(to: filePath, atomically: true, encoding: .utf8)
                    let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                    return (Data(), response)
                }

                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = Data(#"{"five_hour":{"utilization":10,"resets_at":"2026-04-03T18:00:00.000Z"},"seven_day":{"utilization":30,"resets_at":"2026-04-08T18:00:00.000Z"}}"#.utf8)
                return (data, response)
            },
            cliExecutor: { _, _ in
                XCTFail("CLI should not be used when file credentials exist")
                return .init(exitCode: 1, output: "")
            },
            claudeBinaryLocator: { nil }
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 90)
        XCTAssertEqual(usageCalls.value, 2)
    }

    @MainActor
    func testClaudeUsageServiceDoesNotTriggerShellStartupForCLIProbe() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-cli-shell-\(UUID().uuidString)", isDirectory: true)
        let zdotDir = tempDir.appendingPathComponent("zdot", isDirectory: true)
        let markerFile = tempDir.appendingPathComponent("shell-startup-marker")
        let fakeClaude = tempDir.appendingPathComponent("claude")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zdotDir, withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        cat <<'EOF'
        Current session
        20% used
        Current week (all models)
        60% left
        EOF
        """
        try script.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeClaude.path
        )

        // A zsh startup file that creates a marker — should never be sourced since the executor
        // runs the binary directly (not via `zsh -lc`).
        let zshEnv = """
        touch "\(markerFile.path)"
        """
        try zshEnv.write(
            to: zdotDir.appendingPathComponent(".zshenv"),
            atomically: true,
            encoding: .utf8
        )

        let originalZdotDir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", zdotDir.path, 1)
        defer {
            if let originalZdotDir {
                setenv("ZDOTDIR", originalZdotDir, 1)
            } else {
                unsetenv("ZDOTDIR")
            }
        }

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            keychainService: .empty
        )
        // Inject the absolute path directly so the executor runs fakeClaude without PATH lookup.
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { _ in
                XCTFail("API should not be called when CLI succeeds")
                throw UsageError.invalidResponse
            },
            claudeBinaryLocator: { fakeClaude.path }
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 80)
        XCTAssertEqual(usage.weeklyWindow?.remainingPercent, 60)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerFile.path),
            "CLI execution should not source shell startup files"
        )
    }

    func testClaudeReauthAppleScriptEscapesCommandQuotes() {
        let script = ClaudeAuthLauncher.appleScript(command: #"echo "quoted""#)

        XCTAssertTrue(script.contains(#"do script "echo \"quoted\"""#))
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
    }
}
