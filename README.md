# Coding AI Usage

> A lightweight, native macOS menu bar app that keeps your **Claude Code**, **OpenAI Codex**, and **Windsurf** usage visible at all times.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

---

## What It Looks Like

**Menu bar** (always visible):
```
CC 5h% 50 | w% 63  CX 5h% 99 | w% 89  W d% 99 | w% 81
```
- `CC` = Claude Code (purple badge), `CX` = Codex (teal badge), `W` = Windsurf (blue badge)
- `5h%` = 5-hour window remaining, `d%` = daily window remaining, `w%` = weekly window remaining
- Numbers are color-coded: **green** (≥ 30%), **yellow** (10–30%), **red** (< 10%)

**Dropdown panel** (click to expand): detailed progress bars, reset countdowns, and error messages.

---

## Features

- **Real-time usage tracking** for Claude Code, OpenAI Codex, and Windsurf
- **Compact status bar** showing remaining percentages at a glance
- **Detailed dropdown** with progress bars and reset timers
- **Windsurf footer metadata** for plan end date and extra usage balance
- **Local-first Windsurf parsing** from cached app state, with a scrape fallback only when exact quotas are missing
- **Smart alerts** via macOS notifications when usage drops below a configurable threshold (default: 10%)
- **Configurable polling** intervals: 3 min, 5 min (default), 10 min, 30 min, 1 hour
- **Manual refresh** button for on-demand updates
- **Automatic rate limit handling** with exponential backoff
- **Launch at Login** support
- **Error reporting** in red text when services are unavailable

---

## Prerequisites

Before installing, make sure you have:

| Requirement | How to Check | How to Install |
|---|---|---|
| **macOS 14.0+** (Sonoma or later) | Apple menu > About This Mac | Update via System Settings |
| **Xcode Command Line Tools** | `xcode-select -p` | `xcode-select --install` |
| **Claude Code CLI** | `which claude` | [Install Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) |
| **OpenAI Codex CLI** | `which codex` | [Install Codex](https://github.com/openai/codex) |
| **Windsurf** | `ls /Applications/Windsurf.app` | [Install Windsurf](https://windsurf.com/) |

**All services must be logged in:**
```bash
# Claude Code - run and complete the OAuth login flow
claude

# Codex - authenticate with your ChatGPT account
codex login
```

For Windsurf, open the app and sign in normally. The app reads Windsurf's local state first, including cached quota data from `state.vscdb`, and only falls back to an experimental session-backed scrape when exact daily or weekly quotas are not present locally.

---

## Installation

### Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/ovidiuadorian-yonder/Coding-AI-Usage.git
cd Coding-AI-Usage

# 2. Build the app
chmod +x build.sh
./build.sh

# 3. Run it
open "Coding AI Usage.app"
```

That's it! You should see `CC 5h% ... | w% ...  CX 5h% ... | w% ...  W d% ... | w% ...` appear in your menu bar within a few seconds.

### Install to Applications (Optional)

To keep it permanently and have it available in Launchpad:

```bash
cp -r "Coding AI Usage.app" /Applications/
```

Then launch it from `/Applications` or Spotlight.

### Uninstall

```bash
# Remove the app
rm -rf /Applications/Coding\ AI\ Usage.app

# (Optional) Remove preferences
defaults delete com.ovidiuadorian.CodingAIUsage
```

---

## First Run

On the first launch, macOS will prompt you for permissions:

1. **Keychain Access** - The app reads your Claude Code OAuth token from the macOS Keychain. Click **"Always Allow"** to avoid being prompted every time.

2. **Notifications** (optional) - Allow notifications to receive alerts when your usage is running low.

> **Tip:** If you accidentally clicked "Deny" on the Keychain prompt, you can reset it by opening **Keychain Access.app**, finding the `Claude Code-credentials` entry, and removing the app from its Access Control list. The app will prompt again on the next refresh.

---

## How to Use

### Menu Bar

The status bar text updates automatically based on your polling interval:

| Display | Meaning |
|---|---|
| `CC 5h% 50 \| w% 63  CX 5h% 99 \| w% 89  W d% 99 \| w% 81` | All services enabled with usage data |
| `CC 5h% 50 \| w% 63` | Only Claude Code enabled |
| `CX 5h% 99 \| w% 89` | Only Codex enabled |
| `W d% 99 \| w% 81` | Only Windsurf enabled |
| `Coding Usage` | No services enabled or no data yet |

- **5h%** = percentage remaining in the 5-hour rolling window
- **d%** = percentage remaining in the daily window
- **w%** = percentage remaining in the 7-day weekly window
- Numbers in **green** = healthy (≥ 30% remaining)
- Numbers in **yellow** = warning (10–30% remaining)
- Numbers in **red** = critical (< 10% remaining)

### Dropdown Panel

Click the menu bar text to open the detail panel:

- **Progress bars** for each time window with color coding
- **Reset timers** showing when each window resets
- **Refresh** - manually trigger an update (resets any rate limit backoff)
- **Settings** - configure services, polling, alerts, and launch at login
- **About** - app info and credits
- **Exit** - quit the app

### Settings

| Setting | Options | Default |
|---|---|---|
| **Services** | Toggle Claude Code / Codex / Windsurf on or off | All enabled |
| **Polling Interval** | 3 min, 5 min, 10 min, 30 min, 1 hour | 5 minutes |
| **Alert Threshold** | 5% to 30% | 10% |
| **Launch at Login** | On / Off | Off |

---

## How It Works

The app reads locally stored credentials and usage state:

| Service | Credentials Source | API Endpoint |
|---|---|---|
| **Claude Code** | macOS Keychain (`Claude Code-credentials`) | `api.anthropic.com/api/oauth/usage` |
| **Codex** | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |
| **Windsurf** | `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb` | Local cached user-status protobuf in `windsurfAuthStatus` / `codeium.windsurf`, with experimental session-backed scrape of `windsurf.com/subscription/usage` only as a fallback |

- **No passwords or API keys are stored by the app** - it reads existing credentials that the CLI tools have already saved
- **Windsurf exact daily/weekly quotas are required** - billing-cycle-only cache data is not shown in the compact menu bar
- **Windsurf local source order** - cached user-status protobuf first, cached JSON snapshot second, experimental authenticated scrape last
- Polling happens on a timer with automatic **exponential backoff** when rate-limited (capped at 30 minutes)
- Clicking **Refresh** resets any backoff and retries immediately

---

## Permissions

| Permission | Why | When Prompted |
|---|---|---|
| **Keychain Access** | Read Claude Code OAuth token | First refresh |
| **Network** | HTTPS to `api.anthropic.com`, `chatgpt.com`, and `windsurf.com` | Automatic |
| **Notifications** | Low-usage alerts | First launch |
| **File System** (`~/.codex/`) | Read Codex auth token | Automatic |
| **File System** (`~/Library/Application Support/Windsurf/`) | Read Windsurf state DB and fallback cookies | Automatic |

The app is **not sandboxed** by design. It needs cross-app Keychain access and filesystem access to `~/.codex/` that macOS sandboxing would block. This is the same approach used by other developer tools like CodexBar and Claude-Usage-Tracker.

---

## Troubleshooting

| Error Message | Cause | Fix |
|---|---|---|
| `Claude Code not installed` | `claude` CLI not found in PATH | [Install Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) |
| `Claude Code: not logged in` | No OAuth token in Keychain | Run `claude` and complete the login flow |
| `Claude Code: session expired` | OAuth token expired | Re-login: run `claude` in terminal |
| `Claude Code: rate limited` | Anthropic API rate limiting | Automatic retry; click Refresh to retry now |
| `Codex not installed` | `codex` CLI not found in PATH | [Install Codex CLI](https://github.com/openai/codex) |
| `Codex: not logged in` | No auth token in `~/.codex/auth.json` | Run `codex login` |
| `Codex: session expired` | ChatGPT OAuth token expired | Run `codex login` to re-authenticate |
| `Windsurf not installed` | Windsurf app support files not found | Install and open Windsurf |
| `Windsurf: not logged in` | No Windsurf auth state in the local state DB | Sign in inside Windsurf |
| `Windsurf: daily/weekly quota unavailable` | Exact daily/weekly quotas were missing from local cached state and the fallback scrape could not recover them | Open Windsurf, let the Plan Info page load, then refresh |
| Keychain prompt every time | Clicked "Allow" instead of "Always Allow" | Open Keychain Access, find `Claude Code-credentials`, update Access Control |
| No data showing | First poll hasn't completed yet | Wait a few seconds or click Refresh |

---

## Building from Source

### Requirements

- macOS 14.0+ (Sonoma)
- Swift 5.9+ (included with Xcode 15+)

### Build

```bash
# Debug build (faster, for development)
swift build

# Release build + app bundle (for distribution)
./build.sh
```

### Project Structure

```
CodingAIUsage/
├── CodingAIUsageApp.swift         # App entry point with MenuBarExtra
├── Info.plist                      # App bundle config (LSUIElement=YES)
├── Models/
│   ├── UsageData.swift             # Core types: UsageWindow, ServiceUsage, UsageLevel
│   ├── ClaudeUsageResponse.swift   # Anthropic API response model
│   ├── CodexUsageData.swift        # ChatGPT API response model
│   └── WindsurfUsageData.swift     # Windsurf cache, protobuf, and page parsing models
├── Services/
│   ├── KeychainService.swift       # macOS Keychain reader
│   ├── ClaudeUsageService.swift    # Claude API client
│   ├── CodexUsageService.swift     # Codex API client
│   ├── WindsurfUsageService.swift  # Windsurf local state reader + fallback usage scraper
│   ├── NotificationService.swift   # Alert notifications
│   └── PollingScheduler.swift      # Timer with exponential backoff
├── ViewModels/
│   └── UsageViewModel.swift        # Central state management
└── Views/
    ├── MenuBarLabel.swift          # Status bar text
    ├── UsageDetailView.swift       # Dropdown panel
    ├── ServiceRowView.swift        # Progress bars per service
    ├── SettingsView.swift          # Preferences
    └── AboutView.swift             # Credits
```

---

## Credits

Created by **Ovidiu Adorian**

Built with Swift and SwiftUI. No third-party dependencies.

## License

MIT - see [LICENSE](LICENSE) for details.
