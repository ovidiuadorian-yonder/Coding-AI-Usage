import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    let onDone: () -> Void

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.notificationsEnabled },
            set: { viewModel.setNotificationsEnabled($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { viewModel.launchAtLogin },
            set: { viewModel.setLaunchAtLogin($0) }
        )
    }

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

            // Refresh behavior
            GroupBox("Refresh") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage is fetched only when you open this menu or click Refresh. Menu opens are throttled, and recent Claude Code snapshots are reused for 15 minutes to avoid API rate limits. There is no background polling.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    Toggle("Enable Low-Usage Notifications", isOn: notificationsBinding)
                    Text("Notifications stay off until you explicitly enable them here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Launch at Login", isOn: launchAtLoginBinding)

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
        .frame(minWidth: 360, idealWidth: 380, maxWidth: 440)
    }

    private func reauthenticateClaude() {
        viewModel.reauthenticateClaude()
    }
}
