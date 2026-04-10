import Foundation
import SQLite3
import Security
import WebKit
import CommonCrypto

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

protocol WindsurfUsageServing: Sendable {
    func fetchUsage(preferLiveRefresh: Bool) async throws -> ServiceUsage
    func checkInstalled() async -> Bool
    func isLoggedIn() async -> Bool
}

actor WindsurfUsageService: WindsurfUsageServing {
    typealias CookieStateProvider = @Sendable () throws -> WindsurfCookieState
    typealias LiveSnapshotProvider = @Sendable (_ planInfo: WindsurfCachedPlanInfo?, _ cookies: [HTTPCookie]) async throws -> WindsurfPageSnapshot?

    private let stateDBPath: String
    private let usageURL: URL
    private let cookieStateProvider: CookieStateProvider
    private let liveSnapshotProvider: LiveSnapshotProvider

    init(
        stateDBPath: String = NSHomeDirectory() + "/Library/Application Support/Windsurf/User/globalStorage/state.vscdb",
        usageURL: URL = URL(string: "https://windsurf.com/subscription/usage")!,
        cookieStateProvider: CookieStateProvider? = nil,
        liveSnapshotProvider: LiveSnapshotProvider? = nil
    ) {
        self.stateDBPath = stateDBPath
        self.usageURL = usageURL
        self.cookieStateProvider = cookieStateProvider ?? { [stateDBPath] in
            try WindsurfUsageService.readCookies(stateDBPath: stateDBPath)
        }
        self.liveSnapshotProvider = liveSnapshotProvider ?? { [usageURL] planInfo, cookies in
            try await WindsurfUsageService.scrapeSnapshot(
                usageURL: usageURL,
                planInfo: planInfo,
                cookies: cookies
            )
        }
    }

    func fetchUsage(preferLiveRefresh: Bool = false) async throws -> ServiceUsage {
        guard let authStatus = try readAuthStatus(), !authStatus.apiKey.isEmpty else {
            throw UsageError.noCredentials("Windsurf: not logged in")
        }

        let planInfo = try readCachedPlanInfo()
        let lastUpdated = Date()

        let persistedSnapshot = try
            planInfo?.quotaSnapshot ??
            readStructuredSnapshot(authStatus: authStatus, planInfo: planInfo)

        let cookieState: WindsurfCookieState
        let liveSnapshot: WindsurfPageSnapshot?
        if preferLiveRefresh {
            cookieState = try cookieStateProvider()
            if cookieState.hasLikelyAuthCookies {
                liveSnapshot = try? await liveSnapshotProvider(planInfo, cookieState.cookies)
            } else {
                liveSnapshot = nil
            }
        } else {
            cookieState = WindsurfCookieState(cookies: [], hasLikelyAuthCookies: false)
            liveSnapshot = nil
        }

        if let snapshot = WindsurfSnapshotResolver.resolve(
            cached: persistedSnapshot,
            live: liveSnapshot,
            preferLive: preferLiveRefresh
        ) {
            if preferLiveRefresh && WindsurfQuotaDiagnostics.shouldHideSuspiciousLocalQuota(
                snapshot: snapshot,
                hasLikelyLiveAuthCookies: cookieState.hasLikelyAuthCookies
            ) {
                return ServiceUsage(
                    id: "windsurf",
                    displayName: "Windsurf",
                    shortLabel: "W",
                    windows: [],
                    lastUpdated: lastUpdated,
                    error: "Windsurf: live quota unavailable; local cache may be stale",
                    footerLines: snapshot.footerLines
                )
            }

            return snapshot.toServiceUsage(lastUpdated: lastUpdated)
        }

        return ServiceUsage(
            id: "windsurf",
            displayName: "Windsurf",
            shortLabel: "W",
            windows: [],
            lastUpdated: lastUpdated,
            error: "Windsurf: daily/weekly quota unavailable",
            footerLines: []
        )
    }

    func checkInstalled() async -> Bool {
        let appPath = "/Applications/Windsurf.app"
        let supportPath = NSHomeDirectory() + "/Library/Application Support/Windsurf"
        return FileManager.default.fileExists(atPath: appPath) || FileManager.default.fileExists(atPath: supportPath)
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
        return try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: Data(value.utf8))
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

    private static func scrapeSnapshot(
        usageURL: URL,
        planInfo: WindsurfCachedPlanInfo?,
        cookies: [HTTPCookie]
    ) async throws -> WindsurfPageSnapshot? {
        guard !cookies.isEmpty else {
            return nil
        }

        let scraper = await WindsurfUsageScraper(url: usageURL)
        let pageText = try await scraper.fetchPageText(cookies: cookies)
        let parser = WindsurfUsagePageParser(now: Date())
        let parsed = try parser.parse(pageText: pageText)

        return WindsurfPageSnapshot(
            dailyUsagePercent: parsed.dailyUsagePercent,
            weeklyUsagePercent: parsed.weeklyUsagePercent,
            dailyResetTime: parsed.dailyResetTime,
            weeklyResetTime: parsed.weeklyResetTime,
            extraUsageBalance: parsed.extraUsageBalance,
            planEndDate: parsed.planEndDate ?? planInfo?.endDate
        )
    }

    private static func readCookies(stateDBPath _: String) throws -> WindsurfCookieState {
        let cookieStores = [
            ChromiumCookieStore(
                path: NSHomeDirectory() + "/Library/Application Support/Windsurf/Cookies",
                safeStorageService: "Windsurf Safe Storage",
                safeStorageAccount: "Windsurf"
            ),
            ChromiumCookieStore(
                path: NSHomeDirectory() + "/Library/Application Support/Microsoft Edge/Default/Cookies",
                safeStorageService: "Microsoft Edge Safe Storage",
                safeStorageAccount: "Microsoft Edge"
            ),
            ChromiumCookieStore(
                path: NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Default/Cookies",
                safeStorageService: "Chrome Safe Storage",
                safeStorageAccount: "Chrome"
            )
        ]

        var fallbackCookies: [HTTPCookie] = []

        for store in cookieStores where FileManager.default.fileExists(atPath: store.path) {
            let cookies = try readCookies(from: store)
            let hasLikelyAuthCookies = cookies.contains(where: Self.isLikelyAuthCookie(_:))

            if hasLikelyAuthCookies {
                return WindsurfCookieState(
                    cookies: cookies,
                    hasLikelyAuthCookies: true
                )
            }

            if fallbackCookies.isEmpty, !cookies.isEmpty {
                fallbackCookies = cookies
            }
        }

        return WindsurfCookieState(cookies: fallbackCookies, hasLikelyAuthCookies: false)
    }

    private static func isLikelyAuthCookie(_ cookie: HTTPCookie) -> Bool {
        let name = cookie.name.lowercased()
        let analyticsPrefixes = ["_ga", "__stripe_", "ph_", "ajs_", "amplitude", "mp_"]
        return !analyticsPrefixes.contains(where: { name.hasPrefix($0) })
    }

    private static func readCookies(from store: ChromiumCookieStore) throws -> [HTTPCookie] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UsageError.invalidResponse
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly
        FROM cookies
        WHERE host_key LIKE '%windsurf.com%'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw UsageError.invalidResponse
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [HTTPCookie] = []
        let safeStorageKey = WindsurfChromiumCookieCrypto.safeStorageKey(
            service: store.safeStorageService,
            account: store.safeStorageAccount
        )

        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let hostKey = sqliteString(statement, index: 0),
                let name = sqliteString(statement, index: 1),
                let path = sqliteString(statement, index: 4)
            else {
                continue
            }

            let value: String?
            if let plaintextValue = sqliteString(statement, index: 2), !plaintextValue.isEmpty {
                value = plaintextValue
            } else if
                let encryptedValue = sqliteData(statement, index: 3),
                let safeStorageKey,
                !encryptedValue.isEmpty
            {
                value = WindsurfChromiumCookieCrypto.decryptCookieValue(
                    encryptedValue,
                    hostKey: hostKey,
                    safeStorageKey: safeStorageKey
                )
            } else {
                value = nil
            }

            guard let value, !value.isEmpty else {
                continue
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: hostKey,
                .name: name,
                .value: value,
                .path: path
            ]

            if sqlite3_column_int64(statement, 5) > 0 {
                properties[.expires] = chromiumDate(from: sqlite3_column_int64(statement, 5))
            }
            if sqlite3_column_int(statement, 6) != 0 {
                properties[.secure] = "TRUE"
            }
            if sqlite3_column_int(statement, 7) != 0 {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }

            if let cookie = HTTPCookie(properties: properties) {
                cookies.append(cookie)
            }
        }

        return cookies
    }

    private func readStateValue(forKey key: String) throws -> String? {
        var db: OpaquePointer?
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

    private static func chromiumDate(from value: Int64) -> Date {
        let secondsSince1601 = Double(value) / 1_000_000.0
        let secondsBetweenEpochs = 11_644_473_600.0
        return Date(timeIntervalSince1970: secondsSince1601 - secondsBetweenEpochs)
    }
}

private struct ChromiumCookieStore {
    let path: String
    let safeStorageService: String
    let safeStorageAccount: String
}

struct WindsurfCookieState {
    let cookies: [HTTPCookie]
    let hasLikelyAuthCookies: Bool
}

struct WindsurfChromiumCookieCrypto {
    private static let version10Prefix = Data("v10".utf8)
    private static let version11Prefix = Data("v11".utf8)

    static func safeStorageKey(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decryptCookieValue(_ encryptedValue: Data, hostKey: String, safeStorageKey: String) -> String? {
        let ciphertext: Data
        switch encryptedValue.prefix(3) {
        case version10Prefix, version11Prefix:
            ciphertext = encryptedValue.dropFirst(3)
        default:
            ciphertext = encryptedValue
        }

        guard
            let key = deriveKey(from: safeStorageKey),
            let decrypted = aes128CBCDecrypt(
                ciphertext,
                key: key,
                iv: Data(repeating: 0x20, count: kCCBlockSizeAES128)
            )
        else {
            return nil
        }

        let plaintext = stripHostDigestIfPresent(from: decrypted, hostKey: hostKey)
        return String(data: plaintext, encoding: .utf8)
    }

    private static func deriveKey(from safeStorageKey: String) -> Data? {
        let password = Data(safeStorageKey.utf8)
        let salt = Data("saltysalt".utf8)
        var derived = Data(count: kCCKeySizeAES128)
        let derivedCount = derived.count

        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedCount
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            return nil
        }

        return derived
    }

    private static func aes128CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let plaintextCount = plaintext.count

        let status = plaintext.withUnsafeMutableBytes { plaintextBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress,
                            ciphertext.count,
                            plaintextBytes.baseAddress,
                            plaintextCount,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            return nil
        }

        plaintext.removeSubrange(outputLength..<plaintext.count)
        return plaintext
    }

    private static func stripHostDigestIfPresent(from decrypted: Data, hostKey: String) -> Data {
        let digest = sha256(Data(hostKey.utf8))
        guard decrypted.starts(with: digest) else {
            return decrypted
        }
        return decrypted.dropFirst(digest.count)
    }

    private static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}

@MainActor
final class WindsurfUsageScraper: NSObject, WKNavigationDelegate {
    private let url: URL
    private let webView: WKWebView
    private var continuation: CheckedContinuation<String, Error>?

    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func fetchPageText(cookies: [HTTPCookie]) async throws -> String {
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, let continuation = self.continuation else { return }
                self.continuation = nil
                continuation.resume(throwing: UsageError.networkError("Windsurf: usage page timed out"))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, error in
            guard let self, let continuation = self.continuation else { return }
            self.continuation = nil

            if let error {
                continuation.resume(throwing: error)
                return
            }

            let text = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                continuation.resume(throwing: UsageError.invalidResponse)
            } else {
                continuation.resume(returning: text)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishWithError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishWithError(error)
    }

    private func finishWithError(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}
