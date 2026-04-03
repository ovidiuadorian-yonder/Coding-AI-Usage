# Task completion checklist
- Run relevant tests before claiming completion; default to `swift test` unless the task is tightly scoped and a targeted test is clearly sufficient.
- If service/auth/build behavior changed, prefer full-suite verification.
- If packaging or app-launch behavior changed, run `./build.sh` and, when appropriate, `./deploy.sh`.
- Mention any macOS-specific prompts or prerequisites affected by the change (Keychain, notifications, Windsurf local files, Codex auth file).
- Keep the user informed about verification results and any residual risks or things not tested.
- Do not assume formatter/linter steps exist; none are configured in the repo today.
- When editing shared services, watch for test seams and dependency injection patterns instead of introducing hard-wired process/network code.