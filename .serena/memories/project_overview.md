# AI-Usage-Plugin overview
- Purpose: native macOS menu bar app that shows usage/quota information for Claude Code, OpenAI Codex, and Windsurf.
- User-facing behavior: menu bar summary, dropdown details with progress bars and reset times, manual refresh, configurable polling and alerts, launch-at-login support.
- Platform: macOS 14+ only.
- Tech stack: Swift 5.9, SwiftUI/AppKit menu bar app, XCTest, SQLite3, Security, UserNotifications, ServiceManagement, WebKit.
- Packaging: Swift Package executable target named `CodingAIUsage`; app bundle is assembled manually by `build.sh`.
- Credential/data sources: Claude via Keychain and local Claude credential files, Codex via `~/.codex/auth.json`, Windsurf via local state database with a live scrape fallback.
- Important runtime assumption: app is intentionally not sandboxed because it needs filesystem and cross-app Keychain access.