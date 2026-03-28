import Foundation

actor CodexUsageService {
    private let authFilePath = NSHomeDirectory() + "/.codex/auth.json"
    // Codex usage endpoint - attempt ChatGPT-based usage API
    private let usageURL = URL(string: "https://api.openai.com/v1/usage")!

    func fetchUsage() async throws -> ServiceUsage {
        guard let auth = readAuthFile() else {
            throw UsageError.noCredentials("Codex: not logged in")
        }

        guard let accessToken = auth.tokens?.accessToken else {
            throw UsageError.noCredentials("Codex: no access token found")
        }

        // Try the OpenAI usage API with the ChatGPT OAuth token
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.networkError("Codex: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            // Try to parse as CodexUsageResponse
            if let usage = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) {
                return usage.toServiceUsage()
            }
            // If the response format is different, return a basic service usage
            return ServiceUsage(
                id: "codex",
                displayName: "Codex",
                shortLabel: "CX",
                windows: [],
                lastUpdated: Date(),
                error: "Codex: usage data format not supported"
            )
        case 401:
            throw UsageError.authExpired("Codex: session expired - please re-login in Codex CLI")
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.httpError(httpResponse.statusCode)
        }
    }

    private func readAuthFile() -> CodexAuthFile? {
        guard let data = FileManager.default.contents(atPath: authFilePath) else {
            return nil
        }
        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    func checkInstalled() -> Bool {
        let paths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) { return true }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func isLoggedIn() -> Bool {
        readAuthFile()?.tokens?.accessToken != nil
    }
}
