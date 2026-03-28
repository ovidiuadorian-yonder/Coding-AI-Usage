import Foundation

actor ClaudeUsageService {
    private let keychainService = KeychainService()
    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetchUsage() async throws -> ServiceUsage {
        guard let token = keychainService.getClaudeOAuthToken() else {
            throw UsageError.noCredentials("Claude Code: not logged in")
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
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
        case 401:
            throw UsageError.authExpired("Claude Code: session expired - please re-login in Claude Code")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.httpError(httpResponse.statusCode)
        }
    }

    func checkInstalled() -> Bool {
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude"
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) { return true }
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
}
