import Foundation

struct ClaudeAuthLauncher {
    // Intentionally uses a login shell so the Terminal window inherits the user's full PATH
    // and environment. This is the opposite of the CLI usage probe, which runs the binary
    // directly to avoid shell startup overhead and side effects.
    static let reauthCommand = "/bin/zsh -lc 'claude auth login --claudeai'"

    static func appleScript(command: String = reauthCommand) -> String {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """
    }

    func launchReauthentication() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.appleScript()]
        try process.run()
    }
}
