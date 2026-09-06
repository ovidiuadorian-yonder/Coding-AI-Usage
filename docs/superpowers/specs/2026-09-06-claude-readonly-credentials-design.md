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

**1. The app competes with the `claude` CLI for a shared credential, and refreshing it breaks
the CLI's copy.**

`ClaudeUsageService.refreshCredentials` POSTs to `https://platform.claude.com/v1/oauth/token`
using the refresh token the CLI stored.

**Confirmed by precedent, not by mechanism.** CodexBar — a macOS menu-bar usage meter with the
same architecture — hit exactly this failure. Issue
[#1161](https://github.com/steipete/CodexBar/issues/1161), *"CodexBar can desync Claude Code's
OAuth refresh token, forcing daily re-login"* (filed against v0.27.0, closed COMPLETED). The
shipped fix, verified in current `main`: `ClaudeOAuthCredentials.swift` switches on credential
ownership and, for `.claudeCLI`-owned records, throws `refreshDelegatedToClaudeCLI` **without
ever calling the token endpoint**. Both `~/.claude/.credentials.json` and the
`Claude Code-credentials` Keychain item are classified `.claudeCLI`, so neither is rotated.

**The mechanism is unproven.** An earlier draft of this spec asserted that Anthropic rotates
refresh tokens on use. That is *not* established: no public source reproduces `invalid_grant`
from re-presenting a consumed refresh token, none reports an observed `expires_in`, and an
adversarial verification of the rotation claim failed (1-2). The desync is *consistent* with
rotation but has other candidate explanations — server-side session invalidation,
single-active-client enforcement, or the CLI overwriting the item with a token the app's own
refresh had already superseded.

**This does not weaken the design.** The remedy is identical under every candidate mechanism:
do not present the CLI's refresh token to the token endpoint. That is what CodexBar shipped,
and it is what every other examined meter does by default (see finding 5).

A second-order harm is certain regardless of mechanism: when the app's refresh *succeeds*, it
stores the result **in memory only** (`cacheRefreshedCredentials`). On app quit that is lost,
so any server-side state change the refresh caused is invisible to both the app and the CLI
afterwards.

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

**5. Every comparable third-party meter is read-only.**

CodexBar reads `Claude Code-credentials` at four call sites, all `SecItemCopyMatching`; a search
for `SecItemAdd|SecItemUpdate|SecItemDelete` under its Claude provider returns nothing.
`ccstatusline` does not even deserialize the refresh token — its schema is
`claudeAiOauth: { accessToken }` — and has zero hits for `refresh_token`, `oauth/token`, or
`platform.claude.com`; on 401 it waits for the user to re-run `/login`. `ccusage` avoids
credentials altogether by reading local JSONL. Read-only consumption is the established pattern,
and it is the one pattern with no reported desync bug.

**6. Claude Code resets the Keychain item's ACL on every refresh (~every 8 hours).**

anthropics/claude-code [#41026](https://github.com/anthropics/claude-code/issues/41026)
("OAuth token refresh overwrites keychain item and resets third-party app permissions", closed
as duplicate) and [#22144](https://github.com/anthropics/claude-code/issues/22144) ("Reduce
keychain prompt friction for third-party tools", labels `area:auth`/`area:security`, closed
**not planned**). The CLI **deletes and recreates** the item on refresh, which resets its ACL
and revokes a third-party reader's "Always Allow" grant. #22144 reports "5-10+ password prompts
per day" and gives the refresh cadence as roughly every 8 hours.

This is independent of OAuth rotation and of the 429 question, and it constrains Part B: a
stable code-signing identity does **not** survive it. Any design that re-reads Keychain *data*
on a short fixed interval will prompt shortly after each CLI refresh.

**7. A 429 on the usage endpoint is not an authentication failure.**

`GET https://api.anthropic.com/api/oauth/usage` returning 429 with
`{"error":{"type":"rate_limit_error"}}` is independently reproduced in anthropics/claude-code
[#31637](https://github.com/anthropics/claude-code/issues/31637),
[#31021](https://github.com/anthropics/claude-code/issues/31021), and
[#30930](https://github.com/anthropics/claude-code/issues/30930) (still open). #30930 records the
token as valid with 4+ hours remaining, correct scopes, and still working for ordinary API calls
while the usage endpoint 429s.

Consequence: a 429 must never be treated as a stale credential or trigger a credential re-read.
Doing so adds pressure with no possible benefit.

**Unresolved: which endpoint produces the 429s observed on this machine.** The public evidence
for usage-endpoint 429s is strong (three independent reporters, byte-identical bodies); the
evidence for token-endpoint 429s is a single unverified report
([#38248](https://github.com/anthropics/claude-code/issues/38248)). The two must not be
conflated. Instrumentation to attribute the local symptom is being added before this spec's
Part C is implemented; if the 429s prove to originate at the usage endpoint, removing the
refresh path will not by itself resolve them, and Part C's justification rests solely on
findings 1 and 5. Note also that `Retry-After` semantics here are unreliable — sources disagree
on whether the header is sent at all — so backoff must tolerate its absence.

**8. Anthropic's stated position gives no sanctioned third-party OAuth path.**

The [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance) states that
OAuth authentication "is intended exclusively for purchasers of Claude Free, Pro, Max, Team, and
Enterprise subscription plans and is designed to support ordinary use of Claude Code and other
native Anthropic applications", and directs third-party developers to API-key authentication.

Scope, stated honestly: the prohibitions are phrased around routing requests, offering Claude.ai
login, and intermediating credentials. A purely local, read-only meter that only reads a stored
`accessToken` and GETs `/api/oauth/usage` is a grey zone the text does not name. An app that
POSTs to the token endpoint with Anthropic's own `client_id` and a spoofed
`User-Agent: claude-code/<version>` is acting as an OAuth client and is outside it. Removing the
refresh path (Part C) moves the app from the second category into the first. This is a further
argument for Part C, not an independent claim about the app's overall standing.

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

### Part B — Collapse the credential layer, re-read on demand

`loadFileCredentials`, `loadKeychainCredentials`, and `loadAnyCredentials` collapse into a single
`loadCredentials(forceRefresh: Bool = false) -> ClaudeCredentials?`, which tries the file paths
first (priority unchanged) and then the Keychain candidate walk from Part A.

- **Keychain results become re-readable, but on demand rather than on a fixed clock.** The
  `case .keychain` branch returning the cached slot unconditionally is removed. It is **not**
  replaced with the file path's blind 300s eviction: finding 6 shows the CLI resets the item's
  ACL every ~8 hours, so a short fixed interval would prompt the user shortly after each CLI
  refresh — roughly three times a day, and a signing identity does not prevent it.

  Instead, a cached Keychain credential is re-read only when there is a reason to:

  1. the cached token is **at or past** its expiry (including the 60s skew below), or
  2. a **401/403** has just been observed (`forceRefresh: true` from Part C step 3).

  A cached credential that is still valid by its own `expiresAt` is reused without touching the
  Keychain, however old the cache entry is. This preserves the property that matters — the app
  never uses a token past its stated lifetime — while keeping Keychain *data* reads to roughly
  the CLI's own refresh cadence rather than 288 times a day.

  **File-sourced credentials keep the 300s TTL.** Reading a file has no ACL cost, so there is no
  reason to make that path lazier.

  The candidate-list cache from Part A keeps its 300s TTL regardless: it is attribute-only and
  never prompts.
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

- **Keychain prompts cannot be fully eliminated.** Finding 6 establishes that the CLI deletes
  and recreates the credential item every ~8 hours, resetting its ACL. A stable signing identity
  keeps the grant across *rebuilds* but does not survive the CLI's recreation of the item, so
  some re-granting is unavoidable for any third-party reader on macOS. Part B's on-demand
  re-read bounds the exposure to roughly the CLI's own refresh cadence instead of every five
  minutes; `sign.sh` remains necessary but is not sufficient. The README must say so plainly
  rather than implying signing makes prompts go away.
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

**Retained, and now load-bearing:**

- `testKeychainCredentialsRemainCachedAcrossPollInterval` — under Part B's on-demand re-read a
  *still-valid* Keychain credential is deliberately reused across poll intervals, so this test
  encodes the property that limits ACL prompts. An earlier draft of this spec proposed inverting
  it to `…AreReReadAfterTTL`; that would now assert the opposite of the intended behaviour.

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
- A 401 triggers exactly one forced Keychain re-read.
- **A 429 triggers no credential re-read at all** (finding 7) — the credential cache is untouched
  and `.rateLimited` propagates unchanged.
- A cached Keychain credential that is still valid by its own `expiresAt` is reused without any
  Keychain data read, regardless of cache age.
- File-sourced credentials still honour the 300s TTL.
- `.authExpired` preserves existing `windows` and does not overwrite the persisted cache.
- **Guard test:** `ClaudeUsageService` issues no request to any `platform.claude.com` host — a
  network-client spy fails the test if one is attempted.

**Manual:**

- With a valid CLI session, refresh repeatedly over an hour and confirm no 429 and no re-prompt.
- `claude auth logout`, refresh, confirm the row shows last-known windows plus "session
  expired" and offers re-auth inline; re-login and confirm recovery without restarting the app.
