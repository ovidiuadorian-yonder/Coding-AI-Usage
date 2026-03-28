# Coding AI Usage

A native macOS menu bar app that shows your **Claude Code** and **OpenAI Codex** usage at a glance.

## Features

- **Status bar display**: Shows remaining usage percentages for 5-hour and weekly windows
  - Format: `CC %5h 25 %W 12  CX %5h 80 %W 45`
  - Green text when >= 10% remaining, **red when below 10%**
- **Dropdown panel**: Detailed usage with progress bars and reset times
- **Alerts**: macOS notifications when usage drops below configurable threshold (default 10%)
- **Configurable polling**: 3 min, 5 min (default), 10 min, 30 min, or 1 hour
- **Manual refresh**: Refresh on demand from the dropdown
- **Launch at Login**: Optional auto-start
- **Error reporting**: Red error messages when services are not installed or not logged in

## Prerequisites

- **macOS 14.0+** (Sonoma or later)
- **Xcode 15+** or Swift 5.9+ toolchain (for building from source)
- **Claude Code** installed and logged in (`claude` CLI in PATH)
- **OpenAI Codex** installed and logged in (`codex` CLI in PATH)

Both tools must be authenticated for usage tracking to work. The app reads credentials from:
- Claude Code: macOS Keychain (service: `Claude Code-credentials`)
- Codex: `~/.codex/auth.json`

## Installation

### Build from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/ovidiuadorian-yonder/Coding-AI-Usage.git
   cd Coding-AI-Usage
   ```

2. Build the app:
   ```bash
   chmod +x build.sh
   ./build.sh
   ```

3. Run the app:
   ```bash
   open "Coding AI Usage.app"
   ```

4. (Optional) Install to Applications:
   ```bash
   cp -r "Coding AI Usage.app" /Applications/
   ```

### First Run

On first launch, macOS may prompt you for:

1. **Keychain Access**: The app needs to read Claude Code credentials from the macOS Keychain. Click "Allow" or "Always Allow" when prompted.
2. **Notifications**: Allow notifications to receive alerts when usage is low.

## Permissions

| Permission | Why | Required |
|---|---|---|
| Keychain Access | Read Claude Code OAuth token | Yes (for Claude) |
| Network | Fetch usage data from Anthropic/OpenAI APIs | Yes |
| Notifications | Alert when usage drops below threshold | Optional |
| File System (`~/.codex/`) | Read Codex authentication file | Yes (for Codex) |

The app is **not sandboxed** by design - it needs cross-app Keychain access and filesystem access to `~/.codex/` that sandboxing would prevent.

## Settings

Click the menu bar item, then click **Settings** to configure:

- **Services**: Enable/disable Claude Code and Codex tracking
- **Polling Interval**: How often to check usage (3m / 5m / 10m / 30m / 1h)
- **Alert Threshold**: Notification trigger point (5% to 30%)
- **Launch at Login**: Start automatically when you log in

## How It Works

The app polls the following APIs:

- **Claude Code**: `GET https://api.anthropic.com/api/oauth/usage` using the OAuth token from macOS Keychain
- **Codex**: OpenAI usage API using the access token from `~/.codex/auth.json`

Rate limiting is handled automatically with exponential backoff (up to 30 minutes).

## Troubleshooting

| Error | Solution |
|---|---|
| "Claude Code not installed" | Install Claude Code CLI and ensure `claude` is in your PATH |
| "Claude Code: not logged in" | Run `claude` and complete the login flow |
| "Codex not installed" | Install Codex CLI and ensure `codex` is in your PATH |
| "Codex: not logged in" | Run `codex login` to authenticate |
| "Rate limited" | The app will automatically back off and retry |
| Keychain prompt keeps appearing | Click "Always Allow" to permanently grant access |

## Credits

Created by **Ovidiu Adorian**

## License

MIT
