import SwiftUI

struct UsageDetailView: View {
    private enum ActivePanel {
        case main
        case settings
        case about
    }

    @ObservedObject var viewModel: UsageViewModel
    @State private var activePanel: ActivePanel = .main

    var body: some View {
        Group {
            switch activePanel {
            case .main:
                mainPanel
            case .settings:
                SettingsView(viewModel: viewModel) {
                    activePanel = .main
                }
            case .about:
                AboutView {
                    activePanel = .main
                }
            }
        }
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Coding AI Usage")
                    .font(.title3.bold())
                Spacer()
                if viewModel.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Button(action: { activePanel = .about }) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("About Coding AI Usage")
                .help("Open app information")
            }

            Divider()

            // Service usage details
            ForEach(viewModel.displayedServices) { usage in
                serviceSection(for: usage)
            }

            if !viewModel.showClaude && !viewModel.showCodex && !viewModel.showWindsurf {
                Text("No services enabled. Enable Claude Code, Codex, or Windsurf in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Errors
            if !viewModel.globalErrors.isEmpty {
                Divider()
                ForEach(viewModel.globalErrors, id: \.self) { error in
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Single updated label
            if let lastUpdated = viewModel.lastUpdated {
                Text("Updated (every \(viewModel.pollingIntervalLabel)) \(lastUpdated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Buttons
            HStack {
                Button(action: { viewModel.manualRefresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isRefreshing)
                .help("Refresh usage now")

                Spacer()

                Button(action: { activePanel = .settings }) {
                    Label("Settings", systemImage: "gear")
                }
                .help("Open settings")

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Exit", systemImage: "xmark.circle")
                }
                .help("Quit Coding AI Usage")
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .frame(minWidth: 320, idealWidth: 340, maxWidth: 420, alignment: .leading)
    }

    private func serviceSection(for usage: ServiceUsage) -> some View {
        GroupBox(usage.displayName) {
            ServiceRowView(usage: usage, showsTitle: false)
        }
    }
}
