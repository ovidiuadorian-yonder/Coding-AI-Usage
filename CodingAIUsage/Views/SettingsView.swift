import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    let onDone: () -> Void

    private let pollingOptions: [(String, Double)] = [
        ("3 minutes", 180),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("30 minutes", 1800),
        ("1 hour", 3600)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.bold())

            Text(viewModel.enabledServicesSummary)
                .font(.caption)
                .foregroundColor(.secondary)

            // Services
            GroupBox("Services") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Claude Code", isOn: $viewModel.showClaude)
                    Toggle("Codex", isOn: $viewModel.showCodex)
                    Toggle("Windsurf", isOn: $viewModel.showWindsurf)
                }
                .padding(.vertical, 4)
            }

            // Polling
            GroupBox("Polling Interval") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Refresh every:", selection: $viewModel.pollingIntervalSeconds) {
                        ForEach(pollingOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: viewModel.pollingIntervalSeconds) { _, newValue in
                        viewModel.updatePollingInterval(newValue)
                    }
                }
                .padding(.vertical, 4)
            }

            // Alert threshold
            GroupBox("Alert Threshold") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Notify when remaining below:")
                        Spacer()
                        Text("\(Int(viewModel.alertThreshold * 100))%")
                            .monospacedDigit()
                    }
                    Slider(value: $viewModel.alertThreshold, in: 0.05...0.30, step: 0.05)
                }
                .padding(.vertical, 4)
            }

            // Launch at login
            GroupBox("General") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)

                    if viewModel.showClaude {
                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Button("Re-login Claude Code") {
                                reauthenticateClaude()
                            }

                            Text("Opens Terminal and starts `claude auth login --claudeai`. Use this when Claude refresh reports an auth or session problem.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Remark
            Text("Claude Code, Codex, and Windsurf must be installed and logged in for usage tracking to work. Windsurf daily and weekly quotas use cached local state first, then an experimental session-backed scrape only if exact quota data is missing.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func reauthenticateClaude() {
        viewModel.reauthenticateClaude()
    }
}
