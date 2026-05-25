---
allowed-tools: Bash
description: Resume an existing feature worktree (print state + restart Apache)
argument-hint: <slug>
---

Resume an existing feature: print its full state (branch, port, URL, plan, uncommitted count) and (re)start Apache.

**This is a pure alias for `/wt-create <slug>`** when the slug is already registered. `feature-create.sh` detects that the slug exists in `state.json` and prints a "Resuming…" banner instead of creating anything. Use `/wt-resume` when you want the UX hint that you're continuing existing work; use `/wt-create` when you don't care either way. No independent logic.

## Process

1. Run the create-or-resume script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/feature-create.sh $ARGUMENTS
   ```
   For a registered slug this is a no-op on disk; it just prints the `Resuming…` banner.

2. (Re)start Apache (idempotent):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/apache-start.sh $ARGUMENTS
   ```

3. Report back: URL, PID, whether Apache was already running.

$ARGUMENTS
