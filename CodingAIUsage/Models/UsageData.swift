import SwiftUI

enum UsageLevel: Comparable {
    case normal
    case warning
    case critical

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}

struct UsageWindow: Identifiable {
    let id: String
    let name: String
    let utilization: Double // 0.0 to 1.0 (percentage USED)
    let resetTime: Date?

    var remaining: Double { max(0, 1.0 - utilization) }
    var remainingPercent: Int { Int(remaining * 100) }

    var level: UsageLevel {
        if remaining < 0.10 { return .critical }
        if remaining < 0.30 { return .warning }
        return .normal
    }
}

struct ServiceUsage: Identifiable {
    let id: String
    let displayName: String
    let shortLabel: String
    let windows: [UsageWindow]
    let lastUpdated: Date
    let error: String?

    var worstLevel: UsageLevel {
        windows.map(\.level).max() ?? .normal
    }

    var fiveHourWindow: UsageWindow? {
        windows.first { $0.id.contains("five") || $0.id.contains("5h") }
    }

    var weeklyWindow: UsageWindow? {
        windows.first { $0.id.contains("seven") || $0.id.contains("week") }
    }
}

enum UsageError: Error, LocalizedError {
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
