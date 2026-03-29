import XCTest
@testable import CodingAIUsage

final class MenuBarLabelTests: XCTestCase {
    func testUsageWindowCompactLabelsDriveMenuText() {
        let claude = ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [
                UsageWindow(id: "five_hour", name: "5-Hour", compactLabel: "5h", utilization: 0.50, resetTime: nil),
                UsageWindow(id: "seven_day", name: "Weekly", compactLabel: "w", utilization: 0.37, resetTime: nil)
            ],
            lastUpdated: .distantPast,
            error: nil
        )
        let windsurf = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [
                UsageWindow(id: "daily", name: "Daily", compactLabel: "d", utilization: 0.01, resetTime: nil),
                UsageWindow(id: "weekly", name: "Weekly", compactLabel: "w", utilization: 0.19, resetTime: nil)
            ],
            lastUpdated: .distantPast,
            error: nil
        )

        let parts = MenuBarLabel.menuBarParts(
            services: [
                .init(usage: claude, isVisible: true, badgeColor: nil),
                .init(usage: windsurf, isVisible: true, badgeColor: nil)
            ]
        )

        XCTAssertEqual(parts.map(\.label), ["CC", "W"])
        XCTAssertEqual(parts[0].primaryLabel, "5h")
        XCTAssertEqual(parts[1].primaryLabel, "d")
        XCTAssertEqual(parts[1].primaryPercent, 99)
        XCTAssertEqual(parts[1].secondaryLabel, "w")
        XCTAssertEqual(parts[1].secondaryPercent, 81)
    }

    func testUnavailableWindsurfStillAppearsInMenuBarWithPlaceholders() {
        let windsurf = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [],
            lastUpdated: .distantPast,
            error: "Windsurf: daily/weekly quota unavailable"
        )

        let parts = MenuBarLabel.menuBarParts(
            services: [
                .init(usage: windsurf, isVisible: true, badgeColor: nil)
            ]
        )

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].label, "W")
        XCTAssertEqual(parts[0].primaryLabel, "d")
        XCTAssertEqual(parts[0].primaryText, "--")
        XCTAssertEqual(parts[0].secondaryLabel, "w")
        XCTAssertEqual(parts[0].secondaryText, "--")
    }

    func testUnavailableClaudeDoesNotAppearInMenuBar() {
        let claude = ServiceUsage(
            id: "claude",
            displayName: "Claude Code",
            shortLabel: "CC",
            windows: [],
            lastUpdated: .distantPast,
            error: "Claude Code: not logged in"
        )

        let parts = MenuBarLabel.menuBarParts(
            services: [
                .init(usage: claude, isVisible: true, badgeColor: nil)
            ]
        )

        XCTAssertTrue(parts.isEmpty)
    }
}
