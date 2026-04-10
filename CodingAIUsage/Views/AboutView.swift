import SwiftUI

struct AboutView: View {
    let onClose: () -> Void

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Coding AI Usage")
                .font(.title.bold())

            Text(versionText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            Text("Track Claude Code, Codex, and Windsurf usage directly from the macOS menu bar.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Divider()

            VStack(spacing: 4) {
                Text("Created by")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Ovidiu Adorian")
                    .font(.headline)
            }

            Button("Close") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 380)
    }
}
