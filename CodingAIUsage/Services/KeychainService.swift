import Foundation

struct SecurityCommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

final class KeychainService {
    typealias CommandRunner = ([String]) throws -> SecurityCommandResult
    typealias UsernameProvider = () -> String

    static let empty = KeychainService(
        commandRunner: { _ in
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        },
        currentUsername: { "unknown" }
    )

    private static let legacyServiceName = "Claude Code-credentials"

    private let commandRunner: CommandRunner
    private let currentUsername: UsernameProvider
    private let lock = NSLock()
    private var cachedServiceName: String?

    init(
        commandRunner: @escaping CommandRunner = KeychainService.runSecurityCommand,
        currentUsername: @escaping UsernameProvider = NSUserName
    ) {
        self.commandRunner = commandRunner
        self.currentUsername = currentUsername
    }

    func readClaudeCredentialsJSON() throws -> String? {
        try readClaudeCredentialsEntry()?.json
    }

    func writeClaudeCredentialsJSON(_ json: String, serviceName: String? = nil) throws {
        let discoveredServiceName = try resolveClaudeServiceName()
        let resolvedServiceName = serviceName ?? discoveredServiceName ?? Self.legacyServiceName
        let result = try commandRunner([
            "add-generic-password",
            "-s", resolvedServiceName,
            "-a", currentUsername(),
            "-w", json,
            "-U"
        ])

        guard result.exitCode == 0 else {
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

        let result = try commandRunner([
            "find-generic-password",
            "-s", serviceName,
            "-a", currentUsername(),
            "-w"
        ])

        guard result.exitCode == 0 else {
            if result.exitCode == 44 {
                return nil
            }
            throw UsageError.networkError("Claude Code: unable to read Keychain credentials")
        }

        let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return (trimmed, serviceName)
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

        if let hashedServiceName = try findHashedClaudeServiceName() {
            cache(serviceName: hashedServiceName)
            return hashedServiceName
        }

        return nil
    }

    private func keychainItemExists(serviceName: String) -> Bool {
        do {
            let result = try commandRunner([
                "find-generic-password",
                "-s", serviceName,
                "-a", currentUsername()
            ])
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func findHashedClaudeServiceName() throws -> String? {
        let result = try commandRunner(["dump-keychain"])
        guard result.exitCode == 0 else {
            return nil
        }

        let pattern = #"Claude Code-credentials-[^"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let output = result.standardOutput
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, options: [], range: range),
              let matchRange = Range(match.range, in: output) else {
            return nil
        }

        return String(output[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func cache(serviceName: String) {
        lock.lock()
        cachedServiceName = serviceName
        lock.unlock()
    }

    private static func runSecurityCommand(args: [String]) throws -> SecurityCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return SecurityCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
