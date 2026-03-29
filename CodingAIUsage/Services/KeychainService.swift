import Foundation
import Security

final class KeychainService {
    private static let cacheLock = NSLock()
    private static var cachedClaudeOAuthToken: String?

    private let claudeTokenReader: () -> String?

    init(claudeTokenReader: @escaping () -> String? = KeychainService.readClaudeOAuthTokenFromKeychain) {
        self.claudeTokenReader = claudeTokenReader
    }

    func getClaudeOAuthToken(forceRefresh: Bool = false) -> String? {
        if !forceRefresh, let cachedToken = Self.withClaudeTokenCache({ Self.cachedClaudeOAuthToken }) {
            return cachedToken
        }

        let token = claudeTokenReader()
        if let token {
            Self.withClaudeTokenCache {
                Self.cachedClaudeOAuthToken = token
            }
        }
        return token
    }

    func invalidateClaudeOAuthTokenCache() {
        Self.withClaudeTokenCache {
            Self.cachedClaudeOAuthToken = nil
        }
    }

    static func resetClaudeOAuthTokenCacheForTests() {
        withClaudeTokenCache {
            cachedClaudeOAuthToken = nil
        }
    }

    private static func readClaudeOAuthTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }

        return token
    }

    private static func withClaudeTokenCache<T>(_ body: () -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body()
    }

    func isClaudeLoggedIn(forceRefresh: Bool = false) -> Bool {
        getClaudeOAuthToken(forceRefresh: forceRefresh) != nil
    }
}
