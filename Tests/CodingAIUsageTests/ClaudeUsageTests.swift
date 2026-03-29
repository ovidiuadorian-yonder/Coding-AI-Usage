import XCTest
@testable import CodingAIUsage

final class ClaudeUsageTests: XCTestCase {
    func testClaudeCheckInstalledFindsUserLocalBinaryWithoutPATH() async throws {
        let localClaudePath = NSHomeDirectory() + "/.local/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: localClaudePath) else {
            throw XCTSkip("This machine does not install claude under ~/.local/bin")
        }

        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let installed = await ClaudeUsageService().checkInstalled()

        XCTAssertTrue(installed)
    }

    func testClaudeReauthCommandLogsOutThenStartsLoginFlow() {
        XCTAssertEqual(
            ClaudeAuthLauncher.reauthCommand,
            "/bin/zsh -lc 'claude auth logout || true; claude auth login --claudeai'"
        )
    }

    func testClaudeReauthAppleScriptEscapesCommandQuotes() {
        let script = ClaudeAuthLauncher.appleScript(command: #"echo "quoted""#)

        XCTAssertTrue(script.contains(#"do script "echo \"quoted\"""#))
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
    }

    func testClaudeOAuthTokenUsesInMemoryCacheAfterFirstRead() {
        KeychainService.resetClaudeOAuthTokenCacheForTests()
        defer { KeychainService.resetClaudeOAuthTokenCacheForTests() }

        var readCount = 0
        let service = KeychainService {
            readCount += 1
            return "claude-token"
        }

        XCTAssertEqual(service.getClaudeOAuthToken(), "claude-token")
        XCTAssertEqual(service.getClaudeOAuthToken(), "claude-token")
        XCTAssertEqual(readCount, 1)
    }

    func testInvalidatingClaudeOAuthTokenCacheForcesFreshRead() {
        KeychainService.resetClaudeOAuthTokenCacheForTests()
        defer { KeychainService.resetClaudeOAuthTokenCacheForTests() }

        var readCount = 0
        let service = KeychainService {
            readCount += 1
            return "claude-token-\(readCount)"
        }

        XCTAssertEqual(service.getClaudeOAuthToken(), "claude-token-1")
        service.invalidateClaudeOAuthTokenCache()
        XCTAssertEqual(service.getClaudeOAuthToken(), "claude-token-2")
        XCTAssertEqual(readCount, 2)
    }

    func testForceRefreshBypassesClaudeOAuthTokenCache() {
        KeychainService.resetClaudeOAuthTokenCacheForTests()
        defer { KeychainService.resetClaudeOAuthTokenCacheForTests() }

        var readCount = 0
        let service = KeychainService {
            readCount += 1
            return "claude-token-\(readCount)"
        }

        XCTAssertEqual(service.getClaudeOAuthToken(), "claude-token-1")
        XCTAssertEqual(service.getClaudeOAuthToken(forceRefresh: true), "claude-token-2")
        XCTAssertEqual(readCount, 2)
    }

    func testMissingClaudeOAuthTokenIsNotCached() {
        KeychainService.resetClaudeOAuthTokenCacheForTests()
        defer { KeychainService.resetClaudeOAuthTokenCacheForTests() }

        var results: [String?] = [nil, "claude-token"]
        var readCount = 0
        let service = KeychainService {
            readCount += 1
            return results.removeFirst()
        }

        XCTAssertNil(service.getClaudeOAuthToken())
        XCTAssertEqual(service.getClaudeOAuthToken(), "claude-token")
        XCTAssertEqual(readCount, 2)
    }
}
