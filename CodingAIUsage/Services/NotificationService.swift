import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private var lastAlerts: [String: Date] = [:]
    private var previousLevels: [String: UsageLevel] = [:]
    private let cooldownInterval: TimeInterval = 1800 // 30 minutes

    private var permissionGranted = false

    func requestPermission() {
        // UNUserNotificationCenter requires a proper app bundle
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor [weak self] in
                self?.permissionGranted = granted
            }
        }
    }

    func checkAndNotify(service: ServiceUsage, threshold: Double = 0.10) {
        for window in service.windows {
            let key = "\(service.id)_\(window.id)"
            let isCritical = window.remaining < threshold
            let wasCritical = previousLevels[key] == .critical

            previousLevels[key] = window.level

            // Only fire on transition into critical (not every poll while critical)
            guard isCritical && !wasCritical else { continue }

            // Check cooldown
            if let lastAlert = lastAlerts[key],
               Date().timeIntervalSince(lastAlert) < cooldownInterval {
                continue
            }

            sendNotification(service: service, window: window)
            lastAlerts[key] = Date()
        }
    }

    func resetTracking(for serviceId: String) {
        let keysToRemove = previousLevels.keys.filter { $0.hasPrefix(serviceId) }
        for key in keysToRemove {
            previousLevels.removeValue(forKey: key)
            lastAlerts.removeValue(forKey: key)
        }
    }

    private func sendNotification(service: ServiceUsage, window: UsageWindow) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Coding AI Usage - \(service.displayName)"

        var body = "\(window.name) usage at \(window.remainingPercent)% remaining."
        if let resetTime = window.resetTime {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            body += " Resets at \(formatter.string(from: resetTime))."
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(service.id)_\(window.id)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
