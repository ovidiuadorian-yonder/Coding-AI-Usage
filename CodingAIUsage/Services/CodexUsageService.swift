import Foundation

protocol CodexUsageServing: Sendable {
    func fetchUsage() async throws -> ServiceUsage
    func checkInstalled() async -> Bool
    func isLoggedIn() async -> Bool
}

actor CodexUsageService: CodexUsageServing {
    typealias NetworkClient = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let authFilePath: String
    private let networkClient: NetworkClient
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    init(
        authFilePath: String = NSHomeDirectory() + "/.codex/auth.json",
        networkClient: @escaping NetworkClient = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.authFilePath = authFilePath
        self.networkClient = networkClient
    }

    func fetchUsage() async throws -> ServiceUsage {
        guard let auth = readAuthFile() else {
            throw UsageError.noCredentials("Codex: not logged in")
        }

        guard let accessToken = auth.tokens?.accessToken else {
            throw UsageError.noCredentials("Codex: no access token found")
        }

        let request = makeRequest(url: usageURL, accessToken: accessToken)

        // Both requests need only the access token, so run them concurrently.
        // The reset-credits leg is only awaited on the 200 path; on any error
        // path it is left unawaited and Swift cancels it automatically.
        async let resetCreditsTask = fetchResetCredits(accessToken: accessToken)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await networkClient(request)
        } catch {
            throw UsageError.networkError("Codex: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            let resetCredits = await resetCreditsTask
            return usage.toServiceUsage(resetCredits: resetCredits)
        case 401, 403:
            throw UsageError.authExpired("Codex: session expired - run 'codex login' to re-authenticate")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.httpError(httpResponse.statusCode)
        }
    }

    /// Best-effort: reset credits enrich the usage display with expirations,
    /// but their absence must never fail the refresh (the usage response
    /// still carries the bare available count as a fallback).
    private func fetchResetCredits(accessToken: String) async -> CodexResetCreditsResponse? {
        let request = makeRequest(url: resetCreditsURL, accessToken: accessToken)

        guard
            let (data, response) = try? await networkClient(request),
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            return nil
        }

        return try? JSONDecoder().decode(CodexResetCreditsResponse.self, from: data)
    }

    private func makeRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    private func readAuthFile() -> CodexAuthFile? {
        guard let data = FileManager.default.contents(atPath: authFilePath) else {
            return nil
        }
        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    func checkInstalled() async -> Bool {
        let paths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) { return true }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
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

    func isLoggedIn() async -> Bool {
        readAuthFile()?.tokens?.accessToken != nil
    }
}
