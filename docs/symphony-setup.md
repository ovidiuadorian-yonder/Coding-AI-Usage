# Symphony Setup

This repository is configured to work with upstream `openai/symphony` as a Linear-driven orchestration target.

The Swift macOS app in this repository remains the product. Symphony runs outside this repository and uses `WORKFLOW.md` as the repository contract for polling Linear, creating workspaces, and launching `codex app-server`.

## What This Setup Covers

- Linear is the only intake and source of truth for v1.
- Symphony should watch one dedicated Linear project queue for this repository.
- Issues are ignored until they are moved into a runnable state.
- `Ready` and `Todo` are the execution gate.
- `In Progress` remains active so Symphony can continue reconciling already-started work.
- Moving an issue into `Done`, `Closed`, `Canceled`, or `Cancelled` should stop orchestration and allow workspace cleanup.

## Prerequisites

Before starting Symphony against this repository, make sure you have:

- a local checkout of upstream `openai/symphony`
- Elixir/Erlang and any other dependencies required by the selected Symphony runtime
- the `codex` CLI installed and authenticated
- access to the target Linear workspace and project
- a Linear personal API key available as `LINEAR_API_KEY` for unattended tracker polling

Recommended local checks:

```bash
which codex
codex login
echo "$LINEAR_API_KEY"
```

## Choose the Linear Project

Set `project_slug` in `WORKFLOW.md` to the dedicated Linear project for this repository.

To find the project slug:

1. Open the Linear project intended for Symphony-managed AI-Usage-Plugin work.
2. Copy the project URL.
3. Extract the slug from a URL such as `https://linear.app/<workspace>/project/<project-slug>`.
4. Replace `your-linear-project-slug` in `WORKFLOW.md`.

Use one dedicated project queue for v1 so issue selection stays predictable.

## Write Issues for Agent Execution

Symphony will perform best when Linear issues are implementation-ready. Each issue should contain:

- a clear title with one objective
- the expected outcome or acceptance criteria
- enough technical context to work safely in this Swift/macOS codebase
- constraints, rollout notes, or verification requirements when relevant

Avoid vague backlog items in runnable states. Keep exploratory or incomplete work in non-runnable states until a human has refined it.

## State Model

Use the following workflow model:

- `Triage`, `Backlog`, and similar states are non-runnable
- `Ready` means the issue has been reviewed and is safe for Symphony to pick up
- `Todo` is also runnable and should be treated as eligible
- `In Progress` remains active so Symphony can continue or reconcile ongoing work
- `Done`, `Closed`, `Canceled`, and `Cancelled` are terminal

The simplest operating model is:

1. Create or refine the issue in Linear.
2. Leave it outside runnable states until it is clear and actionable.
3. Move it to `Ready` or `Todo` when you want Symphony to dispatch an agent.

## Start Symphony

Run Symphony from its own repository, pointing it at this repository's `WORKFLOW.md`.

Example flow:

```bash
cd /path/to/openai-symphony/elixir
export LINEAR_API_KEY="lin_api_xxxxx"
mise exec -- ./bin/symphony /absolute/path/to/AI-Usage-Plugin/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

If you use a different Symphony runtime or install location, keep the same `WORKFLOW.md` path and equivalent runtime flags.

## What Symphony Will Do

With the current `WORKFLOW.md`, Symphony should:

- poll the configured Linear project for issues in `Ready`, `Todo`, or `In Progress`
- create a workspace under `~/.symphony/workspaces/ai-usage-plugin`
- clone `https://github.com/ovidiuadorian-yonder/Coding-AI-Usage.git`
- launch `codex app-server`
- direct the agent to run `swift test` and `./build.sh` before claiming completion when applicable
- expect the agent to keep the Linear issue updated with progress and blockers

## Verify It Is Working

Use a low-risk seed issue first, such as a documentation task or a narrowly scoped test-only change.

Verification checklist:

1. Confirm an issue outside `Ready` and `Todo` is ignored.
2. Move the issue to `Ready` or `Todo`.
3. Confirm Symphony logs show dispatch activity.
4. Confirm a workspace appears under `~/.symphony/workspaces/ai-usage-plugin`.
5. Confirm `codex app-server` starts for the workspace.
6. Confirm the Linear issue receives progress comments or status updates.
7. Confirm moving the issue to a terminal state triggers cleanup.

Repo-native verification commands:

```bash
swift test
./build.sh
```

## Notes

- This repository does not implement its own tracker or orchestration runtime.
- GitHub Issues and Teams intake are intentionally out of scope for this setup.
- The connected Linear MCP/skill can still be useful for interactive work in Codex sessions, but the unattended Symphony runtime should follow its own tracker integration requirements.
