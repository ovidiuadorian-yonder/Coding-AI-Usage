import Foundation

enum ClaudeCredentialSource: Equatable, Sendable {
    case file(path: String)
    case keychain(serviceName: String)
}

struct ClaudeCredentials: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let source: ClaudeCredentialSource
    let rawPayload: String
}

struct ClaudeCredentialCacheState {
    let cachedAccessToken: String?
    let cachedAt: Date?
    let cacheTTL: TimeInterval
}

final class ClaudeCredentialLoader {
    let homeDirectory: String
    let keychainService: KeychainService

    private let now: () -> Date
    private let cacheTTL: TimeInterval
    private let readFile: (String) -> Data?
    private let writeFile: (String, Data) throws -> Void
    private let onInvalidate: () -> Void
    private let lock = NSLock()
    private var cachedCredentials: ClaudeCredentials?
    private var cachedAt: Date?

    init(
        homeDirectory: String = NSHomeDirectory(),
        keychainService: KeychainService = KeychainService(),
        now: @escaping () -> Date = Date.init,
        cacheTTL: TimeInterval = 300,
        readFile: @escaping (String) -> Data? = { FileManager.default.contents(atPath: $0) },
        writeFile: @escaping (String, Data) throws -> Void = { path, data in
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        },
        onInvalidate: @escaping () -> Void = {}
    ) {
        self.homeDirectory = homeDirectory
        self.keychainService = keychainService
        self.now = now
        self.cacheTTL = cacheTTL
        self.readFile = readFile
        self.writeFile = writeFile
        self.onInvalidate = onInvalidate
    }

    var cacheState: ClaudeCredentialCacheState {
        lock.lock()
        defer { lock.unlock() }
        return ClaudeCredentialCacheState(
            cachedAccessToken: cachedCredentials?.accessToken,
            cachedAt: cachedAt,
            cacheTTL: cacheTTL
        )
    }

    func hasCredentialFile() -> Bool {
        credentialFilePaths.contains { path in
            guard let data = readFile(path) else { return false }
            return parseCredentials(data: data, source: .file(path: path)) != nil
        }
    }

    func invalidateCache() {
        lock.lock()
        cachedCredentials = nil
        cachedAt = nil
        lock.unlock()
        onInvalidate()
    }

    func loadAnyCredentials(forceRefresh: Bool = false) throws -> ClaudeCredentials? {
        if let cached = cachedCredentials(allowingFiles: true, allowingKeychain: true, forceRefresh: forceRefresh) {
            return cached
        }

        if let fileCredentials = try loadFileCredentials(forceRefresh: forceRefresh) {
            return fileCredentials
        }

        return try loadKeychainCredentials(forceRefresh: forceRefresh)
    }

    func loadFileCredentials(forceRefresh: Bool = false) throws -> ClaudeCredentials? {
        if let cached = cachedCredentials(allowingFiles: true, allowingKeychain: false, forceRefresh: forceRefresh) {
            return cached
        }

        for path in credentialFilePaths {
            guard let data = readFile(path),
                  let credentials = parseCredentials(data: data, source: .file(path: path)) else {
                continue
            }

            cache(credentials)
            return credentials
        }

        return nil
    }

    func loadKeychainCredentials(forceRefresh: Bool = false) throws -> ClaudeCredentials? {
        if let cached = cachedCredentials(allowingFiles: false, allowingKeychain: true, forceRefresh: forceRefresh) {
            return cached
        }

        guard let entry = try keychainService.readClaudeCredentialsEntry(),
              let data = entry.json.data(using: .utf8),
              let credentials = parseCredentials(
                data: data,
                source: .keychain(serviceName: entry.serviceName)
              ) else {
            return nil
        }

        cache(credentials)
        return credentials
    }

    func needsRefresh(_ credentials: ClaudeCredentials) -> Bool {
        guard credentials.refreshToken != nil else {
            return false
        }

        guard let expiresAt = credentials.expiresAt else {
            return true
        }

        return now().addingTimeInterval(300) >= expiresAt
    }

    func persist(_ credentials: ClaudeCredentials) throws {
        let updatedPayload = try updatedPayloadJSON(for: credentials)
        let updatedCredentials = ClaudeCredentials(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            expiresAt: credentials.expiresAt,
            source: credentials.source,
            rawPayload: updatedPayload
        )

        switch credentials.source {
        case .file(let path):
            try writeFile(path, Data(updatedPayload.utf8))
        case .keychain(let serviceName):
            try keychainService.writeClaudeCredentialsJSON(updatedPayload, serviceName: serviceName)
        }

        cache(updatedCredentials)
    }

    private var credentialFilePaths: [String] {
        [
            (homeDirectory as NSString).appendingPathComponent(".claude/.credentials.json"),
            (homeDirectory as NSString).appendingPathComponent(".claude/credentials.json")
        ]
    }

    // The cache holds a single credential slot. `allowingFiles`/`allowingKeychain` filter whether
    // the cached slot matches what the caller is looking for — they do not select from separate pools.
    private func cachedCredentials(
        allowingFiles: Bool,
        allowingKeychain: Bool,
        forceRefresh: Bool
    ) -> ClaudeCredentials? {
        lock.lock()
        defer { lock.unlock() }

        guard !forceRefresh,
              let cachedCredentials else {
            return nil
        }

        switch cachedCredentials.source {
        case .file:
            // File credentials are re-read every cacheTTL seconds to pick up external token refreshes.
            guard let cachedAt,
                  now().timeIntervalSince(cachedAt) <= cacheTTL else {
                return nil
            }
            return allowingFiles ? cachedCredentials : nil
        case .keychain:
            // Keychain credentials are not TTL-evicted — they remain cached until auth fails (401),
            // at which point the caller refreshes and re-caches. This avoids repeated Keychain reads
            // on every poll interval.
            return allowingKeychain ? cachedCredentials : nil
        }
    }

    private func cache(_ credentials: ClaudeCredentials) {
        lock.lock()
        cachedCredentials = credentials
        cachedAt = now()
        lock.unlock()
    }

    private func parseCredentials(data: Data, source: ClaudeCredentialSource) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            return nil
        }

        let expiresAt = Self.parseExpirationDate(from: oauth["expiresAt"])
        let rawPayload = String(decoding: data, as: UTF8.self)
        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            source: source,
            rawPayload: rawPayload
        )
    }

    private static func parseExpirationDate(from rawValue: Any?) -> Date? {
        guard let rawValue else { return nil }

        if let milliseconds = rawValue as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }

        if let milliseconds = rawValue as? Int {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }

        if let string = rawValue as? String, let milliseconds = Double(string) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }

        return nil
    }

    private func updatedPayloadJSON(for credentials: ClaudeCredentials) throws -> String {
        guard let data = credentials.rawPayload.data(using: .utf8),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.networkError("Claude Code: unable to persist refreshed credentials")
        }

        var oauth = (json["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = credentials.accessToken
        oauth["refreshToken"] = credentials.refreshToken
        oauth["expiresAt"] = credentials.expiresAt.map { $0.timeIntervalSince1970 * 1000 }
        json["claudeAiOauth"] = oauth

        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(decoding: updatedData, as: UTF8.self)
    }
}
