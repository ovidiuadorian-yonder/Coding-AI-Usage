import XCTest
@testable import CodingAIUsage

final class NotificationServiceTests: XCTestCase {
    @MainActor
    func testNotificationTrackingDoesNotAdvanceBeforePermissionIsAvailable() {
        let service = NotificationService()
        let usage = ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [
                UsageWindow(id: "daily", name: "Daily", compactLabel: "d", utilization: 0.95, resetTime: nil)
            ],
            lastUpdated: .distantPast,
            error: nil
        )

        service.checkAndNotify(service: usage, threshold: 0.10)

        let mirror = Mirror(reflecting: service)
        let lastAlerts = mirror.descendant("lastAlerts") as? [String: Date]
        let belowThreshold = mirror.descendant("previouslyBelowThreshold") as? [String: Bool]

        XCTAssertEqual(lastAlerts, [:])
        XCTAssertEqual(belowThreshold, [:])
    }
}
