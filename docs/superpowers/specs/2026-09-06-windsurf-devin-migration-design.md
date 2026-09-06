# Windsurf → Devin Migration — Design

**Date:** 2026-09-06
**Status:** Approved (pending spec review)
**Scope:** `Coding AI Usage` macOS menu-bar app — Windsurf provider only
**Companion spec:** `2026-09-06-claude-readonly-credentials-design.md` (independent; no shared code)

## Problem

Windsurf has been rebranded to Devin. The app still reads
`~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`, which on a migrated
machine is a directory the current client no longer writes. The row therefore reports stale
quota data as if it were current.

### Findings (verified on the development machine, 2026-09-06)

**Devin is the same client under a new name.** `/Applications/Devin.app` reports
`CFBundleIdentifier = com.exafunction.windsurf`, version `3.8.20`. It is the same VS Code fork
with an unchanged state layout at
`~/Library/Application Support/Devin/User/globalStorage/state.vscdb`.

**The state keys are unchanged.** Both DBs contain `windsurfAuthStatus`,
`windsurf.settings.cachedPlanInfo`, and `codeium.windsurf` under the same names — the extension
id is still `codeium.windsurf`, so the existing reader logic applies verbatim once repointed.

**The proto source is live under Devin.** `windsurfAuthStatus.userStatusProtoBinaryBase64` is
47,228 base64 chars in the Devin DB (35,419 decoded bytes) versus 92,732 in the old Windsurf DB —
different content, freshly written. Scanning the decoded proto for plausible epoch-second
varints yields a current billing period (2026-08-28 → 2026-09-28) and a daily reset dated today,
matching the day-of-month pattern of the older data. The existing
`WindsurfUserStatusProtoParser` schema is therefore very likely intact.

**`cachedPlanInfo` is a fossil in both DBs.** The value is byte-identical between Windsurf and
Devin, and its timestamps are 102 days old:

| field | value | age |
|---|---|---|
| `startTimestamp` | 2026-04-28 | 131 days ago |
| `endTimestamp` | 2026-05-28 | 101 days ago |
| `quotaUsage.dailyResetAtUnix` | 2026-05-27 | 102 days ago |
| `quotaUsage.weeklyResetAtUnix` | 2026-05-31 | 98 days ago |

It reports `dailyRemainingPercent = 61`, `weeklyRemainingPercent = 30`. Devin no longer writes
this key; the value was carried over at migration. Because it still parses cleanly, the current
merge path at `WindsurfUsageService.swift:133` would blend May's numbers into today's reading.
**Repointing the path alone is not sufficient** — it would move the app onto a live proto while
still merging a dead fallback.

**The scrape path reads third-party browser cookie jars.** `readCookies`
(`WindsurfUsageService.swift:241`) enumerates three Chromium stores — Windsurf's own,
`Microsoft Edge/Default/Cookies`, and `Google Chrome/Default/Cookies` — reads each one's
"Safe Storage" key from the Keychain (`kSecAttrService`, line 430) and AES-decrypts cookie
values via `CCCrypt` (line 510) to drive a `WKWebView` load of `windsurf.com/subscription/usage`.

**The scrape target still exists but Devin's does not.** `windsurf.com/` 308-redirects to
`devin.ai/desktop`, while `windsurf.com/subscription/usage` still returns a real Next.js page.
`devin.ai/subscription/usage` returns **429** to automated requests; `app.devin.ai` paths are
auth-gated SPA shells. A Devin-side scrape is therefore not a viable migration target.

## Design

Four parts. A repoints the reader, B stops the fossil from contaminating output, C removes the
scrape subsystem, D handles user-facing naming.

### Part A — Freshest-of-both client discovery

`stateDBPath` is currently a fixed string supplied at init. It becomes a **probe**:

- Candidate roots, in a fixed list: `~/Library/Application Support/Devin` and
  `~/Library/Application Support/Windsurf`.
- For each, stat `User/globalStorage/state.vscdb`. Keep those that exist.
- Choose the candidate with the **newer file modification time**. Ties resolve to Devin.
- Resolve once per `fetchUsage` call and reuse the choice for every read within it, so a refresh
  never mixes rows from two different DBs.
- If neither exists → `.noCredentials` ("Windsurf: not logged in"), as today.

`checkInstalled()` currently hardcodes `~/Library/Application Support/Windsurf`
(`WindsurfUsageService.swift:106`) and must use the same probe, otherwise a migrated machine
reports the client as absent.

The probe is injectable at init (alongside the existing provider seams) so tests can drive it
without touching the real filesystem.

Rationale for freshness over fixed priority: it is correct in both directions — a user who has
not yet migrated keeps working, and a user who rolls back to Windsurf is not pinned to a stale
Devin DB.

### Part B — A uniform freshness gate on local sources

Every local source is subject to one rule before it may contribute to a reading. A source is
**expired** when its **billing period end is in the past**. That is the whole rule.

> **Revised 2026-09-07 after the prerequisite parser check.** An earlier draft also expired a
> source when *both* its daily and weekly reset timestamps were in the past. Running the parser
> against the live Devin proto disproved that rule: at `2026-09-06T21:06Z` it yields
> `dailyReset=2026-09-04` and `weeklyReset=2026-09-06`, **both already past**, while the data
> itself is current (`planEnd=2026-09-28`, `balance=$1851.15`). The reset fields are not
> maintained as "next reset" — they lag behind whenever the client last synced quota. The
> discarded rule would have rejected the live source and shown nothing, turning wrong numbers
> into no numbers. Reset timestamps must therefore play no part in staleness.

`planEndDate` is the field that actually tracks freshness. On the machine this was verified
against it separates the two sources cleanly and correctly:

| source | planEnd | verdict |
|---|---|---|
| Devin | 2026-09-28 (future) | **kept** |
| Windsurf | 2026-06-28 (past) | **discarded** |

A source carrying **no** billing period end cannot be judged and is retained; the gate demotes
sources proven stale, it does not require proof of freshness. Failing closed was considered and
rejected: it would blank the row for any user whose proto omits the field, and there is no
evidence about how common that is.

An expired source is **discarded, not merged**. The rule is applied uniformly to:

- `windsurf.settings.cachedPlanInfo` (`readCachedPlanInfo`), whose `endTimestamp` is the field,
- the proto snapshot from `userStatusProtoBinaryBase64`, whose `planEndDate` is the field,
- the `codeium.windsurf` JSON candidates (`windsurf.state.cachedUsageSnapshot`,
  `cachedQuotaSnapshot`, `cachedUsagePageSnapshot`), which carry the plan end only via the
  merged plan info and are therefore judged on it when present.

Consequences on today's data: the fossil `cachedPlanInfo` (period ended 2026-05-28) is dropped,
and the live Devin proto is accepted. `merge(snapshot:fallbackPlanInfo:)` receives `nil` for the
fallback rather than stale values, so `planEndDate` comes from the proto or is absent.

If **every** source fails the gate, the row reports no usage and surfaces the existing
"exact quota data unavailable" state. Showing nothing is correct; showing 102-day-old
percentages as current is not.

### Part B2 — Render elapsed resets honestly

Independent of staleness, the app currently formats a reset that has already passed as though it
were still ahead, by rendering the absolute difference. Verified against the stale Windsurf
source at `2026-09-06T21:06Z`:

| field | stored value | in the past by | displayed as |
|---|---|---|---|
| `dailyResetTime` | 2026-06-04 | 3 months 2 days | "Resets 3 mths, 2 days" |
| `weeklyResetTime` | 2026-06-07 | 2 months 30 days | "Resets 2 mths, 30 days" |

Both matched exactly, so the mechanism is not in doubt. A *daily* quota claiming to reset in
three months is self-evidently wrong, and it was being shown next to a green "Healthy" badge.

The reset formatter must therefore distinguish a future reset from a past one and never present
elapsed time as remaining time. A past reset renders as overdue rather than as a countdown.

This is a defect in the **shared** formatter, not in the Windsurf provider, so the fix applies to
the Claude and Codex rows too. It is included here because the freshness gate alone does not
address it: a source can pass the gate — a valid billing period — while still carrying a reset
timestamp that has elapsed, which is exactly the state the live Devin proto is in right now.

### Part C — Delete the scrape subsystem

The proto is live and carries daily/weekly quotas and resets, making the scrape redundant. A
Devin-side replacement is not available (429). Remove it.

Deleted from `WindsurfUsageService.swift`:

- `WindsurfUsageScraper` (the `WKWebView` / `WKNavigationDelegate` class, line 554)
- `scrapeSnapshot`, `readCookies`, and the three `ChromiumCookieStore` definitions
- `decryptCookieValue` and the `CCCrypt` cookie decryption (lines 446, 510)
- the Keychain read for Chromium "Safe Storage" keys (line 430)
- `WindsurfCookieState`, `CookieStateProvider`, `LiveSnapshotProvider`, `usageURL`,
  `isLikelyAuthCookie`, and `hasLikelyLiveAuthCookies`

Imports reduce from `Foundation, SQLite3, Security, WebKit, CommonCrypto` to
`Foundation, SQLite3`.

The removal collapses plumbing upward. `preferLiveRefresh` exists only to drive the scrape:

- `WindsurfUsageServing.fetchUsage(preferLiveRefresh:)` → `fetchUsage()`
- `UsageViewModel.refresh(forceLiveWindsurf:…)` and `performManualRefresh(forceLiveWindsurf:)`
  lose the parameter (`UsageViewModel.swift:103, 128, 138, 142, 145, 166, 515, 523`)

Beyond code size, this ends the app reading and decrypting the user's Chrome and Edge cookie
jars — capability far exceeding what a usage meter requires, and a plausible source of Keychain
prompts users would struggle to attribute.

### Part D — Naming

- `displayName` → `"Devin"`; short label `"W"` → `"D"` (`WindsurfUsageService.swift:80-81, 94-95`;
  `UsageViewModel.swift:258, 281`).
- The **persisted id stays `"windsurf"`** (`WindsurfUsageService.swift:80`,
  `UsageViewModel.swift:281, 317`) and the **`showWindsurf` `@AppStorage` key is unchanged**
  (`UsageViewModel.swift:21`). Renaming either would discard the user's cached snapshot on
  upgrade and silently reset their row-visibility preference.
- Internal identifiers and user-facing labels are deliberately decoupled. Source-code symbol
  names (`WindsurfUsageService`, `windsurfUsage`) stay as they are; renaming them is churn with
  no user-visible benefit and would enlarge the diff for no gain.
- README updated: the provider is Devin, the state path is auto-detected, and the experimental
  scrape no longer exists.

## Out of scope

- Deleting or migrating `~/Library/Application Support/Windsurf`. It is the user's data; the app
  does not remove it.
- Any Devin-hosted HTTP API. None is known to be available to a third-party client.
- Renaming Swift types, the persisted service id, or the `showWindsurf` settings key.
- Claude and Codex providers.

## Risks & mitigations

- **The proto becomes the single source of truth.** If Devin changes that schema, the row goes
  blank rather than degrading to a scrape. Accepted: the discarded alternative was serving
  102-day-old numbers as current. The freshness gate in Part B makes the failure visible instead
  of silent.
- ~~**Proto compatibility is inferred, not proven.**~~ **Resolved 2026-09-07.**
  `WindsurfUserStatusProtoParser` was run against the live Devin proto and parsed it **without
  modification**, returning `dailyUsed=0% weeklyUsed=1% planEnd=2026-09-28 balance=$1851.15`.
  No parser changes are needed. The check did, however, invalidate the original freshness rule —
  see the revision note in Part B.
- **mtime-based selection assumes the active client writes on use.** The Devin DB was modified
  the same day it was inspected, supporting this. If both DBs were somehow equally fresh, the
  tie resolves to Devin.
- **Users on a pre-rebrand Windsurf install.** Fully supported by the Part A probe; they are on
  the same code path, selected by freshness.

## Testing

`WindsurfUsageTests.swift` is currently 678 lines.

**Deleted:** all scrape, cookie-store, cookie-decryption and `WKWebView` cases, plus any case
asserting `preferLiveRefresh` behaviour.

**New — client discovery (Part A):**

- Both DBs present, Devin newer → Devin selected.
- Both present, Windsurf newer → Windsurf selected.
- Devin only → Devin selected.
- Windsurf only → Windsurf selected.
- Neither → `.noCredentials`.
- Equal mtimes → Devin selected.
- `checkInstalled()` returns true when only the Devin support directory exists.

**New — freshness gate (Part B):**

- A source whose billing period end is in the past is discarded.
- A source whose billing period end is in the future is retained.
- A source carrying no billing period end is retained (the gate does not require proof of
  freshness).
- **A source with a future billing period end but both resets already in the past is retained** —
  this is the live Devin proto's actual state, and the case the original rule got wrong.
- A `cachedPlanInfo` fixture with the fossil's `endTimestamp` (2026-05-28) is rejected while a
  proto fixture with a future plan end is accepted in the same read.
- All sources stale → no usage reported, no stale percentages surfaced.

**New — reset rendering (Part B2):**

- A reset timestamp in the future renders as a countdown, as today.
- A reset timestamp in the past renders as overdue, **not** as the elapsed interval. Regression
  fixture: 2026-06-04 evaluated at 2026-09-06 must not render "3 mths, 2 days".
- A nil reset renders as it does today.

**New — naming (Part D):**

- `displayName == "Devin"` while `id == "windsurf"`.
- A snapshot persisted under the previous build's `"windsurf"` id still loads.

**Prerequisite test — satisfied.** `WindsurfUserStatusProtoParser` was run against the live
Devin proto and parsed it unmodified. Committed tests keep using synthetic protos built from the
known field numbers (14-18), matching the existing
`testUserStatusProtoParserExtractsQuotaAndBalanceFromNestedMessage`; the captured proto is **not**
committed, as it is account status data.

**Manual:** with Devin running, refresh and confirm the row shows daily/weekly percentages whose
resets are in the future and which track the Devin UI; confirm no Keychain prompt occurs (the
Safe Storage reads are gone); confirm the row survives an app restart via the cached snapshot.
