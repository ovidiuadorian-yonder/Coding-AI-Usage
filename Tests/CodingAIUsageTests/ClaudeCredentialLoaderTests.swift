import XCTest
@testable import CodingAIUsage

final class ClaudeCredentialLoaderTests: XCTestCase {
    func testFileCredentialsPreferredOverKeychain() throws {
        let tempDir = makeTempDirectory()
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: filePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileJSON = credentialsJSON(accessToken: "file-token", refreshToken: "file-refresh")
        try fileJSON.write(toFile: filePath, atomically: true, encoding: .utf8)

        let keychain = KeychainService(
            commandRunner: { args in
                if args.contains("find-generic-password") {
                    return .init(exitCode: 0, standardOutput: self.credentialsJSON(accessToken: "keychain-token"), standardError: "")
                }
                return .init(exitCode: 44, standardOutput: "", standardError: "")
            },
            currentUsername: { "tester" }
        )

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            keychainService: keychain
        )

        let credentials = try loader.loadAnyCredentials()

        XCTAssertEqual(credentials?.accessToken, "file-token")
        XCTAssertEqual(credentials?.refreshToken, "file-refresh")
        XCTAssertEqual(credentials?.source, .file(path: filePath))
    }

    func testHashedKeychainServiceNameIsResolvedWhenLegacyEntryIsMissing() throws {
        var seenHashedLookup = false
        let service = KeychainService(
            commandRunner: { args in
                if args == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "tester"] {
                    return .init(exitCode: 44, standardOutput: "", standardError: "")
                }
                if args == ["dump-keychain"] {
                    return .init(
                        exitCode: 0,
                        standardOutput: "\"svce\"<blob>=\"Claude Code-credentials-abc123\"\n",
                        standardError: ""
                    )
                }
                if args == ["find-generic-password", "-s", "Claude Code-credentials-abc123", "-a", "tester", "-w"] {
                    seenHashedLookup = true
                    return .init(exitCode: 0, standardOutput: self.credentialsJSON(accessToken: "hashed-token"), standardError: "")
                }
                return .init(exitCode: 44, standardOutput: "", standardError: "")
            },
            currentUsername: { "tester" }
        )

        let result = try service.readClaudeCredentialsJSON()

        XCTAssertTrue(seenHashedLookup)
        XCTAssertEqual(result, credentialsJSON(accessToken: "hashed-token"))
    }

    func testCredentialCacheExpiresAfterTTL() throws {
        let tempDir = makeTempDirectory()
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: filePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileJSON = credentialsJSON(accessToken: "file-token")
        try fileJSON.write(toFile: filePath, atomically: true, encoding: .utf8)

        var now = Date(timeIntervalSince1970: 1_000)
        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            keychainService: KeychainService.empty,
            now: { now },
            cacheTTL: 300
        )

        _ = try loader.loadAnyCredentials()
        XCTAssertEqual(loader.cacheState.cachedAccessToken, "file-token")

        now = now.addingTimeInterval(301)
        XCTAssertTrue(loader.cacheState.isExpired(referenceDate: now))
        _ = try loader.loadAnyCredentials()

        XCTAssertEqual(loader.cacheState.cachedAccessToken, "file-token")
    }

    func testInvalidateCacheClearsCachedCredentials() throws {
        let tempDir = makeTempDirectory()
        let filePath = tempDir.appendingPathComponent(".claude/.credentials.json").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: filePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileJSON = credentialsJSON(accessToken: "file-token")
        try fileJSON.write(toFile: filePath, atomically: true, encoding: .utf8)

        let loader = ClaudeCredentialLoader(
            homeDirectory: tempDir.path,
            keychainService: KeychainService.empty
        )

        _ = try loader.loadAnyCredentials()
        loader.invalidateCache()

        XCTAssertNil(loader.cacheState.cachedAccessToken)
    }

    private func makeTempDirectory() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-credentials-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func credentialsJSON(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAtMilliseconds: Double = 1_800_000_000_000
    ) -> String {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "expiresAt": expiresAtMilliseconds
        ]
        if let refreshToken {
            oauth["refreshToken"] = refreshToken
        }

        let payload: [String: Any] = [
            "claudeAiOauth": oauth
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
