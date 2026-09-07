# Claude via the CLI, Never the Keychain — Design

**Date:** 2026-09-07
**Status:** Approved (pending spec review)
**Scope:** `Coding AI Usage` macOS menu-bar app — Claude Code provider only
**Supersedes:** `2026-09-06-claude-readonly-credentials-design.md` (Parts A–C; Part D carries over)
**Also reverses:** Part B of `2026-06-11-claude-credentials-and-reset-design.md`, which promoted the
JSON API above the CLI

## Problem

Two user-visible symptoms, now traced to one cause.

**1. Persistent token-endpoint rate limits.** Confirmed from the app's own instrumentation on
2026-09-07:

```
3 × endpoint=token status=429 retry-after=absent
      10:37:04   10:37:07   10:37:21
```

Zero `endpoint=usage` records in the same window. The 429s come from
`platform.claude.com/v1/oauth/token` — the refresh endpoint — **not** from
`api.anthropic.com/api/oauth/usage`. This settles the attribution question the predecessor spec
left open, and it does so in favour of removing the refresh path. Two incidental findings: the
token endpoint sends **no `Retry-After`** (so the app's 300s default pause is what actually
governs backoff), and three attempts landed inside 17 seconds because the manual Refresh button
deliberately bypasses the rate-limit pause.

**2. Repeated Keychain password prompts.** The user reports being asked continually, and that
clicking **Always Allow** does not stop it.

### Diagnosis: the ACL is reset by the CLI's own write

The prompts are not caused by anything the app does wrong, and cannot be fixed by the app while
it reads Claude Code's credential item.

- The app's designated requirement is **stable**:
  `identifier "com.ovidiuadorian.CodingAIUsage" and certificate leaf = H"4467e02c…"`. It contains
  no code-directory hash, so rebuilding and redeploying does **not** invalidate a granted ACL
  entry. The stable self-signed identity from the 2026-06-11 spec works as intended.
- Claude Code writes the item with **`security add-generic-password -U`** (confirmed in the
  v2.1.258 binary). Updating an existing item this way **replaces its access control list**,
  leaving only the invoking process. The user's "Always Allow" grant is destroyed on every token
  refresh.
- This preserves the item's **creation** date, which is why `cdat` remained 2026-08-18 while
  `mdat` advanced to 2026-09-07 08:38. An earlier revision of this diagnosis wrongly read that
  stable `cdat` as proof the ACL had survived; it proves only that the item was not deleted.

Upstream: anthropics/claude-code [#22144](https://github.com/anthropics/claude-code/issues/22144)
("Reduce keychain prompt friction for third-party tools", labels `area:auth`/`area:security`,
closed **not planned**, reporting "5-10+ password prompts per day") and
[#41026](https://github.com/anthropics/claude-code/issues/41026) (closed as duplicate). There is
no upstream fix and none planned.

### The two symptoms share a root cause

Both follow from the app borrowing Claude Code's own credential:

| Symptom | Mechanism |
|---|---|
| 429s on the token endpoint | The app refreshes a grant the CLI also refreshes and rotates |
| Keychain password prompts | The CLI's `-U` write resets the ACL the user granted |

Neither is fixable while that item is the source. The remedy is to stop using it.

### Prerequisite check: the CLI path works today

Run before designing around it, per the discipline that caught a bad rule in the Devin spec.

`claude /usage --allowed-tools ""` on v2.1.258 emits:

```
Current session: 12% used · resets Sep 7 at 1:10pm (Europe/Bucharest)
Current week (all models): 85% used · resets Sep 9 at 5am (Europe/Bucharest)
Current week (Fable): 3% used · resets Sep 9 at 5am (Europe/Bucharest)
```

This differs from the format the 2026-06-11 spec described — the reset is now on the same line
after a `·`, lowercase, with `at` between date and time, rather than on its own line as
`Resets 9:40pm (Europe/Madrid)`. **The existing `ClaudeCLIUsageParser` nevertheless parses it
correctly**, verified against the live output:

```
5-Hour: 88% remaining, reset=2026-09-07T10:10:00Z   (= 1:10pm Europe/Bucharest)
Weekly: 15% remaining, reset=2026-09-09T02:00:00Z   (= 5am  Europe/Bucharest)
```

**No parser changes are required.** A prediction that it would fail was wrong.

Measured cost: **~3.0s per probe** (2.97s, 3.09s), well inside the existing 15s timeout, and
subject to the existing 15-minute snapshot reuse so it does not run on most menu opens.

Critically, the probe triggers **no Keychain prompt**: the CLI reads its own item, for which it
holds the ACL entry.

## Design

### Part A — Source order

1. **`~/.claude/.credentials.json` → JSON API**, when the file exists and its token has not
   expired. Reading a file needs no ACL, so this cannot prompt. The file does not exist on macOS
   today (Claude Code keeps credentials in the Keychain, and the plaintext file is only a
   write-failure fallback), but the path already exists in the code, costs nothing, and covers
   Linux-style layouts and any future change in the CLI.
2. **`claude /usage` → `ClaudeCLIUsageParser`.** The working path on macOS.
3. Neither available → `.noCredentials` ("Claude Code: not logged in").

The CLI is promoted from last-resort fallback to the primary macOS source. This is a deliberate
reversal of Part B of the 2026-06-11 spec, which promoted the API to restore reset times; that
goal is preserved, because the CLI parser now yields resets correctly (see the check above).

### Part B — Remove Keychain access entirely

Deleted:

- `KeychainService` and its tests, including `resolveClaudeServiceName`, the legacy/hashed name
  resolution, and `writeClaudeCredentialsJSON`
- the Keychain branch of `ClaudeCredentialLoader`, `loadKeychainCredentials`, and the
  `ClaudeCredentialSource.keychain` case
- every call site that could reach `SecItemCopyMatching` for the Claude credential

Consequences: the app cannot prompt for the login keychain password, because nothing in it can
read a Keychain item. The constraint becomes structural rather than a convention.

This also makes two parts of the predecessor spec unnecessary. **Part A's mod-date ordering of
the 26 `Claude Code-credentials*` items is moot** — no ordering is needed if none are read — and
so is **Part B's on-demand re-read**, which existed to bound how often a Keychain data read could
prompt.

### Part C — Remove the refresh path

Unchanged from the predecessor spec's Part C, now justified by direct local evidence rather than
by precedent alone: delete `refreshCredentials`, `refreshURL`, `oauthClientID`, `oauthScopes`,
the `CredentialScope` enum, `reloadCredentials(scope:)` and the `didReloadCredentials` recursion.

After Parts B and C the app makes exactly one kind of outbound Claude request — `GET
/api/oauth/usage`, and only when a credentials *file* exists. It never contacts
`platform.claude.com`. The observed 429 source becomes unreachable.

This also removes the app from the position the research flagged on Anthropic's
[compliance page](https://code.claude.com/docs/en/legal-and-compliance): it no longer acts as an
OAuth client presenting Anthropic's own `client_id`.

### Part D — Stop destroying the cached snapshot on error

Carried over unchanged from the predecessor spec, and still required. `UsageViewModel` replaces
`claudeUsage` with an empty-`windows` value on `.authExpired` **and writes that over the
persisted cache**, so one transient failure discards the last known good reading. Retain the
existing windows and set `error` alongside them.

Note the interaction with finding 7 of the predecessor spec: a 429 is not an authentication
failure, so it must never invalidate a credential or clear a snapshot.

## Out of scope

- `claude setup-token` and an app-owned credential item. This would also solve the prompts (our
  item, our ACL, never touched by the CLI) and is what CodexBar does, but it needs a one-time
  user setup step, a Settings field, and an unverified assumption that such a token is accepted
  by `/api/oauth/usage`. Recorded as the better long-term design; not built here.
- Deleting the user's 26 stale `Claude Code-credentials*` items. Not the app's data.
- Per-model weekly windows (see Risks).
- Codex and Devin providers.

## Risks & mitigations

- **Per-model windows are lost.** The CLI emits `Current week (Fable): 3% used`, but the parser
  matches on `Current week` and takes `(all models)` first. The API path could in principle have
  rendered per-model rows. Accepted: the dropdown shows only 5-Hour and Weekly for Claude today,
  so nothing visible changes. Adding per-model parsing later is additive.
- **The CLI's output format is not a contract.** It has already changed once (the reset line moved
  and was reworded) and the parser survived, but a future change could break it. Mitigation: the
  parser fails to a recoverable error rather than crashing, the last good snapshot is retained
  (Part D), and the file→API path remains as an alternative if a credentials file ever appears.
- **~3s per probe, on the refresh path.** Bounded by the existing 15s timeout, and the 15-minute
  snapshot reuse plus the 60s menu-open throttle keep it infrequent. The refresh is asynchronous,
  so the UI does not block; data lags briefly instead.
- **A process spawn per refresh.** `claude` is invoked directly rather than through a login shell,
  which the existing code already does deliberately to avoid shell startup cost and side effects.

## Testing

**Removed:** all `KeychainService` tests; `ClaudeCredentialLoader` tests covering the Keychain
branch, hashed-name resolution and Keychain caching; the refresh-path tests already identified in
the predecessor spec.

**New:**

- With no credentials file present, `fetchUsage` uses the CLI and returns parsed windows.
- With a valid credentials file present, `fetchUsage` uses the API and does **not** spawn the CLI.
- With an expired credentials file, `fetchUsage` falls through to the CLI rather than refreshing.
- With neither, `.noCredentials`.
- **Guard test:** the service issues no request to `platform.claude.com` — a network-client spy
  fails the test if one is attempted.
- **Guard test:** no code path reaches the Keychain. Enforced by construction once
  `KeychainService` is deleted; asserted by a source-level check that the Claude sources contain
  no `SecItem` reference.
- A regression fixture of the current CLI output (the three-line form above) parses to 5-Hour and
  Weekly with correct resets.
- `.authExpired` preserves existing windows and does not overwrite the persisted cache.

**Manual:** refresh repeatedly for a day and confirm no Keychain prompt and no 429 record in
`log show --predicate 'subsystem == "com.ovidiuadorian.CodingAIUsage"'`.
