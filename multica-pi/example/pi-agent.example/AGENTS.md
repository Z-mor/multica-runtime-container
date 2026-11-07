# Global agent instructions

Instructions in this file apply to every task this runtime executes, on top of
the per-task instructions Multica writes into the workspace. Keep it short and
operational — it is loaded into every conversation.

- Work only inside the task workspace; never modify files outside it.
- Keep commits small and focused; use the configured git identity.
- Follow the repository's own conventions (lint, tests, commit style).
