# Coding AI Usage

> A lightweight, native macOS menu bar app that keeps your **Claude Code**, **OpenAI Codex**, and **Devin** (formerly Windsurf) usage visible at all times.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)

---

## What It Looks Like

**Menu bar** (always visible):
```
CC 5h% 50 | w% 63  CX 5h% 99 | w% 89  W d% 99 | w% 81
```
- `CC` = Claude Code (purple badge), `CX` = Codex (teal badge), `D` = Devin (blue badge)
- `5h%` = 5-hour window remaining, `d%` = daily window remaining, `w%` = weekly window remaining
- Numbers are color-coded: **green** (≥ 30%), **yellow** (10–30%), **red** (< 10%)

**Dropdown panel** (click to expand): detailed progress bars, reset countdowns, and error messages.

---

## Features

- **Real-time usage tracking** for Claude Code, OpenAI Codex, and Devin
- **Compact status bar** showing remaining percentages at a glance
- **Detailed dropdown** with progress bars and reset timers
- **Devin footer metadata** for plan end date and extra usage balance
- **No Keychain access at all** - the app never reads a Keychain item, so it never asks for your login password
- **Local-first Devin parsing** from the client's cached app state, with stale sources rejected rather than shown as current
- **Smart alerts** via macOS notifications when usage drops below a configurable threshold (default: 10%)
- **On-demand refresh only** - usage is fetched when you open the menu (throttled to once a minute) or click Refresh; there is no background polling
- **Manual refresh** button for on-demand updates
- **Cached last-known usage** restored on relaunch before the first refresh
- **Rate limit aware** - menu-open refreshes pause until a reported `Retry-After` expires
- **Launch at Login** support
- **Error reporting** in red text when services are unavailable

---

## Prerequisites

Before installing, make sure you have:

| Requirement | How to Check | How to Install |
|---|---|---|
| **macOS 14.0+** (Sonoma or later) | Apple menu > About This Mac | Update via System Settings |
| **Xcode Command Line Tools** | `xcode-select -p` | `xcode-select --install` |
| **Self-signed code-signing cert** (build-from-source only) | `security find-identity -v -p codesigning \| grep "Coding AI Usage Self-Signed"` | See "Code Signing" below |
| **Claude Code CLI** | `which claude` | [Install Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) |
| **OpenAI Codex CLI** | `which codex` | [Install Codex](https://github.com/openai/codex) |
| **Devin** (formerly Windsurf) | `ls /Applications/Devin.app` | [Install Devin](https://devin.ai/desktop) |

**All services must be logged in:**
```bash
# Claude Code - run and complete the OAuth login flow
claude

# Codex - authenticate with your ChatGPT account
codex login
```

For Devin, open the app and sign in normally. The app reads the client's local `state.vscdb`, auto-detecting whichever of `~/Library/Application Support/Devin/` or `.../Windsurf/` was written most recently, so both the current client and a pre-rebrand install work. Sources whose billing period has already ended are discarded rather than displayed, so a leftover directory from before the rebrand cannot serve months-old numbers as current.

---

## Code Signing (one-time, build-from-source)

`build.sh` signs the bundle with a **stable self-signed identity**, and fails loudly if that
identity is missing, so it is still a build prerequisite.

> **Note:** signing used to exist to keep a Keychain "Always Allow" grant alive across rebuilds.
> That reason is gone - the app no longer reads any Keychain item (see
> [How It Works](#how-it-works)). Signing is retained for a stable app identity; it is no longer
> load-bearing for credentials.

Create the identity once (free, no Apple Developer account):

1. Open **Keychain Access.app**
2. Menu: **Keychain Access > Certificate Assistant > Create a Certificate…**
3. Name: `Coding AI Usage Self-Signed` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing**
4. Click **Create** and keep it in the **login** keychain.

If you have an Apple Developer ID, use it instead:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./deploy.sh
```

Switching identities no longer causes any credential prompt, because no Keychain item is read.

---

## Installation

### Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/ovidiuadorian-yonder/Coding-AI-Usage.git
cd Coding-AI-Usage

# 2. Build, install, and launch the app
chmod +x deploy.sh
./deploy.sh
```

That's it. On a fresh install, the dropdown shows placeholder rows until you click **Refresh** once. After the first successful refresh, the app restores the last cached snapshot on relaunch without touching protected resources first.

If you need more granular control, `./build.sh` only creates the local `.app` bundle without installing or launching it.

### Install to Applications (Optional)

`./deploy.sh` force-stops any running copy, installs the app into `/Applications`, and launches it again.

If you only want the raw `.app` bundle without installing it, use:

```bash
./build.sh
```

### Uninstall

```bash
# Remove the app
rm -rf /Applications/Coding\ AI\ Usage.app

# (Optional) Remove preferences
defaults delete com.ovidiuadorian.CodingAIUsage
```

---

## First Run

On the first launch, macOS may prompt you for one permission:

1. **Notifications** (optional) - Allow notifications to receive alerts when your usage is running low.

**There is no Keychain prompt.** The app reads no Keychain items. If you used an earlier version
and granted it access to `Claude Code-credentials`, that grant is now unused and you can remove
the app from that item's Access Control list in **Keychain Access.app**.

> **Startup behavior:** The app does not read Codex auth or Devin state automatically on launch.
> It waits for a manual refresh, then caches the last successful snapshot so later relaunches can
> show the previous usage immediately.

---

## How to Use

### Menu Bar

The status bar text updates whenever a refresh runs (opening the dropdown or clicking Refresh):

| Display | Meaning |
|---|---|
| `CC 5h% 50 \| w% 63  CX 5h% 99 \| w% 89  D d% 99 \| w% 81` | All services enabled with usage data |
| `CC 5h% 50 \| w% 63` | Only Claude Code enabled |
| `CX 5h% 99 \| w% 89` | Only Codex enabled |
| `D d% 99 \| w% 81` | Only Devin enabled |
| `Coding Usage` | No services enabled or no data yet |

- **5h%** = percentage remaining in the 5-hour rolling window
- **d%** = percentage remaining in the daily window
- **w%** = percentage remaining in the 7-day weekly window
- Numbers in **green** = healthy (≥ 30% remaining)
- Numbers in **yellow** = warning (10–30% remaining)
- Numbers in **red** = critical (< 10% remaining)

### Dropdown Panel

Click the menu bar text to open the detail panel. Opening the panel triggers a refresh (at most once a minute, and never while a provider rate limit is active). Claude Code snapshots under 15 minutes old are reused on menu-open refreshes to avoid hitting Anthropic's usage API too often:

- **Progress bars** for each time window with color coding
- **Reset timers** showing when each window resets
- **Weekly Opus / Sonnet** sub-limits shown as footer lines under Claude Code when your plan reports them
- **Refresh** - manually trigger an update, unlock protected-resource reads for this app session, and bypass the menu-open throttle
- **Settings** - configure services, alerts, and launch at login
- **About** - app info and credits
- **Exit** - quit the app

### Settings

| Setting | Options | Default |
|---|---|---|
| **Services** | Toggle Claude Code / Codex / Devin on or off | All enabled |
| **Alert Threshold** | 5% to 30% | 10% |
| **Launch at Login** | On / Off | Off |

---

## How It Works

The app reads locally stored credentials and usage state:

| Service | Source | Endpoint |
|---|---|---|
| **Claude Code** | `claude /usage` (the CLI reads its own credential) | none - local process |
| **Codex** | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |
| **Devin** | `~/Library/Application Support/{Devin,Windsurf}/User/globalStorage/state.vscdb` - whichever was written most recently | none - local `windsurfAuthStatus` / `codeium.windsurf` state |

- **No passwords or API keys are stored by the app** - it reads state the CLI tools and clients have already saved
- **The app reads no Keychain items, and never writes one.** Claude Code rewrites its credential item on every token refresh in a way that resets the item's access control list, so a third-party reader's "Always Allow" grant is destroyed several times a day ([claude-code#22144](https://github.com/anthropics/claude-code/issues/22144), closed as not planned). Rather than re-prompt you forever, the app asks the `claude` CLI for its usage screen and parses that - the CLI reads its own item with its own grant
- **Claude usage comes from `claude /usage`** (~3s per probe). If a credentials *file* exists at `~/.claude/.credentials.json` it is preferred instead, since reading a file needs no Keychain access and the JSON API (`api.anthropic.com/api/oauth/usage`) carries more detail. That file does not normally exist on macOS
- **The app never refreshes an OAuth token.** It shares the credential with the `claude` CLI, and refreshing a grant the CLI also rotates rate-limits the token endpoint. The CLI owns refreshing; the app only reads
- **Stale local sources are discarded, not displayed.** A Devin/Windsurf source whose billing period has already ended is rejected rather than shown as current
- **A reset that has already passed is shown as overdue**, never as time remaining
- **Protected resources are deferred until you interact with the app** - the first read happens when you open the menu or click Refresh
- **Last known usage is cached locally** - successful refreshes are persisted and restored on relaunch, and a transient auth error annotates the row rather than wiping the cached reading
- **Devin exact daily/weekly quotas are required** - billing-cycle-only cache data is not shown in the compact menu bar
- **No background polling** - refreshes run only when you open the menu (throttled to once a minute, with a 15-minute Claude Code cache window) or click Refresh
- When a provider reports a rate limit, menu-open refreshes pause until the reported `Retry-After` expires (5 minutes if none is given); clicking **Refresh** retries immediately

---

## Permissions

| Permission | Why | When Prompted |
|---|---|---|
| **Notifications** | Low-usage alerts | First launch |
| **Network** | HTTPS to `chatgpt.com` (and `api.anthropic.com` only if a Claude credentials file exists) | First refresh and later manual/menu-open refreshes |
| **File System** (`~/.codex/`) | Read Codex auth token | First refresh and later manual/menu-open refreshes |
| **File System** (`~/Library/Application Support/{Devin,Windsurf}/`) | Read the Devin client state DB | First refresh and later manual/menu-open refreshes |
| **Subprocess** (`claude`) | Run `claude /usage` to read Claude Code usage | First refresh and later manual/menu-open refreshes |

**No Keychain permission is required or requested.** Earlier versions read
`Claude Code-credentials` directly and decrypted browser cookie jars for a Windsurf scrape
fallback; both were removed.

The app is **not sandboxed** by design: it needs filesystem access to `~/.codex/` and the client
state directories, and it spawns the `claude` CLI - all of which macOS sandboxing would block.

---

## Troubleshooting

| Error Message | Cause | Fix |
|---|---|---|
| `Claude Code not installed` | `claude` CLI not found in PATH | [Install Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) |
| `Claude Code: not logged in` | `claude /usage` reported no session, and no credentials file exists | Run `claude` and complete the login flow |
| `Claude Code: session expired` | The credentials file's token expired and the CLI could not be reached | Re-login: run `claude` in terminal |
| `Claude Code: rate limited` | Anthropic API rate limiting (only reachable via the credentials-file path) | Automatic backoff; click Refresh to retry now |
| `Codex not installed` | `codex` CLI not found in PATH | [Install Codex CLI](https://github.com/openai/codex) |
| `Codex: not logged in` | No auth token in `~/.codex/auth.json` | Run `codex login` |
| `Codex: session expired` | ChatGPT OAuth token expired | Run `codex login` to re-authenticate |
| `Devin not installed` | No Devin or Windsurf state database found | Install and open Devin |
| `Devin: not logged in` | No auth state in the client's local state DB | Sign in inside Devin |
| `Devin: daily/weekly quota unavailable` | Exact quotas were missing from local state, or every local source's billing period had already ended | Open Devin, let the Plan Info page load, then refresh |
| `Reset overdue` on a row | The client's stored reset timestamp is from its last quota sync, not the next reset | Expected; it is not an error |
| Only `Click Refresh to load usage.` is showing | No cached snapshot exists yet for this install | Click Refresh once to seed the cache |
| Relaunch shows old values | The app restores the last cached snapshot until the next successful refresh | Click Refresh to fetch current usage |

---

## Building from Source

### Requirements

- macOS 14.0+ (Sonoma)
- Swift 5.9+ (included with Xcode 15+)

### Build

```bash
# Debug build (faster, for development)
swift build

# Release build + sign + app bundle only
./build.sh

# Release build + install to /Applications + launch
./deploy.sh
```

Use `./build.sh` when you want the signed bundle only, without installing or launching it. (Requires the one-time self-signed certificate described in the [Code Signing](#code-signing-one-time-build-from-source) section above.)

### Project Structure

```
CodingAIUsage/
├── CodingAIUsageApp.swift         # App entry point with MenuBarExtra
├── Info.plist                      # App bundle config (LSUIElement=YES)
├── Models/
│   ├── UsageData.swift             # Core types: UsageWindow, ServiceUsage, UsageLevel
│   ├── ClaudeUsageResponse.swift   # Anthropic API response model
│   ├── CodexUsageData.swift        # ChatGPT API response model
│   └── WindsurfUsageData.swift     # Devin/Windsurf cache and protobuf models
├── Services/
│   ├── ClaudeUsageService.swift    # Claude API client
│   ├── CodexUsageService.swift     # Codex API client
│   ├── UsageCacheStore.swift       # Persist last-known service snapshots between launches
│   ├── WindsurfUsageService.swift  # Devin/Windsurf local state reader
│   └── NotificationService.swift   # Alert notifications
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
