# Claude Credentials Signing & Reset-Time Restoration — Design

**Date:** 2026-06-11
**Status:** Approved (pending spec review)
**Scope:** `Coding AI Usage` macOS menu-bar app — Claude Code service only

## Problem

Two user-reported problems, which share a root cause:

1. **Repeated Keychain prompts.** The user is asked to authorize Keychain access for
   `Claude Code-credentials` on (nearly) every refresh / redeploy.
2. **Missing "next reset".** The Claude Code row shows correct utilization percentages,
   but the reset countdown/timer is blank.

### Diagnosis (verified)

- The app bundle is **ad-hoc signed** (`codesign` reports `Signature=adhoc`,
  `flags=0x20002(adhoc,linker-signed)`) and `build.sh`/`deploy.sh` contain **no `codesign`
  step**. macOS binds a Keychain "Always Allow" grant to the app's code-signing identity.
  An ad-hoc signature's identity (cdhash) changes on every rebuild, so every `./deploy.sh`
  invalidates the grant → re-prompt. **The credential *storage* is fine; the app's *signing*
  is the problem.**
- Claude Code v2.1.173 stores its OAuth token **only** in the `Claude Code-credentials`
  Keychain item. No `~/.claude/.credentials.json` file exists on this machine, so the app's
  file-credential path is dead and it falls through to the CLI scraper / Keychain.
- "Percentages OK, no reset" indicates the **CLI scraper** (`ClaudeCLIUsageParser`) is
  serving the Claude row. The `claude /usage` output changed to human-local reset times
  (`Resets 9:40pm (Europe/Madrid)`) with **no ISO-8601 timestamp**. The parser's reset regex
  only matches `20XX-...` ISO strings, so it parses the percentage (`100% used`) but never a
  reset. Switching to the JSON API — whose `resets_at` field is unchanged — restores the reset.

### Research findings (current `/api/oauth/usage` shape, mid-2026)

Confirmed against `steipete/CodexBar` Swift source, `ohugonnot/claude-code-statusline`, and
`anthropics/claude-code` issues #54750 / #10165 / #55210.

- **`User-Agent: claude-code/<version>` header is required.** Without it the request lands in
  an aggressively rate-limited bucket and returns persistent 429s. Required headers:
  `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
  `User-Agent: claude-code/<version>`.
- **Window keys expanded** (all nullable, key names actively churning):
  `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `seven_day_oauth_apps`,
  `seven_day_routines` (aliases: `seven_day_cowork`, `claude_routines`), `extra_usage`.
- **Each window:** `{ "utilization": <0-100 number, may be fractional>, "resets_at": "<iso8601 or absent>" }`.
  `resets_at` is **unchanged** (ISO-8601 with offset, fractional seconds sometimes present),
  may be **absent** on some windows. Decode every window and every `resets_at` as optional.
- **`utilization` is 0–100** (not 0–1). Existing `/ 100.0` math is correct.
- `extra_usage`: `{ is_enabled, monthly_limit, used_credits, utilization, currency }` —
  `monthly_limit`/`used_credits` in **minor units** (cents). Out of scope for this change.
- **CLI `/usage` v2.1.x text format** (for the fallback parser): labels `Current session`,
  `Current week (all models)`, `Current week (Sonnet only)`, `Current week (Opus)`;
  percentages `N% used`; reset line `Resets <h:mma> (<IANA tz>)` with an optional leading
  `Mon DD,` / `MMM DD,` date token (date appears only when the reset is on a future day).
  No ISO timestamps, no relative countdown, no JSON output mode.

## Design

Four parts. A and B are the core fixes; C and D harden them.

### Part A — Stable code signing (fixes repeated prompts)

A stable signing identity keeps the app's designated requirement constant across rebuilds, so
the Keychain "Always Allow" grant persists.

- **One-time setup (documented in README):** create a self-signed code-signing certificate
  named `Coding AI Usage Self-Signed` via Keychain Access → Certificate Assistant → Create a
  Certificate → Certificate Type: *Code Signing*. (Manual creation is more reliable than
  scripting a valid code-signing identity.)
- **New `sign.sh`:** signs the assembled bundle with that identity:
  ```bash
  codesign --force --options runtime --sign "Coding AI Usage Self-Signed" "Coding AI Usage.app"
  ```
  - If the identity is missing, `sign.sh` prints clear instructions (the README steps) and
    exits non-zero so the build fails loudly rather than silently producing an ad-hoc bundle.
  - The identity name is overridable via an env var (e.g. `SIGN_IDENTITY`) so a user with a
    Developer ID can substitute it without editing the script.
- **`build.sh`:** call `sign.sh` as the final step, after the bundle is fully assembled
  (executable, Info.plist, icon copied) and before it reports "Build complete".
- **Verification:** after signing, `codesign -dvvv` should report the self-signed
  authority (not `adhoc`). The first refresh after switching identities will prompt once;
  subsequent rebuilds keep the grant.

### Part B — Make the JSON API the primary Claude source (restores reset)

- **Reorder `ClaudeUsageService.fetchUsage()`** to:
  1. File credentials → API (unchanged; still first if a file ever exists).
  2. **Keychain credentials → API** (promoted above the CLI).
  3. CLI scraper (`fetchUsageViaCLI`) — last-resort fallback only (see Part D).
  - If the Keychain item is missing and no file exists and the CLI yields nothing, the row
    shows `Claude Code: not logged in` as today.
- **Add `User-Agent` header** to both `performUsageRequest` and `refreshCredentials`:
  `claude-code/<version>`. Version source: pinned constant (`2.1.173`) is acceptable; if the
  installed `claude` version is cheaply discoverable it may be used, but a constant is the
  baseline requirement. This is mandatory to avoid 429 throttling.
- **Rewrite `ClaudeUsageResponse`** to decode the current shape with all fields optional:
  - Windows: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`,
    `seven_day_oauth_apps`, `seven_day_routines` (try alias keys `seven_day_cowork`,
    `claude_routines`). Each is an optional `WindowData { utilization: Double; resets_at: String? }`.
  - `extra_usage` decoded but not displayed (kept for forward-compat; out of scope to surface).
  - Missing/`null` windows simply produce no `UsageWindow`.
  - **Menu bar unchanged:** `5h%` from `five_hour`, `w%` from `seven_day` (all models).
  - **Dropdown:** additionally render `seven_day_opus` and `seven_day_sonnet` rows **only when
    present and non-null**. Keep it minimal — no new menu-bar fields.
  - Keep defensive `resets_at` parsing (`.withFractionalSeconds` then plain internet-date-time).

### Part C — Stop writing tokens back to the Keychain

- On token refresh, obtain the new access token in-memory for the current API call only.
  **Do not call `credentialLoader.persist(...)`** for Keychain-sourced credentials.
- Rationale: writes can re-trigger prompts and can race with the `claude` CLI's own token
  rotation, causing churn. The CLI owns the stored token; the app is a read-only consumer.
- The refreshed token is still cached in-memory (existing `cache(...)` path) so repeated polls
  within a session reuse it without re-reading the Keychain.
- File-sourced credentials: writing back to a file the app itself owns is harmless, but for
  consistency and simplicity the refresh path will also skip persistence. (`persist` may remain
  in the codebase unused, or be removed — implementation plan decides; no caller should invoke
  it from the refresh flow.)

### Part D — Fix the CLI fallback parser (so the safety net works)

- Update `ClaudeCLIUsageParser.extractResetDate` / `parseResetDate` to parse the human format:
  `Resets <h:mma> (<IANA tz>)`, e.g. `Resets 9:40pm (Europe/Madrid)`, with an optional leading
  `Mon DD,` / `MMM DD,` date token.
  - Parse the time-of-day and IANA timezone; when no date token is present, resolve to the next
    occurrence of that time (today if still in the future, otherwise the next reset day).
  - Existing labels (`Current session`, `Current week`) already substring-match the new
    `Current week (all models)` / `Current week (Sonnet only)` lines; percentage parsing
    (`N% used`) is unchanged.
- This path only runs as a last resort once Part B makes the API primary, but it must not
  silently drop the reset.

## Out of scope

- Surfacing `extra_usage` (overage credits) in the UI.
- Codex and Windsurf services — no changes.
- Notarization / distribution / Gatekeeper (self-signed local use only).
- Changing the menu-bar format or adding new compact fields.
- Using the CC ≥2.1.x statusline stdin `rate_limits` path (not available to a standalone app).

## Risks & mitigations

- **Undocumented endpoint / churning keys.** Mitigate with fully-optional decoding and alias
  keys, mirroring CodexBar. A new window key simply won't render until added.
- **First prompt after re-signing.** Expected one-time prompt when the signing identity
  changes; "Always Allow" then persists. Documented in README.
- **Self-signed cert per machine.** Each machine building from source creates the cert once;
  documented. Users with a Developer ID override `SIGN_IDENTITY`.

## Testing

- Unit: `ClaudeUsageResponse` decoding against fixtures — full multi-window response, response
  with `null` windows, response missing `resets_at`, legacy two-window response.
- Unit: `ClaudeCLIUsageParser` reset parsing for `Resets 9:40pm (Europe/Madrid)`,
  `Resets Nov 13, 2pm (...)`, and a no-reset output (percentage only).
- Unit/behavior: `fetchUsage` ordering — Keychain/API chosen before CLI; CLI only on API failure.
- Manual: build via `build.sh`, confirm `codesign -dvvv` shows the self-signed authority;
  refresh once (prompt), redeploy, confirm no re-prompt; confirm reset countdown appears.
