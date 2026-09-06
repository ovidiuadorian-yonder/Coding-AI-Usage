import Foundation

struct ClaudeCLIExecutionResult {
    let exitCode: Int32
    let output: String
}

protocol ClaudeUsageServing: Sendable {
    func fetchUsage() async throws -> ServiceUsage
    func checkInstalled() async -> Bool
    func hasCredentialFile() async -> Bool
    func invalidateCredentialCache() async
}

actor ClaudeUsageService: ClaudeUsageServing {
    typealias NetworkClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias CLIExecutor = @Sendable (_ binaryPath: String, _ arguments: [String]) -> ClaudeCLIExecutionResult
    typealias BinaryLocator = @Sendable () -> String?

    private enum CredentialScope {
        case file
        case keychain
    }

    private let credentialLoader: ClaudeCredentialLoader
    private let networkClient: NetworkClient
    private let diagnostic: DiagnosticRecorder
    private let cliExecutor: CLIExecutor
    private let claudeBinaryLocator: BinaryLocator
    private let cliParser = ClaudeCLIUsageParser()
    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let oauthScopes = "user:profile user:inference user:sessions:claude_code"
    private let userAgent = "claude-code/2.1.173"

    init(
        credentialLoader: ClaudeCredentialLoader = ClaudeCredentialLoader(),
        networkClient: @escaping NetworkClient = { request in
            try await URLSession.shared.data(for: request)
        },
        cliExecutor: @escaping CLIExecutor = { binaryPath, arguments in
            ClaudeUsageService.defaultCLIExecutor(binaryPath: binaryPath, arguments: arguments)
        },
        claudeBinaryLocator: @escaping BinaryLocator = {
            ClaudeUsageService.defaultClaudeBinaryLocator()
        },
        diagnostic: @escaping DiagnosticRecorder = DiagnosticLog.claude
    ) {
        self.credentialLoader = credentialLoader
        self.networkClient = networkClient
        self.diagnostic = diagnostic
        self.cliExecutor = cliExecutor
        self.claudeBinaryLocator = claudeBinaryLocator
    }

    func fetchUsage() async throws -> ServiceUsage {
        // File and Keychain are alternative credential sources, tried in priority order. A non-auth
        // error (rate limit / network) from the chosen source propagates to the caller and is recovered
        // by polling backoff; we intentionally do not fall back across sources on transient failures.
        if let fileCredentials = try credentialLoader.loadFileCredentials() {
            return try await fetchUsageViaAPI(
                startingWith: fileCredentials,
                credentialScope: .file
            )
        }

        if let keychainCredentials = try credentialLoader.loadKeychainCredentials() {
            return try await fetchUsageViaAPI(
                startingWith: keychainCredentials,
                credentialScope: .keychain
            )
        }

        // Last-resort fallback: scrape the CLI only when no token is available via file or Keychain.
        if let claudePath = claudeBinaryLocator() {
            return try fetchUsageViaCLI(binaryPath: claudePath)
        }

        throw UsageError.noCredentials("Claude Code: not logged in")
    }

    func checkInstalled() async -> Bool {
        claudeBinaryLocator() != nil
    }

    func hasCredentialFile() async -> Bool {
        credentialLoader.hasCredentialFile()
    }

    func invalidateCredentialCache() async {
        credentialLoader.invalidateCache()
    }

    private func fetchUsageViaCLI(binaryPath: String) throws -> ServiceUsage {
        let result = cliExecutor(binaryPath, ["/usage", "--allowed-tools", ""])
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
        // Only refresh proactively on the first attempt. After a 401 we reload the freshest
        // stored credential (the `claude` CLI may have rotated it) and try it directly — refreshing
        // again here would re-use our already-consumed refresh token and yield a false invalid_grant.
        if !didReloadCredentials, credentialLoader.needsRefresh(activeCredentials) {
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
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
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
            let loggedErrorCode = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error"] as? String } ?? "unknown"
            logEndpoint(
                "token",
                status: httpResponse.statusCode,
                response: httpResponse,
                extra: "error=\(loggedErrorCode)"
            )

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorCode = json["error"] as? String,
               errorCode == "invalid_grant" {
                throw UsageError.authExpired("Claude Code: session expired - please re-login in Claude Code")
            }

            throw UsageError.authExpired("Claude Code: session expired - please re-login in Claude Code")
        }

        if httpResponse.statusCode == 429 {
            logEndpoint("token", status: 429, response: httpResponse)
            // The token endpoint is rate-limited. Surface this as .rateLimited (not .httpError) so
            // menu-open refreshes pause for Retry-After — a near-expiry token makes needsRefresh true
            // on every fetch, so retrying here before the limit clears keeps the rate limit alive.
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        }

        guard httpResponse.statusCode == 200 else {
            logEndpoint("token", status: httpResponse.statusCode, response: httpResponse)
            throw UsageError.httpError(httpResponse.statusCode)
        }

        guard let refreshResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = refreshResponse["access_token"] as? String else {
            throw UsageError.invalidResponse
        }

        // Rotation probe: does the endpoint hand back a different refresh token than the one
        // presented? If it consistently does, the stored credential the `claude` CLI owns is being
        // superseded by our refresh — the mechanism behind CodexBar #1161. Fingerprints only.
        let returnedRefreshToken = refreshResponse["refresh_token"] as? String
        let changed = returnedRefreshToken != nil && returnedRefreshToken != refreshToken
        diagnostic(
            "endpoint=token status=200 refresh-token-changed=\(changed) "
            + "sent=\(DiagnosticLog.fingerprint(refreshToken)) "
            + "returned=\(DiagnosticLog.fingerprint(returnedRefreshToken))"
        )

        let expiresAt = (refreshResponse["expires_in"] as? Double)
            .map { Date().addingTimeInterval($0) }
        let updatedCredentials = ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: (refreshResponse["refresh_token"] as? String) ?? credentials.refreshToken,
            expiresAt: expiresAt,
            source: credentials.source,
            rawPayload: credentials.rawPayload
        )
        credentialLoader.cacheRefreshedCredentials(updatedCredentials)
        return updatedCredentials
    }

    private func performUsageRequest(accessToken: String) async throws -> ServiceUsage {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

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
            logEndpoint("usage", status: httpResponse.statusCode, response: httpResponse)
            throw UsageError.authExpired("Claude Code: session expired - please re-login in Claude Code")
        case 429:
            logEndpoint("usage", status: 429, response: httpResponse)
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            logEndpoint("usage", status: httpResponse.statusCode, response: httpResponse)
            throw UsageError.httpError(httpResponse.statusCode)
        }
    }

    /// Emits one machine-greppable line per non-success response, tagged with the endpoint that
    /// produced it. `endpoint=usage` is api.anthropic.com; `endpoint=token` is platform.claude.com.
    private func logEndpoint(
        _ endpoint: String,
        status: Int,
        response: HTTPURLResponse,
        extra: String? = nil
    ) {
        let retryAfter = DiagnosticLog.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        var line = "endpoint=\(endpoint) status=\(status) retry-after=\(retryAfter)"
        if let extra {
            line += " " + extra
        }
        diagnostic(line)
    }

    private static func defaultClaudeBinaryLocator() -> String? {
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude"
        ]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // Fall back to `which` for other installation paths (e.g. nvm, custom prefix).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private static func defaultCLIExecutor(binaryPath: String, arguments: [String]) -> ClaudeCLIExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments

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
