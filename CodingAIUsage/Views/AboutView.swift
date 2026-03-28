import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Coding AI Usage")
                .font(.title.bold())

            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            Text("Track your Claude Code and Codex usage directly from the macOS menu bar.")
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

            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 300)
    }
}
