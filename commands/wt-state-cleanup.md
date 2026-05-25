---
allowed-tools: Bash
description: Run the worktree-flow janitor — GC state.json.tmp.* orphans, reconcile state, archive old plans
---

Explicit cleanup pass for `.worktrees/` state and `~/.claude/plans/`. Same routine that `session-start.sh` runs automatically, exposed as a command for when you notice cruft between sessions.

What it does:
1. Removes `.worktrees/state.json.tmp.*` files older than 60 minutes (jq+mv leftovers).
2. Reconciles feature entries (marks missing worktree dirs as `stale`, GCs stale session buckets).
3. Reconciles Apache PIDs (flips `apache_running` to false for dead PIDs).
4. Archives plan files older than 14 days into `~/.claude/plans/archive/YYYY-MM/`.

Run:
```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/state-cleanup.sh
```

Read-only on state.json semantics — it only updates flags and removes temp files. Never deletes real worktrees, branches, or active plans.

$ARGUMENTS
