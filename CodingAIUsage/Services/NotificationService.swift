import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var lastAlerts: [String: Date] = [:]
    private var previouslyBelowThreshold: [String: Bool] = [:]
    private let cooldownInterval: TimeInterval = 1800  // 30 minutes

    private var permissionGranted = false

    func requestPermission() {
        // UNUserNotificationCenter requires a proper app bundle
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor [weak self] in
                self?.permissionGranted = granted
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func checkAndNotify(service: ServiceUsage, threshold: Double = 0.10) {
        for window in service.windows {
            let key = "\(service.id)_\(window.id)"
            let isBelowThreshold = window.remaining < threshold
            let wasBelowThreshold = previouslyBelowThreshold[key] ?? false
            if !isBelowThreshold {
                previouslyBelowThreshold[key] = false
                continue
            }

            // Only fire on transition into below-threshold (not every poll while below)
            guard isBelowThreshold && !wasBelowThreshold else { continue }

            // Check cooldown
            if let lastAlert = lastAlerts[key],
                Date().timeIntervalSince(lastAlert) < cooldownInterval
            {
                continue
            }

            guard sendNotification(service: service, window: window) else { continue }
            previouslyBelowThreshold[key] = true
            lastAlerts[key] = Date()
        }
    }

    func resetTracking(for serviceId: String) {
        let keysToRemove = previouslyBelowThreshold.keys.filter { $0.hasPrefix(serviceId) }
        for key in keysToRemove {
            previouslyBelowThreshold.removeValue(forKey: key)
            lastAlerts.removeValue(forKey: key)
        }
    }

    private func sendNotification(service: ServiceUsage, window: UsageWindow) -> Bool {
        guard permissionGranted, Bundle.main.bundleIdentifier != nil else { return false }
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
        return true
    }
}
