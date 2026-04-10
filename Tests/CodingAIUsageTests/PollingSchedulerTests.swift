import XCTest
@testable import CodingAIUsage

@MainActor
final class PollingSchedulerTests: XCTestCase {
    func testStartUsesReturnedIntervalForNextRun() {
        let scheduler = PollingScheduler(interval: 0.3)
        let secondFire = expectation(description: "second fire")
        var fireDates: [Date] = []

        scheduler.start {
            fireDates.append(Date())
            if fireDates.count == 2 {
                secondFire.fulfill()
            }
            return fireDates.count == 1 ? 0.05 : nil
        }

        wait(for: [secondFire], timeout: 1.0)
        scheduler.stop()

        XCTAssertEqual(fireDates.count, 2)
        XCTAssertLessThan(fireDates[1].timeIntervalSince(fireDates[0]), 0.20)
    }

    func testUpdateBaseIntervalReschedulesActiveTimerImmediately() {
        let scheduler = PollingScheduler(interval: 0.4)
        let secondFire = expectation(description: "second fire")
        var fireDates: [Date] = []

        scheduler.start {
            fireDates.append(Date())
            if fireDates.count == 1 {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    scheduler.updateBaseInterval(0.05)
                }
            } else if fireDates.count == 2 {
                secondFire.fulfill()
            }
            return nil
        }

        wait(for: [secondFire], timeout: 1.0)
        scheduler.stop()

        XCTAssertEqual(fireDates.count, 2)
        XCTAssertLessThan(fireDates[1].timeIntervalSince(fireDates[0]), 0.20)
    }
}
