import Foundation

enum ClaudeCredentialSource: Equatable, Sendable {
    case file(path: String)
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

/// Loads Claude Code OAuth credentials from a credentials **file** only.
///
/// The macOS Keychain is deliberately not consulted. Claude Code writes its credential item with
/// `security add-generic-password -U`, which replaces the item's access control list on every
/// token refresh, so a third-party reader's "Always Allow" grant is destroyed roughly every time
/// the CLI refreshes — a login-keychain password prompt several times a day, with no upstream fix
/// (anthropics/claude-code#22144, closed not planned). Reading a file needs no ACL and cannot
/// prompt. When no file exists, the caller falls back to the `claude` CLI, which reads its own
/// item using its own grant. See
/// `docs/superpowers/specs/2026-09-07-claude-cli-primary-design.md`.
final class ClaudeCredentialLoader {
    let homeDirectory: String

    private let now: () -> Date
    private let cacheTTL: TimeInterval
    private let readFile: (String) -> Data?
    private let onInvalidate: () -> Void
    private let lock = NSLock()
    private var cachedCredentials: ClaudeCredentials?
    private var cachedAt: Date?

    init(
        homeDirectory: String = NSHomeDirectory(),
        now: @escaping () -> Date = Date.init,
        cacheTTL: TimeInterval = 300,
        readFile: @escaping (String) -> Data? = { FileManager.default.contents(atPath: $0) },
        onInvalidate: @escaping () -> Void = {}
    ) {
        self.homeDirectory = homeDirectory
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

    func loadCredentials(forceRefresh: Bool = false) throws -> ClaudeCredentials? {
        if !forceRefresh, let cached = validCachedCredentials() {
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

    /// Whether the credential is unusable for a request starting now.
    ///
    /// A 60s skew keeps a request from starting with a token about to lapse mid-flight. A `nil`
    /// expiry is treated as **usable**: the app cannot refresh, so inferring expiry from a missing
    /// field would discard a working token. A 401 covers that case instead.
    func isExpired(_ credentials: ClaudeCredentials, skew: TimeInterval = 60) -> Bool {
        guard let expiresAt = credentials.expiresAt else {
            return false
        }
        return now().addingTimeInterval(skew) >= expiresAt
    }

    private var credentialFilePaths: [String] {
        [
            (homeDirectory as NSString).appendingPathComponent(".claude/.credentials.json"),
            (homeDirectory as NSString).appendingPathComponent(".claude/credentials.json")
        ]
    }

    private func validCachedCredentials() -> ClaudeCredentials? {
        lock.lock()
        defer { lock.unlock() }

        // Re-read every cacheTTL seconds so an external token refresh by the CLI is picked up.
        guard let cachedCredentials,
              let cachedAt,
              now().timeIntervalSince(cachedAt) <= cacheTTL else {
            return nil
        }
        return cachedCredentials
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
