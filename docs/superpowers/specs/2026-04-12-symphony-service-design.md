# Symphony Service Design

**Date:** 2026-04-12
**Status:** Approved in conversation, pending written-review confirmation

## Goal

Implement a repository-local Symphony service in this repository as a separate `Node.js + TypeScript` application that conforms to the upstream `openai/symphony` specification and runs live against the real Linear project plus `codex app-server`.

## Scope

This design covers:

- a new top-level `symphony/` service inside this repository
- live Linear GraphQL reads against the `AI Usage Plugin Symphony` project
- live `codex app-server` execution in per-issue workspaces
- workflow parsing from repository-owned `WORKFLOW.md`
- runtime reload, orchestration, retries, workspace lifecycle, and structured logging
- repository docs and smoke-test support needed to run the service locally

This design does not cover:

- changes to the Swift macOS app outside what Symphony may work on through Linear issues
- a web dashboard or multi-tenant control plane
- a separate safety platform beyond a high-trust local runner for v1

## Product Boundary

The existing Swift macOS menu bar app remains the product under development.

The new Symphony service is an operator tool that:

- polls Linear for eligible issues
- creates or reuses deterministic per-issue workspaces
- runs `codex app-server` sessions inside those workspaces
- reconciles issue state changes and worker lifecycle
- emits logs and operator-visible status

This means the repository will contain both:

1. the Swift product
2. the TypeScript orchestration service that can work on the product

## Runtime Choice

The service will use `Node.js + TypeScript`.

Reasons:

- good fit for long-running daemon behavior and file watchers
- straightforward child-process control for `codex app-server`
- strong JSON and stream handling for stdio protocol parsing
- lower setup cost than adding Elixir to a Swift-focused repo

## Architecture

The service will live under a new top-level `symphony/` directory with its own package metadata, TypeScript config, and test configuration.

Planned module boundaries:

### 1. CLI Layer

Entry point: `symphony/src/cli.ts`

Responsibilities:

- accept optional path to `WORKFLOW.md`
- resolve default workflow path when omitted
- initialize logging and startup validation
- start the orchestrator host process
- exit nonzero on startup failure

### 2. Workflow Layer

Directory: `symphony/src/workflow/`

Responsibilities:

- load `WORKFLOW.md`
- parse YAML front matter and markdown body
- surface typed workflow errors
- watch the workflow file for runtime reload
- render prompts with strict template semantics

Expected outputs:

- `config` object from front matter
- `promptTemplate` string

### 3. Config Layer

Directory: `symphony/src/config/`

Responsibilities:

- expose typed getters with defaults
- resolve `$VAR_NAME` references
- normalize paths and numeric values
- validate dispatch-critical settings
- preserve last known good configuration on invalid reload

### 4. Linear Integration Layer

Directory: `symphony/src/tracker/linear/`

Responsibilities:

- perform live GraphQL calls to Linear
- fetch candidate issues by project and active states
- refresh issue state by IDs for reconciliation
- fetch terminal issues for startup cleanup
- normalize tracker payloads into the Symphony issue model

Normalization rules to enforce:

- lowercase labels
- stable `id` plus human-readable `identifier`
- blocker normalization from relevant relations
- state comparisons on normalized lowercase values

### 5. Workspace Layer

Directory: `symphony/src/workspace/`

Responsibilities:

- derive sanitized workspace keys from issue identifiers
- ensure workspaces stay inside configured workspace root
- create, reuse, and remove workspace directories safely
- run lifecycle hooks with timeouts
- keep hook failures typed and observable

Lifecycle hooks:

- `after_create` only on first workspace creation
- `before_run` before every agent attempt, aborting the attempt on failure
- `after_run` after every attempt, best effort
- `before_remove` before cleanup, best effort

### 6. Codex Runner Layer

Directory: `symphony/src/codex/`

Responsibilities:

- launch `codex app-server` via `bash -lc`
- keep cwd pinned to the issue workspace
- speak the app-server protocol over stdio
- create thread/session state
- run repeated turns up to configured limits
- extract session identifiers, usage counters, and rate limits from event payloads

### 7. Orchestrator Layer

Directory: `symphony/src/orchestrator/`

Responsibilities:

- own the single authoritative runtime state
- schedule poll ticks
- dispatch eligible issues under concurrency limits
- reconcile running issues against current tracker state
- stop ineligible or terminal runs
- manage retry timers and continuation retries
- aggregate runtime metrics

### 8. Observability Layer

Directory: `symphony/src/observability/`

Responsibilities:

- emit structured logs with issue and session context
- keep validation failures operator-visible
- expose a lightweight runtime snapshot surface for debugging

For v1, structured logs are required. A minimal local status surface is recommended if it does not slow delivery.

## Files And Responsibilities

Planned initial file layout:

- `symphony/package.json`: service scripts and dependencies
- `symphony/tsconfig.json`: TypeScript compiler settings
- `symphony/vitest.config.ts`: test configuration
- `symphony/src/cli.ts`: CLI bootstrap
- `symphony/src/types.ts`: shared domain types
- `symphony/src/workflow/loadWorkflow.ts`: parse and load workflow file
- `symphony/src/workflow/watchWorkflow.ts`: live reload watcher
- `symphony/src/workflow/renderPrompt.ts`: strict prompt rendering
- `symphony/src/config/getConfig.ts`: typed config getters and defaults
- `symphony/src/config/validateConfig.ts`: startup and dispatch validation
- `symphony/src/tracker/linear/linearClient.ts`: raw GraphQL client
- `symphony/src/tracker/linear/normalizeIssue.ts`: tracker normalization
- `symphony/src/tracker/linear/linearTracker.ts`: candidate/state fetch operations
- `symphony/src/workspace/workspaceManager.ts`: workspace lifecycle
- `symphony/src/workspace/runHook.ts`: hook execution and timeout handling
- `symphony/src/codex/appServerClient.ts`: low-level protocol wrapper
- `symphony/src/codex/runAgentAttempt.ts`: attempt lifecycle
- `symphony/src/orchestrator/orchestrator.ts`: runtime state and scheduling
- `symphony/src/orchestrator/retryQueue.ts`: retry scheduling helpers
- `symphony/src/observability/logger.ts`: structured logging
- `symphony/src/observability/statusSnapshot.ts`: optional local status snapshot
- `symphony/tests/...`: module and integration tests

## Workflow Contract

The service will treat repository `WORKFLOW.md` as the canonical policy contract.

Requirements:

- optional YAML front matter plus markdown body
- strict parsing with typed errors for missing or malformed workflow files
- dynamic reload without service restart
- invalid reloads must not crash the process
- invalid reloads must preserve the last known good configuration

Prompt rendering inputs:

- `issue`
- `attempt`

Prompt rendering must fail on unknown variables or filters rather than silently substituting blanks.

## Dispatch Model

Eligibility rules for v1:

- only issues in configured active states are candidates
- issues with terminal blockers are allowed to proceed
- issues with non-terminal blockers are not dispatched
- priority order is lower numeric priority first, then oldest creation time
- claimed issues must not be double-dispatched

Service behavior:

1. poll Linear on configured cadence
2. validate current workflow config
3. reconcile already-running issues
4. fetch candidate issues
5. dispatch while concurrency slots remain
6. update logs and status snapshot

## Run Lifecycle

For each issue attempt:

1. create or reuse workspace
2. run `before_run`
3. start `codex app-server`
4. initialize session and thread
5. render prompt from workflow plus issue payload
6. execute turns until:
   - the issue leaves an active state
   - the issue reaches a terminal state
   - the run hits `max_turns`
   - the app-server exits or times out
7. stop the app-server session
8. run `after_run`
9. return normal or abnormal worker result to the orchestrator

## Retry And Reconciliation

The orchestrator owns all retry state.

Rules:

- normal worker exits schedule a short continuation retry
- abnormal exits schedule exponential backoff retries
- backoff is capped by config
- retry entries stay claimed so they are not duplicated
- non-active non-terminal tracker states stop a run without deleting its workspace
- terminal tracker states stop the run and clean the workspace
- startup performs a terminal-state cleanup sweep

## Trust And Safety Posture

V1 will be a high-trust local runner.

Meaning:

- no extra sandbox layer beyond Codex and OS defaults
- live access to the real Linear project and local filesystem
- workspace-boundary enforcement is still mandatory
- secrets are resolved through environment variables and never logged
- hook output is truncated in logs

This is intentionally not a hardened multi-tenant deployment. Hardening can be a later phase after the core implementation is stable and useful.

## Testing Strategy

Implementation will follow TDD at the module level.

Test layers:

- unit tests for workflow parsing, config defaults, env resolution, path sanitization, retry math, and normalization
- integration-style tests for orchestrator behavior, workspace hooks, and app-server protocol handling with test doubles
- opt-in live smoke tests for real Linear and `codex app-server`

Live smoke requirements:

- disabled by default
- enabled only with explicit environment flags and credentials
- target the real Linear project URL already in use
- verify startup validation, issue fetch, workspace creation, and app-server startup path

## Delivery Plan Shape

Implementation will be delivered in phases:

1. scaffold the TypeScript service and test harness
2. implement workflow/config layers with tests
3. implement real Linear client and normalization with tests
4. implement workspace management and hooks with tests
5. implement Codex app-server client with tests
6. implement orchestrator, retries, and reconciliation with tests
7. add live smoke path, docs, and run scripts

## Documentation Changes

The repository documentation should be updated to distinguish:

- the Swift product
- the local Symphony orchestration service
- the operator steps to run Symphony from this repository

The existing lightweight `WORKFLOW.md`/`docs/symphony-setup.md` content should be evolved so it matches the new in-repo implementation rather than only describing upstream usage.

## Risks And Constraints

- the upstream spec is broad, so strict v1 conformance needs disciplined scoping
- `codex app-server` protocol details can drift by installed version, so protocol code must be defensive
- live Linear integration means failures must be observable and non-destructive
- the repo currently has a user-modified `WORKFLOW.md`; implementation should avoid clobbering it without explicit intent

## Success Criteria

The design is successful when this repository contains a separate TypeScript Symphony service that:

- starts from a CLI with optional workflow path
- validates and reloads `WORKFLOW.md`
- reads live issues from the real Linear project
- creates deterministic per-issue workspaces
- launches `codex app-server` in those workspaces
- reconciles tracker state changes and retries according to the spec
- emits structured logs and supports live smoke verification
