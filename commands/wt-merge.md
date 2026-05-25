---
allowed-tools: Bash
description: PR + merge current worktree's branch into main, then tear down
---

From inside a worktree: push → create/find PR → merge (merge commit by default) → checkout main in main repo → pull → kill apache → remove worktree → drop from state.

## Process

1. First, confirm with the user by showing:
   - The feature slug + branch
   - Uncommitted file count (if >0, they must /wt-commit first)
   - Target base branch

   If there are uncommitted changes, refuse and suggest `/wt-commit`.

2. Run:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh
   ```

3. Report results: PR number, merge SHA, confirmation of teardown.

$ARGUMENTS
