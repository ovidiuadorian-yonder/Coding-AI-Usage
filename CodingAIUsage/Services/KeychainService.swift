import Foundation
import Security

final class KeychainService {
    typealias CredentialWriter = (_ json: String, _ serviceName: String, _ account: String) throws -> Void
    typealias CredentialReader = (_ serviceName: String, _ account: String) throws -> String?
    typealias HashedServiceNameFinder = () -> String?
    typealias UsernameProvider = () -> String

    static let empty = KeychainService(
        currentUsername: { "unknown" },
        credentialWriter: { _, _, _ in },
        credentialReader: { _, _ in nil },
        hashedServiceNameFinder: { nil }
    )

    private static let legacyServiceName = "Claude Code-credentials"

    private let currentUsername: UsernameProvider
    private let credentialWriter: CredentialWriter
    private let credentialReader: CredentialReader
    private let hashedServiceNameFinder: HashedServiceNameFinder
    private let lock = NSLock()
    private var cachedServiceName: String?

    init(
        currentUsername: @escaping UsernameProvider = NSUserName,
        credentialWriter: @escaping CredentialWriter = KeychainService.writeCredentialsToKeychain,
        credentialReader: @escaping CredentialReader = KeychainService.readCredentialFromKeychain,
        hashedServiceNameFinder: @escaping HashedServiceNameFinder = KeychainService.findHashedClaudeServiceNameDirect
    ) {
        self.currentUsername = currentUsername
        self.credentialWriter = credentialWriter
        self.credentialReader = credentialReader
        self.hashedServiceNameFinder = hashedServiceNameFinder
    }

    func readClaudeCredentialsJSON() throws -> String? {
        try readClaudeCredentialsEntry()?.json
    }

    func writeClaudeCredentialsJSON(_ json: String, serviceName: String? = nil) throws {
        let resolvedServiceName: String
        if let serviceName {
            resolvedServiceName = serviceName
        } else {
            resolvedServiceName = try resolveClaudeServiceName() ?? Self.legacyServiceName
        }

        do {
            try credentialWriter(json, resolvedServiceName, currentUsername())
        } catch {
            throw UsageError.networkError("Claude Code: unable to update Keychain credentials")
        }

        lock.lock()
        cachedServiceName = resolvedServiceName
        lock.unlock()
    }

    func hasClaudeCredentialItem() -> Bool {
        (try? resolveClaudeServiceName()) != nil
    }

    func resolvedClaudeServiceName() throws -> String? {
        try resolveClaudeServiceName()
    }

    func readClaudeCredentialsEntry() throws -> (json: String, serviceName: String)? {
        guard let serviceName = try resolveClaudeServiceName() else {
            return nil
        }

        guard let json = try credentialReader(serviceName, currentUsername()) else {
            return nil
        }

        return (json, serviceName)
    }

    private func resolveClaudeServiceName() throws -> String? {
        lock.lock()
        if let cachedServiceName {
            lock.unlock()
            return cachedServiceName
        }
        lock.unlock()

        if keychainItemExists(serviceName: Self.legacyServiceName) {
            cache(serviceName: Self.legacyServiceName)
            return Self.legacyServiceName
        }

        if let hashedServiceName = findHashedClaudeServiceName() {
            cache(serviceName: hashedServiceName)
            return hashedServiceName
        }

        return nil
    }

    private func keychainItemExists(serviceName: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: currentUsername(),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private func findHashedClaudeServiceName() -> String? {
        hashedServiceNameFinder()
    }

    private func cache(serviceName: String) {
        lock.lock()
        cachedServiceName = serviceName
        lock.unlock()
    }

    private static func readCredentialFromKeychain(serviceName: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw UsageError.networkError("Claude Code: unable to read Keychain credentials")
        }
    }

    private static func findHashedClaudeServiceNameDirect() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return nil
        }

        let prefix = "Claude Code-credentials-"
        return items
            .compactMap { $0[kSecAttrService as String] as? String }
            .first { $0.hasPrefix(prefix) }
    }

    private static func writeCredentialsToKeychain(
        _ json: String,
        _ serviceName: String,
        _ account: String
    ) throws {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecParam))
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
    }
}
