---
allowed-tools: Bash
description: Throw away a feature — kill apache, remove worktree, delete branch
argument-hint: <slug>
---

**Destructive.** Abandons a feature: stops apache, removes worktree, deletes local branch, drops from state. No merge, no PR.

## Process

1. Confirm with the user — show the slug, branch, and any uncommitted work that will be lost.
2. Run:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/feature-abandon.sh $ARGUMENTS
   ```
3. Report completion.

$ARGUMENTS
