import Foundation

actor CodexUsageService {
    private let authFilePath = NSHomeDirectory() + "/.codex/auth.json"
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetchUsage() async throws -> ServiceUsage {
        guard let auth = readAuthFile() else {
            throw UsageError.noCredentials("Codex: not logged in")
        }

        guard let accessToken = auth.tokens?.accessToken else {
            throw UsageError.noCredentials("Codex: no access token found")
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            return usage.toServiceUsage()
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

    func isLoggedIn() -> Bool {
        readAuthFile()?.tokens?.accessToken != nil
    }
}
