# Claude Read-Only Credentials — Design

**Date:** 2026-09-06
**Status:** Approved (pending spec review)
**Scope:** `Coding AI Usage` macOS menu-bar app — Claude Code credential acquisition only
**Supersedes:** Part C of `2026-06-11-claude-credentials-and-reset-design.md` (extends it from
"don't write the token back" to "don't refresh the token at all")

## Problem

The Claude Code row frequently reports rate limits and auth errors. Four commits have targeted
the symptom without removing the cause:

- `fb82de3` — handle 429 from the token endpoint
- `a52ea0a` — avoid double refresh-token consumption on 401
- `e243a08` — remove `PollingScheduler`, refresh on demand only
- `cc6a16b` — cache Claude snapshots, 15-minute reuse window

Refresh cadence is now conservative (menu-open only, 60s throttle, 15-minute snapshot reuse,
rate-limit pause). The 429s persist because they do not originate from polling frequency.

### Diagnosis (verified)

**1. The app competes with the `claude` CLI for a shared, rotating refresh token.**

`ClaudeUsageService.refreshCredentials` POSTs to `https://platform.claude.com/v1/oauth/token`
using the refresh token the CLI stored. Anthropic rotates refresh tokens on use. The sequence:

1. The app reads access token `T1` from the Keychain and caches it.
2. The CLI later refreshes, rotating the stored token to `T2`.
3. The app's cached `T1` expires. `needsRefresh` fires.
4. The app POSTs `T1`'s refresh token — already consumed by the CLI — and gets `invalid_grant`.
5. Repeated on each menu-open refresh, the token endpoint returns **429**.

The existing comment at `ClaudeUsageService.swift:186` describes this loop keeping the rate
limit alive. `a52ea0a`'s commit message ("avoid double refresh-token consumption") confirms the
rotation behaviour was already observed.

The converse is also damaging: when the app's refresh *succeeds*, it rotates the token and
stores the result **in memory only** (`cacheRefreshedCredentials`). On app quit that is lost,
leaving the CLI's stored refresh token dead.

**2. Keychain credentials are never TTL-evicted.**

`ClaudeCredentialLoader.cachedCredentials(...)`, `case .keychain`, returns the cached slot
without consulting `cachedAt` — by design, per its comment. The app therefore holds one access
token until it 401s, which *guarantees* it eventually presents an expired token and enters the
refresh loop above. It also means CLI rotations are invisible to the app.

**3. `needsRefresh` returns `true` when `expiresAt` is `nil`.**

`guard let expiresAt = credentials.expiresAt else { return true }` — a credential payload
without an expiry triggers a refresh on *every* fetch.

**4. The Keychain item is chosen arbitrarily among many.**

`KeychainService.findHashedClaudeServiceNameDirect` selects with
`.first { $0.hasPrefix("Claude Code-credentials-") }` over an **unordered**
`SecItemCopyMatching` result, then `resolveClaudeServiceName` caches that name for the process
lifetime. The query does not filter by `kSecAttrAccount`.

The development machine holds **26** matching items: the legacy `Claude Code-credentials` plus
25 hashed entries (`-9c13783d`, `-943349bd`, `-0eb83a42`, …), most last modified April–June
2026. The legacy entry (modified 2026-09-06) happens to be the fresh one and is checked first,
which masks the defect locally. On any machine without a legacy entry, the app picks one of 25
mostly-stale items at random — presenting as permanent auth failure plus the refresh loop.

### Rejected: moving credentials to `~/.claude/.credentials.json`

Investigated and rejected. Claude Code v2.1.258's credential store is a composite in which the
Keychain is primary and the plaintext file is a **write-failure fallback**: the telemetry event
is `secure_storage_credentials_write` → `plaintext_fallback_used`, a successful Keychain write
**deletes** the plaintext file, and the fallback carries the string
`Warning: Storing credentials in plaintext.`

There is no macOS opt-out. The only credential-storage override in the binary is
`CLAUDE_CODE_FORCE_WINDOWS_CREDMAN`. Obtaining the file would require deliberately breaking
Keychain access, and the CLI would revert as soon as it healed.

The app's file-credential path already exists and is already tried first
(`ClaudeUsageService.fetchUsage`, `ClaudeCredentialLoader.credentialFilePaths`). It is retained
unchanged — it costs nothing and serves Linux-style layouts and any future CLI change. It is
simply not a fix for this problem.

## Design

Four parts. A and B fix credential acquisition; C removes the rate-limit source; D corrects how
the resulting state reaches the user.

### Part A — Ordered, validated Keychain candidate resolution

`KeychainService` becomes a Keychain adapter with no opinion about credential contents.

- Replace `resolveClaudeServiceName() -> String?` with
  `claudeCredentialCandidates() -> [String]`.
- One `SecItemCopyMatching` with `kSecReturnAttributes: true`,
  `kSecMatchLimit: kSecMatchLimitAll`, and `kSecAttrAccount: currentUsername()` — the account
  filter is new; today's query returns every generic password for every account.
- Keep names equal to `Claude Code-credentials` **or** prefixed `Claude Code-credentials-`. The
  legacy entry is an ordinary candidate, not a privileged one.
- Sort by `kSecAttrModificationDate` descending. Items lacking the attribute sort last.
- Attribute-only queries never read item data, so this triggers **no ACL prompts** irrespective
  of candidate count.
- Cache the sorted list for the same 300s TTL the loader uses, with the duration injected at
  init so tests can drive it. A `forceRefresh` from the loader bypasses the cache. It must not
  persist for the process lifetime, as `cachedServiceName` does today.
- Expose `readCredential(serviceName:) -> String?` for a single item's data.
- **Delete `writeClaudeCredentialsJSON`.** Its only caller is a test. A write method on a
  read-only consumer invites reintroducing the defect this spec removes.

`ClaudeCredentialLoader` drives selection, since it owns the JSON shape: walk candidates
newest-first, read data, parse; the first yielding valid `claudeAiOauth` JSON wins. **At most 3
candidates are read** — the cap counts every attempted data read, whether or not it parses.

Failure handling is asymmetric and this asymmetry is required:

- A **parse failure** (absent, malformed, or empty payload) falls forward to the next candidate.
- An **access failure** — `errSecUserCanceled`, `errSecInteractionNotAllowed`, or `errSecAuthFailed`
  — stops the walk immediately and surfaces the error. Falling forward on denial would turn one
  declined prompt into up to three.

### Part B — Collapse the credential layer, evict on TTL

`loadFileCredentials`, `loadKeychainCredentials`, and `loadAnyCredentials` collapse into a single
`loadCredentials(forceRefresh: Bool = false) -> ClaudeCredentials?`, which tries the file paths
first (priority unchanged) and then the Keychain candidate walk from Part A.

- **Keychain results are TTL-evicted exactly like file results.** The `case .keychain` branch
  returning the cached slot unconditionally is removed; both sources honour the 300s window.
  This is what lets the app observe CLI rotations.
- **`needsRefresh` becomes `isExpired(_:)`**, with a **60s skew** so a request never starts with
  a token about to lapse mid-flight.
- **A `nil` `expiresAt` is treated as usable, not expired.** Under Part C, "expired" routes
  directly to a re-auth prompt, so inferring expiry from a missing field would send a working
  token there. A 401 covers the case instead.
- **Delete `cacheRefreshedCredentials`** — with no refresh, there is nothing to cache from one.
  The `switch cachedCredentials.source` branching inside `cachedCredentials(...)` also goes,
  since both sources now obey one TTL rule, and with it the `allowingFiles` / `allowingKeychain`
  filter parameters, which existed only so the two separate load methods could share a single
  cache slot. `ClaudeCredentialSource` itself is **retained** — it remains useful diagnostic
  information on a loaded credential.
- **`hasCredentialFile()` is retained unchanged.** It inspects only the file paths and is
  consumed by `UsageViewModel.swift:367` for Claude readiness (`ready = isInstalled ||
  hasCredentialFile`). It is deliberately *not* widened to consult the Keychain: readiness is
  already satisfied by `isInstalled` whenever the CLI is present, so widening it would add a
  code path without changing an outcome.

### Part C — A linear, refresh-free fetch path

`ClaudeUsageService` loses `refreshCredentials`, `refreshURL`, `oauthClientID`, `oauthScopes`,
the `CredentialScope` enum, `reloadCredentials(scope:)`, and the `didReloadCredentials`
recursion parameter. `fetchUsage()` becomes linear:

1. `loadCredentials()`. If nothing is found at all → CLI scraper (`fetchUsageViaCLI`) → if that
   also yields nothing, `.noCredentials`.
2. If the credential is expired → `loadCredentials(forceRefresh: true)` **once**. The CLI
   usually rotated the token already, so the fresh read normally succeeds. If the freshly-read
   credential is also expired → `.authExpired`.
3. Perform the usage request. On 401/403 → invalidate the cache,
   `loadCredentials(forceRefresh: true)`, retry **once**. Still 401/403 → `.authExpired`.
4. 429 from `api.anthropic.com/api/oauth/usage` still maps to `.rateLimited` and still drives
   the existing menu-open pause.

The CLI scraper's role is **unchanged**: last resort, reached only when no parseable credential
exists from any source. An expired-but-present credential goes to `.authExpired`, not to the
scraper — the scraper blocks for up to 15 seconds on a process spawn and returns less data than
the API.

After this change the token endpoint is unreachable from the app. The 429 source is removed
structurally rather than guarded.

### Part D — Correct the terminal state's presentation

`.authExpired` changes from a rare event to the normal terminal state for a lapsed token, which
makes the current handling wrong in two ways.

- **Stop blanking the snapshot.** `UsageViewModel.swift:426` replaces `claudeUsage` with a value
  whose `windows` is empty and then **saves that over the persisted cache**. Instead, retain the
  existing windows and set `error` alongside them. The row then shows last-known usage *and*
  "session expired", and — more importantly — a transient auth failure no longer destroys the
  cached snapshot on disk.
- **Surface re-auth where the error appears.** `viewModel.reauthenticateClaude()` is currently
  reachable only from `SettingsView`. Add the same action to the Claude row when its `error`
  indicates an auth problem. No new plumbing: `ClaudeAuthLauncher` and the view-model method
  already exist.

## Out of scope

- Deleting the 25 stale Keychain entries. The app must not mutate the user's Keychain; the
  manual cleanup is documented in the README instead.
- Migrating credentials to `~/.claude/.credentials.json` (rejected above, with reasons).
- Writing any credential back to the Keychain, under any circumstance.
- Surfacing `extra_usage`.
- Codex and Windsurf services. Windsurf's Devin rebrand is a separate spec.
- Changing the menu-bar format.

## Risks & mitigations

- **`sign.sh` becomes load-bearing.** TTL-evicting the Keychain cache turns one data read per
  session into one per five minutes. This is silent only while the stable self-signed identity
  from the prior spec holds its "Always Allow" grant. On an ad-hoc build it becomes a prompt
  every five minutes rather than once per session. Mitigation: `build.sh` already fails loudly
  when the identity is missing; the README must state that skipping signing now degrades far
  worse than before.
- **A lapsed token now requires user action.** Previously the app attempted self-healing via
  refresh. It will now prompt. This is deliberate: the refresh was unreliable, damaged the CLI's
  stored token, and caused the rate limits. The fresh re-read in Part C step 2 handles the
  common case without user involvement, because the CLI keeps the stored token current.
- **Mod-date ordering assumes the CLI touches the item it uses.** If a future CLI reads without
  updating `kSecAttrModificationDate`, ordering could favour a stale entry. Mitigation: the
  fall-forward walk in Part A tries up to three candidates, so a stale-but-parseable newest
  entry still yields a 401 that triggers exactly one forced re-read rather than a loop.
- **Three data reads could mean three ACL prompts** on a machine where the app has no grant for
  the newest entries. Mitigated by stopping the walk on access failure (Part A), so at most one
  prompt is declined before the error surfaces.

## Testing

Existing coverage is 839 lines across `ClaudeUsageTests.swift` and
`ClaudeCredentialLoaderTests.swift`.

**Deleted as moot** (they assert behaviour of the removed refresh path):

- `testClaudeUsageServiceRefreshesExpiredFileTokenBeforeFetchingUsage`
- `testClaudeUsageServiceDoesNotWriteRefreshedTokenBackToKeychain`
- `testClaudeUsageServiceDoesNotDoubleRefreshAfter401`
- `testClaudeUsageServiceSurfacesRefreshRateLimitAsRateLimited`
- `testWritingKeychainCredentialsCallsCredentialWriter`

**Inverted:**

- `testKeychainCredentialsRemainCachedAcrossPollInterval` becomes
  `testKeychainCredentialsAreReReadAfterTTL`.

**Adapted:**

- `testHashedKeychainServiceNameIsResolvedWhenLegacyEntryIsMissing` → asserts ordering rather
  than legacy-first precedence.
- The three `ClaudeCredentialLoaderTests` cases calling `loadAnyCredentials()` (`testFileCredentialsPreferredOverKeychain`, `testCredentialCacheExpiresAfterTTL`,
  `testInvalidateCacheClearsCachedCredentials`) → retargeted at `loadCredentials(forceRefresh:)`.
  `cacheState` / `ClaudeCredentialCacheState` are retained; they are test-only observers.
- `testClaudeUsageServiceReloadsCredentialsAfter401AndRetriesOnce` → retained, rewritten against
  the linear path.

**New:**

- Candidates are sorted by `kSecAttrModificationDate`, newest first.
- A legacy `Claude Code-credentials` entry older than a hashed entry ranks *below* it.
- The candidate query filters by the current account.
- Fall-forward past an unparseable newest candidate reaches the next one.
- Access denial (`errSecUserCanceled`) stops the walk — the second candidate is never read.
- The walk reads at most 3 candidates.
- A credential with `nil` `expiresAt` is treated as usable.
- A token expiring within the 60s skew is treated as expired.
- An expired credential triggers exactly one forced re-read; a fresh valid one then succeeds.
- An expired credential whose forced re-read is also expired yields `.authExpired`.
- `.authExpired` preserves existing `windows` and does not overwrite the persisted cache.
- **Guard test:** `ClaudeUsageService` issues no request to any `platform.claude.com` host — a
  network-client spy fails the test if one is attempted.

**Manual:**

- With a valid CLI session, refresh repeatedly over an hour and confirm no 429 and no re-prompt.
- `claude auth logout`, refresh, confirm the row shows last-known windows plus "session
  expired" and offers re-auth inline; re-login and confirm recovery without restarting the app.
