# Claude Credentials Signing & Reset-Time Restoration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop repeated macOS Keychain prompts and restore the missing Claude "next reset" countdown in the Coding AI Usage menu-bar app.

**Architecture:** Two synergistic fixes. (1) Sign the app bundle with a stable self-signed code-signing identity so the Keychain "Always Allow" grant survives rebuilds. (2) Make the clean JSON `/api/oauth/usage` endpoint the primary Claude source (with the now-required `claude-code` User-Agent), demote the fragile CLI-TUI scraper to a last-resort fallback, decode the expanded/nullable API window shape, stop writing tokens back to the Keychain, and fix the CLI fallback parser for Claude's new human-readable reset format.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, AppKit/SwiftUI, bash, `codesign`/`security`.

---

## Reference: current `/api/oauth/usage` response shape

Each window is `{ "utilization": <0-100 number, may be fractional>, "resets_at": "<iso8601 or absent>" }`. Top-level windows (all nullable, unknown keys ignored): `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, plus others we deliberately ignore (`seven_day_oauth_apps`, `seven_day_routines`, `extra_usage`). Required request headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version>` (missing UA → 429 throttling).

Current `claude /usage` text (fallback parser only): `Current session: 100% used` / `Resets 9:40pm (Europe/Madrid)` / `Current week (all models): 60% used` / `Current week (Sonnet only): 1% used`. Reset line: `Resets <h:mma> (<IANA tz>)` with an optional leading `Mon DD,` date token (date present only when reset is a future day). No ISO timestamps.

## File map

- **Modify** `CodingAIUsage/Models/ClaudeUsageResponse.swift` — expanded, nullable window decoding; Opus/Sonnet → footer lines (Task 1).
- **Modify** `CodingAIUsage/Services/ClaudeUsageService.swift` — User-Agent header (Task 2); API-primary ordering (Task 3); no write-back on refresh (Task 4).
- **Modify** `CodingAIUsage/Services/ClaudeCredentialLoader.swift` — add `cacheRefreshedCredentials` (Task 4).
- **Modify** `CodingAIUsage/Services/ClaudeCLIUsageParser.swift` — human-readable reset parsing (Task 5).
- **Modify** `Tests/CodingAIUsageTests/ClaudeUsageTests.swift` — tests for Tasks 1–5.
- **Create** `sign.sh` — stable signing step (Task 6).
- **Create** `Tests/sign_sh_test.sh`, `Tests/build_sh_test.sh` — shell tests (Tasks 6–7).
- **Modify** `build.sh` — invoke `sign.sh` (Task 7).
- **Modify** `README.md` — document signing, write-back removal, expanded windows (Task 8).

---

## Task 1: Decode the expanded, nullable API window shape

**Files:**
- Modify: `CodingAIUsage/Models/ClaudeUsageResponse.swift`
- Test: `Tests/CodingAIUsageTests/ClaudeUsageTests.swift`

- [ ] **Step 1: Add failing tests**

Add these three methods to `final class ClaudeUsageTests` in `Tests/CodingAIUsageTests/ClaudeUsageTests.swift`:

```swift
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

    func testClaudeUsageResponseToleratesWindowWithNullUtilization() throws {
        let data = Data(#"{"five_hour":{"utilization":null},"seven_day":{"utilization":20}}"#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let usage = response.toServiceUsage()

        XCTAssertEqual(usage.fiveHourWindow?.remainingPercent, 100)
        XCTAssertEqual(usage.weeklyWindow?.remainingPercent, 80)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClaudeUsageTests/testClaudeUsageResponseDecodesExpandedNullableWindows`
Expected: FAIL to compile or assertion failure (current model has non-optional `fiveHour`/`sevenDay`, no `footerLines` output, no Opus/Sonnet handling).

- [ ] **Step 3: Rewrite the model**

Replace the entire contents of `CodingAIUsage/Models/ClaudeUsageResponse.swift` with:

```swift
import Foundation

struct ClaudeUsageResponse: Decodable {
    let fiveHour: WindowData?
    let sevenDay: WindowData?
    let sevenDayOpus: WindowData?
    let sevenDaySonnet: WindowData?

    struct WindowData: Decodable {
        let utilization: Double    // 0-100 percentage USED
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Tolerate a present-but-null or missing utilization (e.g. an empty window object).
            utilization = (try? container.decodeIfPresent(Double.self, forKey: .utilization)) ?? 0
            resetsAt = (try? container.decodeIfPresent(String.self, forKey: .resetsAt)) ?? nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }

    func toServiceUsage() -> ServiceUsage {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var windows: [UsageWindow] = []
        if let fiveHour {
            windows.append(
                UsageWindow(
                    id: "five_hour",
                    name: "5-Hour",
                    compactLabel: "5h",
                    utilization: fiveHour.utilization / 100.0,
                    resetTime: parseResetDate(fiveHour.resetsAt, using: formatter)
                )
            )
        }
        if let sevenDay {
            windows.append(
                UsageWindow(
                    id: "seven_day",
                    name: "Weekly",
                    compactLabel: "w",
                    utilization: sevenDay.utilization / 100.0,
                    resetTime: parseResetDate(sevenDay.resetsAt, using: formatter)
                )
            )
        }

        // Opus/Sonnet weekly windows are shown as footer text only, so they never affect the
        // compact menu-bar (primary/secondary windows) or the badge color (worstLevel).
        var footerLines: [String] = []
        if let sevenDayOpus {
            footerLines.append("Weekly (Opus): \(remainingPercent(sevenDayOpus))% remaining")
        }
        if let sevenDaySonnet {
            footerLines.append("Weekly (Sonnet): \(remainingPercent(sevenDaySonnet))% remaining")
        }

        return ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: windows,
            lastUpdated: Date(),
            error: nil,
            footerLines: footerLines
        )
    }

    private func remainingPercent(_ window: WindowData) -> Int {
        max(0, Int((100.0 - window.utilization).rounded()))
    }

    private func parseResetDate(_ rawValue: String?, using formatter: ISO8601DateFormatter) -> Date? {
        guard let rawValue else { return nil }
        if let date = formatter.date(from: rawValue) {
            return date
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: rawValue)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClaudeUsageTests`
Expected: PASS, including the pre-existing `testClaudeUsageResponseParsesResetDatesWithoutFractionalSeconds` and `testClaudeUsageResponseParsesMixedResetDateFormatsIndependently`.

- [ ] **Step 5: Commit**

```bash
git add CodingAIUsage/Models/ClaudeUsageResponse.swift Tests/CodingAIUsageTests/ClaudeUsageTests.swift
git commit -m "feat: decode expanded nullable Claude usage windows; Opus/Sonnet as footer"
```

---

## Task 2: Send the required `claude-code` User-Agent header

**Files:**
- Modify: `CodingAIUsage/Services/ClaudeUsageService.swift`
- Test: `Tests/CodingAIUsageTests/ClaudeUsageTests.swift`

- [ ] **Step 1: Add a header-recorder and a failing test**

At the top of `Tests/CodingAIUsageTests/ClaudeUsageTests.swift`, next to the existing `URLRequestRecorder`, add:

```swift
private final class HeaderRecorder: @unchecked Sendable {
    var headers: [String: String] = [:]
}
```

Add this test method to `ClaudeUsageTests`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ClaudeUsageTests/testClaudeUsageRequestSendsClaudeCodeUserAgent`
Expected: FAIL — `recorder.headers["User-Agent"]` is `nil`.

- [ ] **Step 3: Add the User-Agent constant and set the header**

In `CodingAIUsage/Services/ClaudeUsageService.swift`, add the constant alongside the other `private let` endpoint properties (just below `oauthScopes`):

```swift
    private let userAgent = "claude-code/2.1.173"
```

In `performUsageRequest(accessToken:)`, after the existing `request.setValue("application/json", forHTTPHeaderField: "Accept")` line, add:

```swift
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
```

In `refreshCredentials(_:)`, after the existing `request.setValue("application/json", forHTTPHeaderField: "Content-Type")` line, add:

```swift
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ClaudeUsageTests/testClaudeUsageRequestSendsClaudeCodeUserAgent`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add CodingAIUsage/Services/ClaudeUsageService.swift Tests/CodingAIUsageTests/ClaudeUsageTests.swift
git commit -m "fix: send required claude-code User-Agent on Claude usage/refresh requests"
```

---

## Task 3: Make the Keychain/API path primary, CLI last-resort

**Files:**
- Modify: `CodingAIUsage/Services/ClaudeUsageService.swift:53-83` (`fetchUsage`)
- Test: `Tests/CodingAIUsageTests/ClaudeUsageTests.swift`

- [ ] **Step 1: Add a new ordering test and update the existing CLI-fallback test**

Add this test to `ClaudeUsageTests`:

```swift
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
```

Then update the existing `testClaudeUsageServicePrefersCLIWhenCredentialFileIsUnavailable` so the Keychain yields nothing (forcing the CLI fallback under the new ordering). Replace its body's loader construction:

Find:
```swift
        let loader = ClaudeCredentialLoader(
            homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
            keychainService: KeychainService()
        )
```
Replace with:
```swift
        let loader = ClaudeCredentialLoader(
            homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
            keychainService: .empty
        )
```
And rename the method to `testClaudeUsageServiceFallsBackToCLIWhenNoFileOrKeychainCredentials`.

- [ ] **Step 2: Run the tests to verify the new one fails**

Run: `swift test --filter ClaudeUsageTests/testClaudeUsageServicePrefersKeychainAPIOverCLI`
Expected: FAIL — current ordering runs the CLI first, so `XCTFail("CLI must not run...")` fires.

- [ ] **Step 3: Reorder `fetchUsage`**

In `CodingAIUsage/Services/ClaudeUsageService.swift`, replace the entire `fetchUsage()` method (currently lines 53–83) with:

```swift
    func fetchUsage() async throws -> ServiceUsage {
        if let fileCredentials = try credentialLoader.loadFileCredentials() {
            return try await fetchUsageViaAPI(
                startingWith: fileCredentials,
                credentialScope: .file
            )
        }

        if let keychainCredentials = try credentialLoader.loadKeychainCredentials() {
            return try await fetchUsageViaAPI(
                startingWith: keychainCredentials,
                credentialScope: .keychain
            )
        }

        // Last-resort fallback: scrape the CLI only when no token is available via file or Keychain.
        if let claudePath = claudeBinaryLocator() {
            return try fetchUsageViaCLI(binaryPath: claudePath)
        }

        throw UsageError.noCredentials("Claude Code: not logged in")
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClaudeUsageTests`
Expected: PASS, including `testClaudeUsageServiceFallsBackToCLIWhenNoFileOrKeychainCredentials` and `testClaudeUsageServiceDoesNotTriggerShellStartupForCLIProbe`.

- [ ] **Step 5: Commit**

```bash
git add CodingAIUsage/Services/ClaudeUsageService.swift Tests/CodingAIUsageTests/ClaudeUsageTests.swift
git commit -m "feat: prefer Keychain/JSON-API for Claude usage, CLI scraper last-resort"
```

---

## Task 4: Stop writing refreshed tokens back to the Keychain

**Files:**
- Modify: `CodingAIUsage/Services/ClaudeCredentialLoader.swift` (add `cacheRefreshedCredentials`)
- Modify: `CodingAIUsage/Services/ClaudeUsageService.swift:207` (refresh path)
- Test: `Tests/CodingAIUsageTests/ClaudeUsageTests.swift`

- [ ] **Step 1: Add a failing test**

Add this test to `ClaudeUsageTests`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ClaudeUsageTests/testClaudeUsageServiceDoesNotWriteRefreshedTokenBackToKeychain`
Expected: FAIL — `writeCounter.value` is `1` (current code calls `persist`, which writes to the Keychain).

- [ ] **Step 3: Add an in-memory-only cache method to the loader**

In `CodingAIUsage/Services/ClaudeCredentialLoader.swift`, add this method immediately after the `persist(_:)` method (after its closing brace, before `private var credentialFilePaths`):

```swift
    /// Updates the in-memory credential cache without writing to the Keychain or a file.
    /// Used after an in-flight OAuth refresh so subsequent polls reuse the fresh token
    /// while leaving the stored credential for the `claude` CLI to own.
    func cacheRefreshedCredentials(_ credentials: ClaudeCredentials) {
        cache(credentials)
    }
```

- [ ] **Step 4: Stop persisting on refresh**

In `CodingAIUsage/Services/ClaudeUsageService.swift`, inside `refreshCredentials(_:)`, replace:

```swift
        try credentialLoader.persist(updatedCredentials)
        return updatedCredentials
```
with:

```swift
        credentialLoader.cacheRefreshedCredentials(updatedCredentials)
        return updatedCredentials
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ClaudeUsageTests`
Expected: PASS, including `testClaudeUsageServiceRefreshesExpiredFileTokenBeforeFetchingUsage` and `testClaudeUsageServiceReloadsCredentialsAfter401AndRetriesOnce`.

- [ ] **Step 6: Commit**

```bash
git add CodingAIUsage/Services/ClaudeCredentialLoader.swift CodingAIUsage/Services/ClaudeUsageService.swift Tests/CodingAIUsageTests/ClaudeUsageTests.swift
git commit -m "fix: cache refreshed Claude token in memory instead of writing to Keychain"
```

---

## Task 5: Parse Claude's human-readable CLI reset format (fallback)

**Files:**
- Modify: `CodingAIUsage/Services/ClaudeCLIUsageParser.swift`
- Test: `Tests/CodingAIUsageTests/ClaudeUsageTests.swift`

- [ ] **Step 1: Add failing tests**

Add these tests to `ClaudeUsageTests`:

```swift
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
```

The pre-existing `testClaudeCLIUsageParserBuildsServiceUsageFromQuotaOutput` (ISO format) must keep passing.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClaudeUsageTests/testClaudeCLIUsageParserParsesHumanResetTimeSameDay`
Expected: FAIL to compile (`ClaudeCLIUsageParser(now:)` initializer does not exist yet).

- [ ] **Step 3: Add `now` injection and human-format parsing**

In `CodingAIUsage/Services/ClaudeCLIUsageParser.swift`, change the struct declaration and add an initializer at the top of the struct (immediately after `struct ClaudeCLIUsageParser {`):

```swift
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }
```

Then replace the existing `parseResetDate(from:)` method with the following (keeps ISO parsing, adds the human-readable branch and its helpers):

```swift
    private func parseResetDate(from line: String) -> Date? {
        if let isoDate = parseISOResetDate(from: line) {
            return isoDate
        }
        return parseHumanResetDate(from: line)
    }

    private func parseISOResetDate(from line: String) -> Date? {
        let pattern = #"(20[0-9]{2}-[0-9]{2}-[0-9]{2}T[^ ]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }

        let dateString = String(line[range])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }

    // Parses "Resets 9:40pm (Europe/Madrid)" or "Resets Nov 13, 2pm (America/New_York)".
    // No date token => the next occurrence of that local time (today if still future, else tomorrow).
    private func parseHumanResetDate(from line: String) -> Date? {
        guard let clock = parseClockTime(in: line) else { return nil }

        let timeZone = firstCaptureGroup(#"\(([A-Za-z]+/[A-Za-z_]+)\)"#, in: line)
            .flatMap { TimeZone(identifier: $0) } ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let nowDate = now()
        var components = calendar.dateComponents([.year, .month, .day], from: nowDate)
        components.hour = clock.hour
        components.minute = clock.minute
        components.second = 0

        let monthDay = parseMonthDay(in: line)
        if let monthDay {
            components.month = monthDay.month
            components.day = monthDay.day
        }

        guard var candidate = calendar.date(from: components) else { return nil }

        if monthDay == nil {
            if candidate <= nowDate {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
        } else if candidate < nowDate {
            // A dated reset already past this year resolves to next year.
            components.year = (components.year ?? 0) + 1
            candidate = calendar.date(from: components) ?? candidate
        }

        return candidate
    }

    private func parseClockTime(in line: String) -> (hour: Int, minute: Int)? {
        let pattern = #"([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let hourRange = Range(match.range(at: 1), in: line),
              var hour = Int(line[hourRange]),
              let meridiemRange = Range(match.range(at: 3), in: line) else {
            return nil
        }

        var minute = 0
        if let minuteRange = Range(match.range(at: 2), in: line), let parsed = Int(line[minuteRange]) {
            minute = parsed
        }

        let meridiem = line[meridiemRange].lowercased()
        if meridiem == "pm" && hour != 12 { hour += 12 }
        if meridiem == "am" && hour == 12 { hour = 0 }

        return (hour, minute)
    }

    private func parseMonthDay(in line: String) -> (month: Int, day: Int)? {
        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        let pattern = #"([A-Za-z]{3})[a-z]*\s+([0-9]{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let monthRange = Range(match.range(at: 1), in: line),
              let dayRange = Range(match.range(at: 2), in: line),
              let monthIndex = months.firstIndex(of: line[monthRange].lowercased()),
              let day = Int(line[dayRange]) else {
            return nil
        }
        return (month: monthIndex + 1, day: day)
    }

    private func firstCaptureGroup(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClaudeUsageTests`
Expected: PASS, including the pre-existing ISO test `testClaudeCLIUsageParserBuildsServiceUsageFromQuotaOutput`.

- [ ] **Step 5: Commit**

```bash
git add CodingAIUsage/Services/ClaudeCLIUsageParser.swift Tests/CodingAIUsageTests/ClaudeUsageTests.swift
git commit -m "fix: parse Claude CLI human-readable reset times in fallback parser"
```

---

## Task 6: Create `sign.sh` (stable self-signed signing)

**Files:**
- Create: `sign.sh`
- Create: `Tests/sign_sh_test.sh`

- [ ] **Step 1: Write the shell test**

Create `Tests/sign_sh_test.sh`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGN_SCRIPT="${SCRIPT_DIR}/../sign.sh"

[[ -f "${SIGN_SCRIPT}" ]] || { echo "sign.sh is missing"; exit 1; }
[[ -x "${SIGN_SCRIPT}" ]] || { echo "sign.sh is not executable"; exit 1; }

grep -q 'codesign --force' "${SIGN_SCRIPT}" || { echo "expected 'codesign --force' in sign.sh"; exit 1; }
grep -q 'SIGN_IDENTITY' "${SIGN_SCRIPT}" || { echo "expected overridable SIGN_IDENTITY in sign.sh"; exit 1; }
grep -q 'find-identity' "${SIGN_SCRIPT}" || { echo "expected an identity-existence check in sign.sh"; exit 1; }

# With a guaranteed-missing identity the script must fail loudly (missing bundle or missing identity).
if SIGN_IDENTITY="nonexistent-identity-$$" bash "${SIGN_SCRIPT}" >/dev/null 2>&1; then
    echo "expected sign.sh to exit non-zero for a missing identity"
    exit 1
fi

echo "sign.sh checks passed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash Tests/sign_sh_test.sh`
Expected: FAIL with "sign.sh is missing".

- [ ] **Step 3: Write `sign.sh`**

Create `sign.sh`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="Coding AI Usage"
APP_BUNDLE="${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-Coding AI Usage Self-Signed}"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "error: ${APP_BUNDLE} not found. Run ./build.sh first." >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -qF "${SIGN_IDENTITY}"; then
    cat >&2 <<EOF
error: code-signing identity "${SIGN_IDENTITY}" not found.

A stable identity is required so the macOS Keychain "Always Allow" grant
persists across rebuilds. Create a free self-signed identity once:

  1. Open Keychain Access.app
  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate...
  3. Name:            ${SIGN_IDENTITY}
     Identity Type:   Self Signed Root
     Certificate Type: Code Signing
  4. Click Create, then keep it in the "login" keychain.

Already have an Apple Developer ID? Re-run with:
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
EOF
    exit 1
fi

echo "Signing ${APP_BUNDLE} with \"${SIGN_IDENTITY}\"..."
codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
codesign --verify --strict --verbose=2 "${APP_BUNDLE}"
echo "Signed ${APP_BUNDLE} (stable identity: ${SIGN_IDENTITY})."
```

Then make it executable:

```bash
chmod +x sign.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash Tests/sign_sh_test.sh`
Expected: PASS — "sign.sh checks passed".

- [ ] **Step 5: Commit**

```bash
git add sign.sh Tests/sign_sh_test.sh
git commit -m "feat: add sign.sh for stable self-signed code signing"
```

---

## Task 7: Invoke `sign.sh` from `build.sh`

**Files:**
- Modify: `build.sh`
- Create: `Tests/build_sh_test.sh`

- [ ] **Step 1: Write the shell test**

Create `Tests/build_sh_test.sh`:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/../build.sh"

cp_line="$(grep -n 'cp .build-release/release/CodingAIUsage' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"
sign_line="$(grep -n 'sign.sh' "${BUILD_SCRIPT}" | cut -d: -f1 || true)"

[[ -n "${cp_line}" ]] || { echo "expected executable copy step in build.sh"; exit 1; }
[[ -n "${sign_line}" ]] || { echo "expected sign.sh invocation in build.sh"; exit 1; }
[[ "${sign_line}" -gt "${cp_line}" ]] || { echo "expected signing after bundle assembly"; exit 1; }

echo "build.sh signing wiring looks correct"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash Tests/build_sh_test.sh`
Expected: FAIL with "expected sign.sh invocation in build.sh".

- [ ] **Step 3: Add the signing step to `build.sh`**

In `build.sh`, replace this block:

```bash
echo ""
echo "Build complete: ${APP_BUNDLE}"
echo ""
echo "Bundle ready: ${APP_BUNDLE}"
echo "Use ./deploy.sh to install it to /Applications and launch it."
```
with:

```bash
# Sign with a stable identity so the Keychain "Always Allow" grant survives rebuilds.
"${SCRIPT_DIR}/sign.sh"

echo ""
echo "Build complete: ${APP_BUNDLE}"
echo ""
echo "Bundle ready: ${APP_BUNDLE}"
echo "Use ./deploy.sh to install it to /Applications and launch it."
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash Tests/build_sh_test.sh`
Expected: PASS — "build.sh signing wiring looks correct".

- [ ] **Step 5: Commit**

```bash
git add build.sh Tests/build_sh_test.sh
git commit -m "feat: sign the app bundle as the final build.sh step"
```

---

## Task 8: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the one-time signing setup**

In `README.md`, under the "Prerequisites" table, add a new row after the **Xcode Command Line Tools** row:

```markdown
| **Self-signed code-signing cert** (build-from-source only) | `security find-identity -v -p codesigning \| grep "Coding AI Usage Self-Signed"` | See "Code Signing" below |
```

- [ ] **Step 2: Add a "Code Signing" section**

In `README.md`, immediately before the "## Installation" section, add:

```markdown
## Code Signing (one-time, build-from-source)

The app reads your Claude Code OAuth token from the macOS Keychain. macOS ties a
"Always Allow" Keychain grant to the app's code-signing identity, so an **unsigned/ad-hoc**
build is treated as a new app on every rebuild and re-prompts you each time. `build.sh` signs
the bundle with a **stable self-signed identity** so the grant persists.

Create the identity once (free, no Apple Developer account):

1. Open **Keychain Access.app**
2. Menu: **Keychain Access > Certificate Assistant > Create a Certificate…**
3. Name: `Coding AI Usage Self-Signed` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing**
4. Click **Create** and keep it in the **login** keychain.

If you have an Apple Developer ID, use it instead:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./deploy.sh
```

The first refresh after switching identities prompts once for Keychain access — click
**"Always Allow"** and it will stick across all future rebuilds.
```

- [ ] **Step 3: Correct the "How It Works" credential notes**

In `README.md`, in the "How It Works" section, replace this bullet:

```markdown
- **No passwords or API keys are stored by the app** - it reads existing credentials that the CLI tools have already saved
```
with:

```markdown
- **No passwords or API keys are stored by the app** - it reads existing credentials that the CLI tools have already saved
- **The app never writes to the Keychain** - if the Claude OAuth token needs refreshing, the app refreshes it in memory for that request only and lets the `claude` CLI own the stored token
- **Claude usage comes from the JSON API** (`api.anthropic.com/api/oauth/usage`) sent with a `claude-code` User-Agent; the `claude /usage` CLI screen is only scraped as a last-resort fallback when no token is available
```

- [ ] **Step 4: Note expanded Claude windows in the dropdown**

In `README.md`, in the "Dropdown Panel" subsection, add this bullet after the "Reset timers" bullet:

```markdown
- **Weekly Opus / Sonnet** sub-limits shown as footer lines under Claude Code when your plan reports them
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document self-signed signing, no Keychain write-back, expanded windows"
```

---

## Final verification

- [ ] **Run the full test suite**

Run: `swift test`
Expected: all tests PASS (no `XCTSkip` failures count as failures).

- [ ] **Run the shell tests**

Run: `bash Tests/sign_sh_test.sh && bash Tests/build_sh_test.sh && bash Tests/deploy_sh_test.sh`
Expected: all three print their success lines.

- [ ] **Build, sign, and smoke-test manually**

Run: `./build.sh`
Expected: completes and `codesign -dvvv "Coding AI Usage.app"` reports the self-signed authority (NOT `Signature=adhoc`). (Requires the one-time cert from Task 8 / README.)

Then: `./deploy.sh`, click **Refresh**, click **"Always Allow"** on the one Keychain prompt, confirm the Claude row shows a reset countdown. Run `./deploy.sh` again and confirm **no** new Keychain prompt appears.

---

## Self-review notes (spec coverage)

- Spec Part A (stable signing) → Tasks 6, 7, 8.
- Spec Part B (API primary, User-Agent, expanded nullable windows, reset restored) → Tasks 1, 2, 3.
- Spec Part C (no Keychain write-back) → Task 4.
- Spec Part D (CLI fallback human reset parsing) → Task 5.
- Opus/Sonnet rendered as **footer lines** (not `windows`) to honor "menu bar unchanged": `primaryWindow`/`secondaryWindow` and `worstLevel` operate only on `windows`, so the compact display and badge color are unaffected. `seven_day_oauth_apps`, `seven_day_routines`, and `extra_usage` are intentionally ignored (unknown keys decode tolerantly to `nil`); this is the agreed tolerant-decoding approach and stays out of scope for display.
