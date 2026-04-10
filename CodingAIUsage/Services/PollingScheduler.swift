import Foundation

@MainActor
final class PollingScheduler: ObservableObject {
    typealias ScheduledAction = @MainActor () async -> TimeInterval?

    private var timer: Timer?
    private var action: ScheduledAction?
    private var baseInterval: TimeInterval
    private var currentInterval: TimeInterval

    init(interval: TimeInterval = 300) {
        self.baseInterval = interval
        self.currentInterval = interval
    }

    func start(action: @escaping ScheduledAction) {
        stop()
        self.action = action

        Task { @MainActor [weak self] in
            await self?.runActionAndSchedule()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        action = nil
    }

    func resetBackoff() {
        reschedule(after: baseInterval)
    }

    func updateBaseInterval(_ interval: TimeInterval) {
        baseInterval = interval
        if action != nil {
            reschedule(after: interval)
        } else {
            currentInterval = interval
        }
    }

    func reschedule(after interval: TimeInterval?) {
        currentInterval = interval ?? baseInterval
        guard action != nil else { return }
        scheduleTimer(after: currentInterval)
    }

    private func runActionAndSchedule() async {
        guard let action else { return }
        let nextInterval = await action() ?? baseInterval
        scheduleTimer(after: nextInterval)
    }

    private func scheduleTimer(after interval: TimeInterval) {
        timer?.invalidate()
        currentInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runActionAndSchedule()
            }
        }
    }
}
