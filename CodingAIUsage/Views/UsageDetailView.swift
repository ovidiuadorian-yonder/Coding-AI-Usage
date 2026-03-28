import SwiftUI

struct UsageDetailView: View {
    @ObservedObject var viewModel: UsageViewModel
    @State private var showSettings = false
    @State private var showAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Coding AI Usage")
                    .font(.title3.bold())
                Spacer()
                if viewModel.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            Divider()

            // Service usage details
            if let claude = viewModel.claudeUsage, viewModel.showClaude {
                ServiceRowView(usage: claude)
            }

            if let codex = viewModel.codexUsage, viewModel.showCodex {
                ServiceRowView(usage: codex)
            }

            if !viewModel.showClaude && !viewModel.showCodex {
                Text("No services enabled. Enable Claude Code or Codex in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Errors
            if !viewModel.errors.isEmpty {
                Divider()
                ForEach(viewModel.errors, id: \.self) { error in
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Divider()

            // Buttons
            HStack {
                Button(action: { viewModel.manualRefresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isRefreshing)

                Spacer()

                Button(action: { showSettings = true }) {
                    Label("Settings", systemImage: "gear")
                }

                Button(action: { showAbout = true }) {
                    Label("About", systemImage: "info.circle")
                }

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Exit", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .frame(width: 320)
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
    }
}
