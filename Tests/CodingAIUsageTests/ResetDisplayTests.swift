import XCTest
@testable import CodingAIUsage

final class ResetDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_735_960) // 2026-09-06T21:06:00Z

    func testFutureResetRendersAsCountdown() {
        let inOneHour = now.addingTimeInterval(3600)
        XCTAssertEqual(ResetDisplay.mode(for: inOneHour, now: now), .countdown)
    }

    func testResetJustSecondsAwayStillCountsDown() {
        XCTAssertEqual(ResetDisplay.mode(for: now.addingTimeInterval(1), now: now), .countdown)
    }

    func testElapsedResetDoesNotRenderAsCountdown() {
        // The exact regression: the stale Windsurf source stored a daily reset of 2026-06-04,
        // which the UI displayed as "Resets 3 mths, 2 days" — elapsed time shown as remaining.
        let june4 = Date(timeIntervalSince1970: 1_780_905_600) // 2026-06-04T08:00:00Z
        XCTAssertEqual(ResetDisplay.mode(for: june4, now: now), .overdue)
    }

    func testResetOneSecondAgoIsOverdue() {
        XCTAssertEqual(ResetDisplay.mode(for: now.addingTimeInterval(-1), now: now), .overdue)
    }

    func testResetExactlyNowIsOverdue() {
        // A reset at exactly `now` has fired; counting down to it would show "0 seconds" forever.
        XCTAssertEqual(ResetDisplay.mode(for: now, now: now), .overdue)
    }

    func testLiveDevinResetsAreOverdueButThatIsNotStaleness() {
        // The live Devin proto legitimately carries elapsed resets (daily 2026-09-04, weekly
        // 2026-09-06) while its billing period is still open. They must render as overdue rather
        // than as a countdown — and that is a display concern, not a freshness one.
        let sept4 = Date(timeIntervalSince1970: 1_788_508_800)  // 2026-09-04T08:00:00Z
        let sept6 = Date(timeIntervalSince1970: 1_788_681_600)  // 2026-09-06T08:00:00Z
        XCTAssertEqual(ResetDisplay.mode(for: sept4, now: now), .overdue)
        XCTAssertEqual(ResetDisplay.mode(for: sept6, now: now), .overdue)
    }
}
