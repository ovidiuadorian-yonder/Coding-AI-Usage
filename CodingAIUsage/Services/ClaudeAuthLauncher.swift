import Foundation

struct ClaudeAuthLauncher {
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
