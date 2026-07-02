import XCTest
@testable import CodingAIUsage

private final class URLRequestRecorder: @unchecked Sendable {
    var urls: [String] = []
}

private final class CallCounter: @unchecked Sendable {
    var value = 0
}

private final class HeaderRecorder: @unchecked Sendable {
    var headers: [String: String] = [:]
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

    func testClaudeUsageServicePrefersKeychainAPIOverCLI() async throws {
        let keychain = KeychainService(
            currentUsername: { "tester" },
            credentialReader: { _, _ in #"{"claudeAiOauth":{"accessToken":"kc-token","expiresAt":9999999999999}}"# },
            hashedServiceNameFinder: { "Claude Code-credentials" }
        )
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-kc-\(UUID().uuidString)", isDirectory: true)
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, keychainService: keychain)
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = Data(#"{"five_hour":{"utilization":15,"resets_at":"2026-04-03T18:00:00Z"},"seven_day":{"utilization":35}}"#.utf8)
                return (data, response)
            },
            cliExecutor: { _, _ in XCTFail("CLI must not run when Keychain credentials exist"); return .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { "/stub/claude" }
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 85)
        XCTAssertNotNil(usage.fiveHourWindow?.resetTime, "API path restores the reset countdown")
    }

    func testClaudeUsageServiceFallsBackToCLIWhenNoFileOrKeychainCredentials() async throws {
        let loader = ClaudeCredentialLoader(
            homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
            keychainService: .empty
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

        let onDisk = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("stale-token"), "refresh must not overwrite the credentials file")
        // Use a JSON-key-aware check: the accessToken value must still be the original stale token.
        // A plain contains("fresh-token") would be a false positive because "refreshToken":"refresh-token"
        // contains "fresh-token" as a substring.
        XCTAssertFalse(onDisk.contains("\"accessToken\":\"fresh-token\""), "refreshed token must stay in memory only")
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

    func testClaudeUsageResponseDecodesExpandedNullableWindows() throws {
        let data = Data(#"""
        {"five_hour":{"utilization":33.0,"resets_at":"2026-04-11T07:00:00.528743+00:00"},
         "seven_day":{"utilization":13.0,"resets_at":"2026-04-17T00:59:59.951713+00:00"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":1.0,"resets_at":"2026-04-16T03:00:00.951719+00:00"},
         "seven_day_oauth_apps":{"utilization":5},
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
        """#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = response.toServiceUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 67)
        XCTAssertEqual(usage.weeklyWindow?.remainingPercent, 87)
        XCTAssertNotNil(usage.fiveHourWindow?.resetTime)
        XCTAssertNotNil(usage.weeklyWindow?.resetTime)
        XCTAssertEqual(usage.windows.count, 2, "Opus/Sonnet must not become menu-bar windows")
        XCTAssertTrue(usage.footerLines.contains("Weekly (Sonnet): 99% remaining"))
        XCTAssertFalse(usage.footerLines.contains { $0.contains("Opus") }, "null Opus window is omitted")
    }

    func testClaudeUsageResponseHandlesMissingFiveHourWindow() throws {
        let data = Data(#"{"seven_day":{"utilization":40,"resets_at":"2026-04-08T18:00:00Z"}}"#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = response.toServiceUsage()

        XCTAssertNil(usage.fiveHourWindow)
        XCTAssertEqual(usage.weeklyWindow?.remainingPercent, 60)
        XCTAssertEqual(usage.windows.count, 1)
    }

    func testClaudeUsageRequestSendsClaudeCodeUserAgent() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-ua-\(UUID().uuidString)", isDirectory: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":9999999999999}}"#
            .write(to: filePath, atomically: true, encoding: .utf8)

        let recorder = HeaderRecorder()
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, keychainService: .empty)
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                recorder.headers = request.allHTTPHeaderFields ?? [:]
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = Data(#"{"five_hour":{"utilization":20},"seven_day":{"utilization":40}}"#.utf8)
                return (data, response)
            },
            cliExecutor: { _, _ in XCTFail("CLI must not run"); return .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil }
        )

        _ = try await service.fetchUsage()

        XCTAssertEqual(recorder.headers["User-Agent"], "claude-code/2.1.173")
    }

    func testClaudeUsageResponseToleratesWindowWithNullUtilization() throws {
        let data = Data(#"{"five_hour":{"utilization":null},"seven_day":{"utilization":20}}"#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = response.toServiceUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 100)
        XCTAssertEqual(usage.weeklyWindow?.remainingPercent, 80)
    }

    func testClaudeUsageServiceDoesNotWriteRefreshedTokenBackToKeychain() async throws {
        let writeCounter = CallCounter()
        let keychain = KeychainService(
            currentUsername: { "tester" },
            credentialWriter: { _, _, _ in writeCounter.value += 1 },
            credentialReader: { _, _ in #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"r","expiresAt":0}}"# },
            hashedServiceNameFinder: { "Claude Code-credentials" }
        )
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-nowrite-\(UUID().uuidString)", isDirectory: true)
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, keychainService: keychain)
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                if request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(#"{"access_token":"fresh","expires_in":3600}"#.utf8), response)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#.utf8), response)
            },
            cliExecutor: { _, _ in XCTFail("CLI must not run"); return .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil }
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 90)
        XCTAssertEqual(writeCounter.value, 0, "refresh must not write the new token back to the Keychain")
    }

    func testClaudeCLIUsageParserParsesHumanResetTimeSameDay() throws {
        // Fixed "now" = 2026-04-11T08:00:00Z == 10:00 in Europe/Madrid (CEST, UTC+2).
        let fixedNow = Date(timeIntervalSince1970: 1_775_894_400)
        let parser = ClaudeCLIUsageParser(now: { fixedNow })
        let output = """
        Current session: 100% used
        Resets 9:40pm (Europe/Madrid)

        Current week (all models): 60% used
        """

        let usage = try parser.parse(output)
        let reset = try XCTUnwrap(usage.fiveHourWindow?.resetTime)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let comps = calendar.dateComponents([.hour, .minute], from: reset)
        XCTAssertEqual(comps.hour, 21)
        XCTAssertEqual(comps.minute, 40)
        XCTAssertGreaterThan(reset, fixedNow)
    }

    func testClaudeCLIUsageParserParsesHumanResetTimeWithFutureDate() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_775_894_400) // 2026-04-11
        let parser = ClaudeCLIUsageParser(now: { fixedNow })
        let output = """
        Current session: 100% used
        Resets Nov 13, 2pm (America/New_York)
        """

        let usage = try parser.parse(output)
        let reset = try XCTUnwrap(usage.fiveHourWindow?.resetTime)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let comps = calendar.dateComponents([.month, .day, .hour], from: reset)
        XCTAssertEqual(comps.month, 11)
        XCTAssertEqual(comps.day, 13)
        XCTAssertEqual(comps.hour, 14)
    }

    func testClaudeCLIUsageParserHandlesMidnightAndNoonMeridiem() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_775_894_400) // 10:00 Europe/Madrid
        let parser = ClaudeCLIUsageParser(now: { fixedNow })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!

        for (label, expectedHour) in [("12am", 0), ("12pm", 12), ("1pm", 13), ("11pm", 23)] {
            let usage = try parser.parse("Current session: 100% used\nResets \(label) (Europe/Madrid)")
            let reset = try XCTUnwrap(usage.fiveHourWindow?.resetTime, "for \(label)")
            XCTAssertEqual(calendar.component(.hour, from: reset), expectedHour, "for \(label)")
        }
    }

    func testClaudeCLIUsageParserReturnsNilResetForUnparseableTime() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_775_894_400)
        let parser = ClaudeCLIUsageParser(now: { fixedNow })
        // No am/pm, no ISO timestamp -> reset must be nil, but the window must still be built.
        let usage = try parser.parse("Current session: 100% used\nResets in 3h")
        XCTAssertNotNil(usage.fiveHourWindow)
        XCTAssertNil(usage.fiveHourWindow?.resetTime)
    }

    func testClaudeCLIUsageParserRollsResetToNextDayWhenTimeAlreadyPassed() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_775_894_400) // 10:00 Europe/Madrid, Apr 11
        let parser = ClaudeCLIUsageParser(now: { fixedNow })
        let usage = try parser.parse("Current session: 100% used\nResets 9am (Europe/Madrid)")
        let reset = try XCTUnwrap(usage.fiveHourWindow?.resetTime)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let comps = calendar.dateComponents([.day, .hour], from: reset)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.day, 12, "9am already passed at 10:00 now, so it must roll to tomorrow")
        XCTAssertGreaterThan(reset, fixedNow)
    }

    func testClaudeUsageServiceDoesNotDoubleRefreshAfter401() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-dblrefresh-\(UUID().uuidString)", isDirectory: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"rt","expiresAt":0}}"#
            .write(to: filePath, atomically: true, encoding: .utf8)

        let tokenCalls = CallCounter()
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, keychainService: .empty)
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                if request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token" {
                    tokenCalls.value += 1
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(#"{"access_token":"fresh","expires_in":3600}"#.utf8), response)
                }
                // Usage endpoint always rejects -> exercises the 401 recovery path.
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            },
            cliExecutor: { _, _ in XCTFail("CLI must not run"); return .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { nil }
        )

        do {
            _ = try await service.fetchUsage()
            XCTFail("expected fetchUsage to throw authExpired")
        } catch let error as UsageError {
            guard case .authExpired = error else {
                XCTFail("expected .authExpired, got \(error)")
                return
            }
        }

        XCTAssertEqual(tokenCalls.value, 1, "refresh token must not be consumed twice across the 401 retry")
    }

    func testClaudeCLIUsageParserParsesMultiComponentTimezone() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_775_894_400) // 2026-04-11T08:00:00Z
        let parser = ClaudeCLIUsageParser(now: { fixedNow })
        let usage = try parser.parse("Current session: 100% used\nResets 9:40pm (America/Indiana/Indianapolis)")
        let reset = try XCTUnwrap(usage.fiveHourWindow?.resetTime)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        let comps = calendar.dateComponents([.hour, .minute], from: reset)
        XCTAssertEqual(comps.hour, 21)
        XCTAssertEqual(comps.minute, 40)
    }

    func testClaudeUsageServiceDoesNotFallBackToCLIWhenKeychainAPIFails() async throws {
        let keychain = KeychainService(
            currentUsername: { "tester" },
            credentialReader: { _, _ in #"{"claudeAiOauth":{"accessToken":"kc-token","expiresAt":9999999999999}}"# },
            hashedServiceNameFinder: { "Claude Code-credentials" }
        )
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-kcfail-\(UUID().uuidString)", isDirectory: true)
        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, keychainService: keychain)
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            },
            cliExecutor: { _, _ in
                XCTFail("CLI must not run as a fallback when the Keychain/API path errors")
                return .init(exitCode: 1, output: "")
            },
            claudeBinaryLocator: { "/stub/claude" }
        )

        do {
            _ = try await service.fetchUsage()
            XCTFail("expected fetchUsage to throw when the API is rate-limited")
        } catch let error as UsageError {
            guard case .rateLimited = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
        }
    }

    func testClaudeUsageServiceSurfacesRefreshRateLimitAsRateLimited() async throws {
        // A near-expiry token triggers a proactive refresh on every poll. When the token endpoint
        // itself is rate-limited we must surface .rateLimited (with Retry-After) so polling backs off,
        // rather than .httpError(429) which keeps hammering the endpoint at the base interval.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-refresh-429-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-token","expiresAt":0}}"#
            .write(to: filePath, atomically: true, encoding: .utf8)

        let loader = ClaudeCredentialLoader(homeDirectory: tempDir.path, keychainService: .empty)
        let service = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "120"]
                )!
                return (Data(), response)
            },
            cliExecutor: { _, _ in
                XCTFail("CLI should not be used when file credentials exist")
                return .init(exitCode: 1, output: "")
            },
            claudeBinaryLocator: { nil }
        )

        do {
            _ = try await service.fetchUsage()
            XCTFail("expected fetchUsage to throw when the refresh endpoint is rate-limited")
        } catch let error as UsageError {
            guard case .rateLimited(let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(retryAfter, 120)
        }
    }
}
