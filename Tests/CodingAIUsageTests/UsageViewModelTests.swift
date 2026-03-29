import XCTest
@testable import CodingAIUsage

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
}
