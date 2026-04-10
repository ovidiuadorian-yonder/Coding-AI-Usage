import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    typealias PermissionRequestHandler = (@escaping (Bool) -> Void) -> Void

    private var lastAlerts: [String: Date] = [:]
    private var previouslyBelowThreshold: [String: Bool] = [:]
    private let cooldownInterval: TimeInterval = 1800  // 30 minutes

    private var permissionGranted = false
    private let requestPermissionHandler: PermissionRequestHandler
    private let configureAuthorizationHandler: (NotificationService) -> Void
    private let addRequestHandler: (UNNotificationRequest) -> Void
    private let bundleIdentifierProvider: () -> String?

    init(
        requestPermissionHandler: @escaping PermissionRequestHandler = { completion in
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                completion(granted)
            }
        },
        configureAuthorizationHandler: @escaping (NotificationService) -> Void = { service in
            UNUserNotificationCenter.current().delegate = service
        },
        addRequestHandler: @escaping (UNNotificationRequest) -> Void = { request in
            UNUserNotificationCenter.current().add(request)
        },
        bundleIdentifierProvider: @escaping () -> String? = { Bundle.main.bundleIdentifier }
    ) {
        self.requestPermissionHandler = requestPermissionHandler
        self.configureAuthorizationHandler = configureAuthorizationHandler
        self.addRequestHandler = addRequestHandler
        self.bundleIdentifierProvider = bundleIdentifierProvider
    }

    func requestPermission() {
        // UNUserNotificationCenter requires a proper app bundle
        guard bundleIdentifierProvider() != nil else { return }
        configureAuthorizationHandler(self)
        requestPermissionHandler { granted in
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
        guard permissionGranted, bundleIdentifierProvider() != nil else { return false }
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

        addRequestHandler(request)
        return true
    }
}
