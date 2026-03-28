import Foundation

@MainActor
final class PollingScheduler: ObservableObject {
    private var timer: Timer?
    private var baseInterval: TimeInterval
    private var currentInterval: TimeInterval
    private let maxInterval: TimeInterval = 1800 // 30 min cap

    init(interval: TimeInterval = 300) {
        self.baseInterval = interval
        self.currentInterval = interval
    }

    func start(action: @escaping @MainActor () async -> Void) {
        stop()
        // Fire immediately on start
        Task { @MainActor in
            await action()
        }
        scheduleNext(action: action)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reportSuccess() {
        currentInterval = baseInterval
    }

    func reportRateLimited(retryAfter: TimeInterval?) {
        if let retryAfter {
            // Cap retry-after to maxInterval to avoid absurdly long waits
            currentInterval = min(retryAfter + 30, maxInterval)
        } else {
            currentInterval = min(currentInterval * 2, maxInterval)
        }
    }

    func resetBackoff() {
        currentInterval = baseInterval
    }

    func updateBaseInterval(_ interval: TimeInterval) {
        baseInterval = interval
        currentInterval = interval
    }

    private func scheduleNext(action: @escaping @MainActor () async -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await action()
                self.scheduleNext(action: action)
            }
        }
    }
}
