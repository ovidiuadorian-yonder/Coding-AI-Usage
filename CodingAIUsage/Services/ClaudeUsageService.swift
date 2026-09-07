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

    private let credentialLoader: ClaudeCredentialLoader
    private let networkClient: NetworkClient
    private let diagnostic: DiagnosticRecorder
    private let cliExecutor: CLIExecutor
    private let claudeBinaryLocator: BinaryLocator
    private let cliParser = ClaudeCLIUsageParser()
    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
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
        // A credentials *file* is preferred when one exists: reading it needs no Keychain ACL, so
        // it cannot prompt, and the JSON API carries more than the CLI screen does. On macOS no
        // such file normally exists — Claude Code keeps credentials in the Keychain, which this
        // app deliberately never reads — so the CLI is the working path here.
        if let credentials = try credentialLoader.loadCredentials(),
           !credentialLoader.isExpired(credentials) {
            do {
                return try await performUsageRequest(accessToken: credentials.accessToken)
            } catch let error as UsageError {
                guard case .authExpired = error else { throw error }

                // A 401 can simply mean the CLI rotated the file token since we cached it. Re-read
                // once and retry; a file read costs nothing and cannot prompt for Keychain access.
                // `performUsageRequest` already invalidated the cache, so this reload hits disk.
                guard let reloaded = try credentialLoader.loadCredentials(forceRefresh: true),
                      reloaded.accessToken != credentials.accessToken else {
                    throw error
                }
                return try await performUsageRequest(accessToken: reloaded.accessToken)
            }
        }

        // An expired file token falls through rather than being refreshed. Refreshing would
        // present a grant the `claude` CLI also owns and rotates, which is what produced the
        // observed 429s from the token endpoint.
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
            credentialLoader.invalidateCache()
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

    /// Emits one machine-greppable line per logged response, tagged with the endpoint that produced
    /// it. `endpoint=usage` is api.anthropic.com; `endpoint=token` is platform.claude.com.
    ///
    /// Every line shares the shape `endpoint=… status=… retry-after=… [extra]`, so a single parser
    /// covers all of them — including the successful-refresh line carrying the rotation signal.
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
