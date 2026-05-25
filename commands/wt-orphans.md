---
allowed-tools: Bash
description: List worktree orphans — filesystem dirs missing from state.json, and state entries without a worktree dir
---

Detect inconsistencies between `.worktrees/` on disk and `state.json`.

Two kinds of orphans:
- **Filesystem orphan** — `.worktrees/<slug>/` exists but has no `state.json` entry. Typical cause: `git worktree add` was run manually, or `feature-create.sh` crashed mid-registration.
- **State orphan** — `state.json` has an entry but the worktree dir is gone. Typical cause: the dir was `rm -rf`'d without `/wt-abandon`.

Read-only. Prints recovery commands but does not execute them — you decide per-case whether to adopt, clear, or remove.

Run:
```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/orphans-list.sh
```

Follow the printed suggestions:
- `feature-create.sh <slug>` to adopt a filesystem orphan into state.json.
- `git worktree remove --force <dir>` to drop it entirely.
- `feature-abandon.sh <slug>` to clear a state orphan.

$ARGUMENTS
