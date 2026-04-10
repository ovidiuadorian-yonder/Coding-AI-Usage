import SwiftUI

enum UsageLevel: Comparable {
    case normal
    case warning
    case critical

    var statusText: String {
        switch self {
        case .normal: return "Healthy"
        case .warning: return "Low"
        case .critical: return "Critical"
        }
    }

    var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}

struct UsageWindow: Identifiable, Codable {
    let id: String
    let name: String
    let compactLabel: String
    let utilization: Double // 0.0 to 1.0 (percentage USED)
    let resetTime: Date?

    init(id: String, name: String, compactLabel: String? = nil, utilization: Double, resetTime: Date?) {
        self.id = id
        self.name = name
        self.compactLabel = compactLabel ?? UsageWindow.defaultCompactLabel(for: id, name: name)
        self.utilization = utilization
        self.resetTime = resetTime
    }

    var remaining: Double { max(0, 1.0 - utilization) }
    var remainingPercent: Int { Int(remaining * 100) }

    var level: UsageLevel {
        if remaining < 0.10 { return .critical }
        if remaining < 0.30 { return .warning }
        return .normal
    }

    private static func defaultCompactLabel(for id: String, name: String) -> String {
        let lowered = "\(id) \(name)".lowercased()
        if lowered.contains("five") || lowered.contains("5h") {
            return "5h"
        }
        if lowered.contains("daily") {
            return "d"
        }
        return "w"
    }
}

struct ServiceUsage: Identifiable, Codable {
    let id: String
    let displayName: String
    let shortLabel: String
    let windows: [UsageWindow]
    let lastUpdated: Date
    let error: String?
    let footerLines: [String]

    init(
        id: String,
        displayName: String,
        shortLabel: String,
        windows: [UsageWindow],
        lastUpdated: Date,
        error: String?,
        footerLines: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.shortLabel = shortLabel
        self.windows = windows
        self.lastUpdated = lastUpdated
        self.error = error
        self.footerLines = footerLines
    }

    var worstLevel: UsageLevel {
        windows.map(\.level).max() ?? .normal
    }

    var primaryWindow: UsageWindow? {
        windows.first
    }

    var secondaryWindow: UsageWindow? {
        windows.dropFirst().first
    }

    var fiveHourWindow: UsageWindow? {
        windows.first { $0.id.contains("five") || $0.id.contains("5h") || $0.compactLabel == "5h" }
    }

    var weeklyWindow: UsageWindow? {
        windows.first { $0.id.contains("seven") || $0.id.contains("week") || $0.compactLabel == "w" }
    }
}

enum UsageError: Error, LocalizedError, Equatable {
    case noCredentials(String)
    case notInstalled(String)
    case rateLimited(retryAfter: TimeInterval?)
    case authExpired(String)
    case httpError(Int)
    case networkError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials(let msg): return msg
        case .notInstalled(let msg): return msg
        case .rateLimited: return "Rate limited - backing off"
        case .authExpired(let msg): return msg
        case .httpError(let code): return "HTTP error \(code)"
        case .networkError(let msg): return msg
        case .invalidResponse: return "Invalid response"
        }
    }
}
