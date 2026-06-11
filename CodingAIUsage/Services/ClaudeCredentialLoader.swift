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
        onInvalidate: @escaping () -> Void = {}
    ) {
        self.homeDirectory = homeDirectory
        self.keychainService = keychainService
        self.now = now
        self.cacheTTL = cacheTTL
        self.readFile = readFile
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

    /// Updates the in-memory credential cache without writing to the Keychain or a file.
    /// Used after an in-flight OAuth refresh so subsequent polls reuse the fresh token
    /// while leaving the stored credential for the `claude` CLI to own.
    func cacheRefreshedCredentials(_ credentials: ClaudeCredentials) {
        cache(credentials)
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

}
