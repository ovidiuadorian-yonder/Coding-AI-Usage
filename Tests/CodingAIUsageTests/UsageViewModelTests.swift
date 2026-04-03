import XCTest
@testable import CodingAIUsage

@MainActor
final class UsageViewModelTests: XCTestCase {
    func testGlobalErrorsExcludeServiceSpecificErrors() {
        let windsurf = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [],
            lastUpdated: .distantPast,
            error: "Windsurf: daily/weekly quota unavailable"
        )

        let errors = UsageViewModel.filteredGlobalErrors(
            allErrors: ["Windsurf: daily/weekly quota unavailable", "Codex: rate limited"],
            services: [windsurf]
        )

        XCTAssertEqual(errors, ["Codex: rate limited"])
    }

    func testRetryingFetchClearsPreviousServiceErrorUsage() {
        let previous = ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [],
            lastUpdated: .distantPast,
            error: "Claude Code: session expired - please re-login in Claude Code"
        )

        XCTAssertNil(UsageViewModel.retryingFetchUsage(previous: previous))
    }

    func testRetryingFetchKeepsPreviousHealthyUsage() {
        let previous = ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [
                UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.50, resetTime: nil)
            ],
            lastUpdated: .distantPast,
            error: nil
        )

        XCTAssertEqual(UsageViewModel.retryingFetchUsage(previous: previous)?.error, nil)
        XCTAssertEqual(UsageViewModel.retryingFetchUsage(previous: previous)?.windows.count, 1)
    }

    func testWindsurfFailureUsageClearsPreviousQuotaWindows() {
        let previous = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [
                UsageWindow(id: "daily", name: "Daily", compactLabel: "d", utilization: 0.01, resetTime: nil),
                UsageWindow(id: "weekly", name: "Weekly", compactLabel: "w", utilization: 0.19, resetTime: nil)
            ],
            lastUpdated: .distantPast,
            error: nil,
            footerLines: ["Plan ends Apr 22, 2026", "$1371.44"]
        )

        let usage = UsageViewModel.windsurfFailureUsage(
            message: "Windsurf: unexpected local state format",
            previous: previous
        )

        XCTAssertEqual(usage.error, "Windsurf: unexpected local state format")
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertTrue(usage.footerLines.isEmpty)
    }

    func testClaudePrerequisitesTreatInstalledBinaryAsReadyWithoutCredentialFile() {
        let status = UsageViewModel.claudePrerequisiteStatus(
            isInstalled: true,
            hasCredentialFile: false
        )

        XCTAssertTrue(status.installed)
        XCTAssertTrue(status.loggedIn)
        XCTAssertNil(status.error)
    }

    func testManualRefreshInvalidatesClaudeCredentialCache() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-manual-refresh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json")
        try? FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":9999999999999}}"#
            .write(to: filePath, atomically: true, encoding: .utf8)

        var invalidationCount = 0
        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            onInvalidate: { invalidationCount += 1 }
        )
        let claudeService = ClaudeUsageService(
            credentialLoader: loader,
            networkClient: { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = Data(#"{"five_hour":{"utilization":20,"resets_at":"2026-04-03T18:00:00.000Z"},"seven_day":{"utilization":40,"resets_at":"2026-04-08T18:00:00.000Z"}}"#.utf8)
                return (data, response)
            },
            cliExecutor: { _, _ in .init(exitCode: 1, output: "") },
            claudeBinaryLocator: { false }
        )

        let viewModel = UsageViewModel(
            claudeService: claudeService,
            autostart: false
        )
        viewModel.showCodex = false
        viewModel.showWindsurf = false

        _ = try? loader.loadAnyCredentials()
        XCTAssertEqual(loader.cacheState.cachedAccessToken, "file-token")

        await viewModel.performManualRefresh(forceLiveWindsurf: false)

        XCTAssertEqual(invalidationCount, 1)
    }
}
