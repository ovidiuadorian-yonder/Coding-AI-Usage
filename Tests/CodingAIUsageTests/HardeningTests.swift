import XCTest
@testable import CodingAIUsage

/// Defense-in-depth checks added after the security review of `claude-cli-primary`.
///
/// The review found no exploitable vulnerability. These cover the two items it named and
/// excluded, both of which became more relevant in that change: the `claude` binary is now
/// executed on every refresh rather than as a last resort, and the state-database probe is now
/// the sole locator for the Devin provider.
final class HardeningTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeExecutable(_ name: String, permissions: Int16, inDirectory dir: URL? = nil) throws -> String {
        let directory = dir ?? root!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - Executable trust

    func testUserOnlyExecutableIsAccepted() throws {
        // 0o700 in a user-owned directory: the normal ~/.local/bin case.
        let path = try makeExecutable("claude", permissions: 0o700)
        XCTAssertTrue(ClaudeUsageService.isTrustworthyExecutable(atPath: path))
    }

    func testWorldWritableExecutableIsRejected() throws {
        let path = try makeExecutable("claude", permissions: 0o777)
        XCTAssertFalse(ClaudeUsageService.isTrustworthyExecutable(atPath: path),
                       "a binary anyone can overwrite must not be executed")
    }

    func testGroupWritableExecutableIsRejected() throws {
        let path = try makeExecutable("claude", permissions: 0o770)
        XCTAssertFalse(ClaudeUsageService.isTrustworthyExecutable(atPath: path))
    }

    func testExecutableInWorldWritableDirectoryIsRejected() throws {
        // The classic hijack: the file itself looks fine, but anyone can replace it by name.
        let dir = root.appendingPathComponent("open-bin", isDirectory: true)
        let path = try makeExecutable("claude", permissions: 0o755, inDirectory: dir)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o777))],
                                             ofItemAtPath: dir.path)
        XCTAssertFalse(ClaudeUsageService.isTrustworthyExecutable(atPath: path))
    }

    func testMissingOrEmptyPathIsRejected() {
        XCTAssertFalse(ClaudeUsageService.isTrustworthyExecutable(atPath: ""))
        XCTAssertFalse(ClaudeUsageService.isTrustworthyExecutable(atPath: root.appendingPathComponent("nope").path))
    }

    // MARK: - State database path resolution

    private func attributes(of path: String) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path)
    }

    func testRegularFileIsAccepted() throws {
        let file = root.appendingPathComponent("state.vscdb")
        try Data("db".utf8).write(to: file)
        XCTAssertTrue(WindsurfUsageService.resolvesWithin(
            homeDirectory: root.path, path: file.path, attributes: try attributes(of: file.path)
        ))
    }

    func testSymlinkInsideHomeIsAccepted() throws {
        // Legitimate relocation: the real file lives elsewhere under the same home directory.
        let target = root.appendingPathComponent("elsewhere.vscdb")
        try Data("db".utf8).write(to: target)
        let link = root.appendingPathComponent("state.vscdb")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertTrue(WindsurfUsageService.resolvesWithin(
            homeDirectory: root.path, path: link.path, attributes: try attributes(of: link.path)
        ))
    }

    func testSymlinkEscapingHomeIsRejected() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).vscdb")
        try Data("db".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = root.appendingPathComponent("state.vscdb")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertFalse(WindsurfUsageService.resolvesWithin(
            homeDirectory: root.path, path: link.path, attributes: try attributes(of: link.path)
        ), "a redirected database would report another file's quota as this client's")
    }

    func testLocatorSkipsARedirectedCandidate() throws {
        // End to end: a Devin path redirected outside home must not be selected, and the probe
        // must fall through to the legitimate Windsurf candidate instead of failing outright.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).vscdb")
        try Data("db".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        for client in ["Devin", "Windsurf"] {
            let dir = root.appendingPathComponent("Library/Application Support/\(client)/User/globalStorage",
                                                 isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("state.vscdb")
            if client == "Devin" {
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            } else {
                try Data("db".utf8).write(to: file)
            }
        }

        let located = WindsurfUsageService.defaultStateDBLocator(homeDirectory: root.path)
        XCTAssertEqual(located?.contains("/Windsurf/"), true, located ?? "nil")
    }
}
