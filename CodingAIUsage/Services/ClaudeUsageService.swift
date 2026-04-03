import Foundation

struct ClaudeCLIExecutionResult {
    let exitCode: Int32
    let output: String
}

actor ClaudeUsageService {
    typealias NetworkClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias CLIExecutor = @Sendable (_ binary: String, _ arguments: [String]) -> ClaudeCLIExecutionResult
    typealias BinaryLocator = @Sendable () -> Bool

    private enum CredentialScope {
        case file
        case keychain
    }

    private let credentialLoader: ClaudeCredentialLoader
    private let networkClient: NetworkClient
    private let cliExecutor: CLIExecutor
    private let claudeBinaryLocator: BinaryLocator
    private let cliParser = ClaudeCLIUsageParser()
    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let oauthScopes = "user:profile user:inference user:sessions:claude_code"

    init(
        credentialLoader: ClaudeCredentialLoader = ClaudeCredentialLoader(),
        networkClient: @escaping NetworkClient = { request in
            try await URLSession.shared.data(for: request)
        },
        cliExecutor: @escaping CLIExecutor = { binary, arguments in
            ClaudeUsageService.defaultCLIExecutor(binary: binary, arguments: arguments)
        },
        claudeBinaryLocator: @escaping BinaryLocator = {
            ClaudeUsageService.defaultClaudeBinaryLocator()
        }
    ) {
        self.credentialLoader = credentialLoader
        self.networkClient = networkClient
        self.cliExecutor = cliExecutor
        self.claudeBinaryLocator = claudeBinaryLocator
    }

    func fetchUsage() async throws -> ServiceUsage {
        if let fileCredentials = try credentialLoader.loadFileCredentials() {
            return try await fetchUsageViaAPI(
                startingWith: fileCredentials,
                credentialScope: .file
            )
        }

        if checkInstalled() {
            do {
                return try fetchUsageViaCLI()
            } catch let cliError as UsageError {
                if let keychainCredentials = try credentialLoader.loadKeychainCredentials() {
                    return try await fetchUsageViaAPI(
                        startingWith: keychainCredentials,
                        credentialScope: .keychain
                    )
                }
                throw cliError
            }
        }

        if let keychainCredentials = try credentialLoader.loadKeychainCredentials() {
            return try await fetchUsageViaAPI(
                startingWith: keychainCredentials,
                credentialScope: .keychain
            )
        }

        throw UsageError.noCredentials("Claude Code: not logged in")
    }

    func checkInstalled() -> Bool {
        claudeBinaryLocator()
    }

    func hasCredentialFile() -> Bool {
        credentialLoader.hasCredentialFile()
    }

    func invalidateCredentialCache() {
        credentialLoader.invalidateCache()
    }

    private func fetchUsageViaCLI() throws -> ServiceUsage {
        let result = cliExecutor("claude", ["/usage", "--allowed-tools", ""])
        if result.output.isEmpty && result.exitCode != 0 {
            throw UsageError.networkError("Claude Code: CLI usage probe failed")
        }

        do {
            return try cliParser.parse(result.output)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.networkError("Claude Code: unexpected CLI usage output")
        }
    }

    private func fetchUsageViaAPI(
        startingWith credentials: ClaudeCredentials,
        credentialScope: CredentialScope,
        didReloadCredentials: Bool = false
    ) async throws -> ServiceUsage {
        var activeCredentials = credentials
        if credentialLoader.needsRefresh(activeCredentials) {
            activeCredentials = try await refreshCredentials(activeCredentials)
        }

        do {
            return try await performUsageRequest(accessToken: activeCredentials.accessToken)
        } catch let error as UsageError {
            guard case .authExpired = error else {
                throw error
            }

            credentialLoader.invalidateCache()
            guard !didReloadCredentials,
                  let reloaded = try reloadCredentials(scope: credentialScope) else {
                throw error
            }

            return try await fetchUsageViaAPI(
                startingWith: reloaded,
                credentialScope: credentialScope,
                didReloadCredentials: true
            )
        }
    }

    private func reloadCredentials(scope: CredentialScope) throws -> ClaudeCredentials? {
        switch scope {
        case .file:
            return try credentialLoader.loadFileCredentials(forceRefresh: true)
        case .keychain:
            return try credentialLoader.loadKeychainCredentials(forceRefresh: true)
        }
    }

    private func refreshCredentials(_ credentials: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard let refreshToken = credentials.refreshToken else {
            return credentials
        }

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
            "scope": oauthScopes
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await networkClient(request)
        } catch {
            throw UsageError.networkError("Claude Code: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorCode = json["error"] as? String,
               errorCode == "invalid_grant" {
                throw UsageError.authExpired("Claude Code: session expired - please re-login in Claude Code")
            }

            throw UsageError.authExpired("Claude Code: session expired - please re-login in Claude Code")
        }

        guard httpResponse.statusCode == 200 else {
            throw UsageError.httpError(httpResponse.statusCode)
        }

        guard let refreshResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = refreshResponse["access_token"] as? String else {
            throw UsageError.invalidResponse
        }

        let expiresAt = (refreshResponse["expires_in"] as? Double)
            .map { Date().addingTimeInterval($0) }
        let updatedCredentials = ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: (refreshResponse["refresh_token"] as? String) ?? credentials.refreshToken,
            expiresAt: expiresAt,
            source: credentials.source,
            rawPayload: credentials.rawPayload
        )
        try credentialLoader.persist(updatedCredentials)
        return updatedCredentials
    }

    private func performUsageRequest(accessToken: String) async throws -> ServiceUsage {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await networkClient(request)
        } catch {
            throw UsageError.networkError("Claude Code: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            let usage = try decoder.decode(ClaudeUsageResponse.self, from: data)
            return usage.toServiceUsage()
        case 401, 403:
            throw UsageError.authExpired("Claude Code: session expired - please re-login in Claude Code")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.httpError(httpResponse.statusCode)
        }
    }

    private static func defaultClaudeBinaryLocator() -> Bool {
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude"
        ]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func defaultCLIExecutor(binary: String, arguments: [String]) -> ClaudeCLIExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let escapedArguments = ([binary] + arguments).map { argument -> String in
            if argument.isEmpty {
                return "\"\""
            }
            return argument.contains(" ") ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
        process.arguments = ["-lc", escapedArguments]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            let timeout = Date().addingTimeInterval(15)
            while process.isRunning && Date() < timeout {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        } catch {
            return ClaudeCLIExecutionResult(exitCode: 1, output: "")
        }

        var data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        data.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
        return ClaudeCLIExecutionResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
