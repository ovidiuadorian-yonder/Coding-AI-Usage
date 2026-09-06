import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

protocol WindsurfUsageServing: Sendable {
    func fetchUsage() async throws -> ServiceUsage
    func checkInstalled() async -> Bool
    func isLoggedIn() async -> Bool
}

actor WindsurfUsageService: WindsurfUsageServing {
    /// Resolves the state database to read, or nil when no supported client is installed.
    typealias StateDBLocator = @Sendable () -> String?

    /// Windsurf was rebranded to Devin. The client is the same VS Code fork — the bundle id is
    /// still `com.exafunction.windsurf` and the state keys are unchanged — so only the label and
    /// the directory move.
    ///
    /// `serviceID` deliberately stays `"windsurf"`: it keys the persisted usage snapshot and the
    /// `showWindsurf` visibility preference, so renaming it would discard the user's cached data
    /// and reset their settings on upgrade. Internal identifier and user-facing label are
    /// decoupled on purpose.
    static let serviceID = "windsurf"
    static let displayName = "Devin"
    static let shortLabel = "D"

    /// Application-support directories to probe, in tie-break order.
    static let clientSupportDirectories = ["Devin", "Windsurf"]

    private let stateDBLocator: StateDBLocator
    private let now: @Sendable () -> Date

    init(
        stateDBLocator: @escaping StateDBLocator = {
            WindsurfUsageService.defaultStateDBLocator()
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.stateDBLocator = stateDBLocator
        self.now = now
    }

    /// Picks the state database with the newest modification time across every supported client
    /// directory, so the app follows the client actually in use.
    ///
    /// Freshness rather than a fixed Devin-first priority: it is correct in both directions — a
    /// user who has not migrated keeps working, and one who rolls back is not pinned to a stale
    /// Devin database. Ties resolve to Devin by the ordering of `clientSupportDirectories`.
    static func defaultStateDBLocator(homeDirectory: String = NSHomeDirectory()) -> String? {
        let fileManager = FileManager.default
        let candidates: [(path: String, modified: Date)] = clientSupportDirectories.compactMap { directory in
            let path = homeDirectory
                + "/Library/Application Support/\(directory)/User/globalStorage/state.vscdb"
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else {
                return nil
            }
            return (path, modified)
        }

        return candidates.max { lhs, rhs in
            // `max(by:)` keeps the later element when the comparator reports "not greater", so a
            // strict `<` preserves the earlier candidate on a tie — Devin, given the array order.
            lhs.modified < rhs.modified
        }?.path
    }

    func fetchUsage() async throws -> ServiceUsage {
        guard let authStatus = try readAuthStatus(), !authStatus.apiKey.isEmpty else {
            throw UsageError.noCredentials("\(Self.displayName): not logged in")
        }

        let planInfo = try readCachedPlanInfo()
        let lastUpdated = now()

        let snapshot = try
            readStructuredSnapshot(authStatus: authStatus, planInfo: planInfo) ??
            planInfo?.quotaSnapshot

        guard let snapshot, isFresh(planEnd: snapshot.planEndDate) else {
            return ServiceUsage(
                id: Self.serviceID,
                displayName: Self.displayName,
                shortLabel: Self.shortLabel,
                windows: [],
                lastUpdated: lastUpdated,
                error: "\(Self.displayName): daily/weekly quota unavailable",
                footerLines: []
            )
        }

        return snapshot.toServiceUsage(lastUpdated: lastUpdated)
    }

    /// A source is stale when its own billing period has already ended.
    ///
    /// Reset timestamps are deliberately not consulted. The proto stores the reset from the
    /// client's last quota sync rather than the next one, so a perfectly current source routinely
    /// carries elapsed daily and weekly resets; treating those as staleness would discard live
    /// data. A source carrying no plan end cannot be judged and is retained — the gate demotes
    /// sources proven stale, it does not demand proof of freshness.
    private func isFresh(planEnd: Date?) -> Bool {
        guard let planEnd else { return true }
        return planEnd > now()
    }

    func checkInstalled() async -> Bool {
        if stateDBLocator() != nil {
            return true
        }
        let fileManager = FileManager.default
        return Self.clientSupportDirectories.contains { directory in
            fileManager.fileExists(atPath: "/Applications/\(directory).app")
                || fileManager.fileExists(atPath: NSHomeDirectory() + "/Library/Application Support/\(directory)")
        }
    }

    func isLoggedIn() async -> Bool {
        guard let authStatus = try? readAuthStatus() else {
            return false
        }
        return !authStatus.apiKey.isEmpty
    }

    private func readAuthStatus() throws -> WindsurfAuthStatus? {
        guard let value = try readStateValue(forKey: "windsurfAuthStatus") else {
            return nil
        }
        return try JSONDecoder().decode(WindsurfAuthStatus.self, from: Data(value.utf8))
    }

    private func readCachedPlanInfo() throws -> WindsurfCachedPlanInfo? {
        guard let value = try readStateValue(forKey: "windsurf.settings.cachedPlanInfo") else {
            return nil
        }
        let planInfo = try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: Data(value.utf8))

        // Freshness gate. This key is no longer written by the current client: it survives a
        // Windsurf-to-Devin migration verbatim and keeps parsing cleanly while being months out of
        // date, so an ungated read blends a dead billing period into today's numbers.
        guard isFresh(planEnd: planInfo.endDate) else {
            return nil
        }
        return planInfo
    }

    private func readStructuredSnapshot(authStatus: WindsurfAuthStatus, planInfo: WindsurfCachedPlanInfo?) throws -> WindsurfPageSnapshot? {
        let protoParser = WindsurfUserStatusProtoParser()

        if let snapshot = protoParser.parse(base64Encoded: authStatus.userStatusProtoBinaryBase64) {
            return merge(snapshot: snapshot, fallbackPlanInfo: planInfo)
        }

        guard let rawState = try readStateValue(forKey: "codeium.windsurf"),
              let state = try JSONSerialization.jsonObject(with: Data(rawState.utf8)) as? [String: Any]
        else {
            return nil
        }

        if let cachedUserStatus = state["windsurf.state.cachedUserStatus"] as? String,
           let snapshot = protoParser.parse(base64Encoded: cachedUserStatus) {
            return merge(snapshot: snapshot, fallbackPlanInfo: planInfo)
        }

        let candidateKeys = [
            "windsurf.state.cachedUsageSnapshot",
            "windsurf.state.cachedQuotaSnapshot",
            "windsurf.state.cachedUsagePageSnapshot"
        ]

        for key in candidateKeys {
            guard let snapshot = state[key] as? [String: Any] else { continue }
            guard
                let dailyUsagePercent = snapshot["dailyUsagePercent"] as? Int,
                let weeklyUsagePercent = snapshot["weeklyUsagePercent"] as? Int
            else {
                continue
            }

            return WindsurfPageSnapshot(
                dailyUsagePercent: dailyUsagePercent,
                weeklyUsagePercent: weeklyUsagePercent,
                dailyResetTime: parseSnapshotDate(snapshot["dailyResetTime"]),
                weeklyResetTime: parseSnapshotDate(snapshot["weeklyResetTime"]),
                extraUsageBalance: snapshot["extraUsageBalance"] as? String,
                planEndDate: planInfo?.endDate
            )
        }

        return nil
    }

    private func parseSnapshotDate(_ rawValue: Any?) -> Date? {
        switch rawValue {
        case let date as Date:
            return date
        case let number as NSNumber:
            return parseSnapshotTimestamp(number.doubleValue)
        case let string as String:
            if let timestamp = Double(string) {
                return parseSnapshotTimestamp(timestamp)
            }

            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso8601.date(from: string) {
                return date
            }

            iso8601.formatOptions = [.withInternetDateTime]
            return iso8601.date(from: string)
        default:
            return nil
        }
    }

    private func parseSnapshotTimestamp(_ value: Double) -> Date {
        let seconds = value > 100_000_000_000 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private func merge(snapshot: WindsurfPageSnapshot, fallbackPlanInfo: WindsurfCachedPlanInfo?) -> WindsurfPageSnapshot {
        WindsurfPageSnapshot(
            dailyUsagePercent: snapshot.dailyUsagePercent,
            weeklyUsagePercent: snapshot.weeklyUsagePercent,
            dailyResetTime: snapshot.dailyResetTime,
            weeklyResetTime: snapshot.weeklyResetTime,
            extraUsageBalance: snapshot.extraUsageBalance,
            planEndDate: snapshot.planEndDate ?? fallbackPlanInfo?.endDate
        )
    }


    private func readStateValue(forKey key: String) throws -> String? {
        var db: OpaquePointer?
        guard let stateDBPath = stateDBLocator() else {
            return nil
        }
        guard sqlite3_open_v2(stateDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UsageError.invalidResponse
        }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw UsageError.invalidResponse
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return Self.sqliteString(statement, index: 0)
    }

    private static func sqliteString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private static func sqliteData(_ statement: OpaquePointer?, index: Int32) -> Data? {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: bytes, count: byteCount)
    }

}
