---
tracker:
  kind: linear
  project_slug: "ai-usage-plugin-symphony-4111b1c85ad5"
  active_states:
    - Ready
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
    - Canceled
    - Cancelled

workspace:
  root: ~/.symphony/workspaces/ai-usage-plugin

hooks:
  after_create: |
    git clone --depth 1 https://github.com/ovidiuadorian-yonder/Coding-AI-Usage.git .
    git config advice.detachedHead false
  before_run: |
    git pull --ff-only || true

agent:
  max_concurrent_agents: 1
  max_turns: 8

codex:
  command: codex app-server
  approval_policy: full-auto
  thread_sandbox: workspace-write
---

You are working on Linear issue {{ issue.identifier }} for the AI-Usage-Plugin repository.

Repository summary:
- Native macOS menu bar app written in Swift 5.9
- Built with Swift Package Manager
- Main product focus: tracking Claude Code, Codex, and Windsurf usage

Issue context:
- Title: {{ issue.title }}
- Description:
{{ issue.description | default: "No additional description provided." }}
{% if issue.labels %}
- Labels: {{ issue.labels | join: ", " }}
{% endif %}

Execution rules:
- Work only inside the workspace created for this issue.
- Keep the Linear issue updated with progress, blockers, validation results, and completion notes.
- Follow the repository's existing structure and naming patterns.
- Avoid unrelated refactors or broad cleanups unless they are required to complete the issue safely.
- Prefer focused changes and preserve existing product behavior outside the issue scope.

Validation rules:
- Run `swift test` before claiming completion for code changes.
- Run `./build.sh` as the build check before claiming completion for app-impacting changes.
- If the task is documentation-only or cannot complete one of those commands, explain the reason in the Linear issue update and final summary.

Completion rules:
- Summarize what changed, what was verified, and any follow-up risks.
- Transition the Linear issue to "Done" when all validation passes and work is complete.
- If blocked, transition the Linear issue to "Todo" and leave a clear blocker summary and the next action needed from a human.
